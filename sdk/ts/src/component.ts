// Niffler component SDK (TypeScript / Node.js).
//
// Mirrors sdk/go/component.go 1:1 — the envelope (docs/WIRE.md) is the
// artifact; SDKs follow. The Go port serializes nats.go callbacks with a
// mutex; this port serializes handlers through a promise chain (the Nim
// SDK's single-threaded poll loop is the model). Teardown = exit; the OS
// is the disposer.
//
// Surface:
//   import sdk from "niffler-sdk";
//   const comp = sdk.newComponent("greet", "0.1.0");
//   comp.tool("greet", {
//     type: "object",
//     description: "Greet someone",
//     properties: { name: { type: "string", description: "the name" } },
//     required: ["name"],
//   }, (c, args) => {
//     const name = (args as any).name ?? "world";
//     return { greeting: `Hello, ${name}` };
//   });
//   comp.run();

import * as path from "path";
import { AsyncLocalStorage } from "node:async_hooks";
import { connect, NatsConnection, Subscription, StringCodec } from "nats";
import { decode, encode, newId } from "./envelope";
import type { Envelope, EnvelopeKind } from "./envelope";
import { loadDotEnv } from "./dotenv";

export * from "./envelope";

const sc = StringCodec();

export type ToolHandler = (
  c: Component,
  args: unknown
) => unknown | Promise<unknown>;

export type EventHandler = (
  c: Component,
  subject: string,
  payload: unknown
) => void | Promise<void>;

/** Raw wire tap: receives the full envelope bytes for every matching
 *  subject (all kinds: call/result/event/error), for bus observation. */
export type TapHandler = (
  c: Component,
  subject: string,
  data: Uint8Array
) => void | Promise<void>;

export interface Tool {
  name: string;
  schema: Record<string, unknown>;
  handler: ToolHandler;
}

interface EventBinding {
  pattern: string;
  handler: EventHandler;
}

interface TapBinding {
  pattern: string;
  handler: TapHandler;
}

export class Component {
  name: string;
  version: string;

  nc: NatsConnection | null = null;
  private tools: Tool[] = [];
  private events: EventBinding[] = [];
  private taps: TapBinding[] = [];
  private subs: Subscription[] = [];
  /** Serializes handlers (mirrors the Nim SDK's single thread). */
  private chain: Promise<unknown> = Promise.resolve();
  private handlerContext = new AsyncLocalStorage<boolean>();
  private closing: Promise<void> | null = null;
  private closeRequested = false;
  private stopRun: (() => void) | null = null;

  constructor(name: string, version: string) {
    this.name = name;
    this.version = version;
  }

  /** Register a tool. Chainable: newComponent().tool(...).tool(...).run() */
  tool(
    name: string,
    schema: Record<string, unknown>,
    handler: ToolHandler
  ): Component {
    this.tools.push({ name, schema, handler });
    return this;
  }

  /** Subscribe to an event pattern (exact subject, ">" or "foo.>"). */
  on(pattern: string, handler: EventHandler): Component {
    this.events.push({ pattern, handler });
    return this;
  }

  /** Subscribe a raw wire tap (see TapHandler). Joins the serialized
   *  handler stream; sees all envelope kinds, incl. this component's calls. */
  tap(pattern: string, handler: TapHandler): Component {
    this.taps.push({ pattern, handler });
    return this;
  }

  /** Publish a fire-and-forget event. */
  emit(subject: string, payload: unknown): void {
    const env: Envelope = { v: 1, id: newId(), kind: "event", payload };
    this.nc?.publish(subject, sc.encode(encode(env)));
  }

  /** Publish any pre-built envelope to any subject. */
  publishEnvelope(subject: string, env: Envelope): void {
    this.nc?.publish(subject, sc.encode(encode(env)));
  }

  /** Request/reply with a pre-built envelope on an arbitrary subject;
   *  returns the full reply envelope (result or error). */
  async requestEnvelope(
    subject: string,
    env: Envelope,
    timeoutMs: number = 5000
  ): Promise<Envelope> {
    const msg = await this.nc!.request(subject, sc.encode(encode(env)), {
      timeout: timeoutMs,
    });
    const reply = decode(sc.decode(msg.data));
    if (reply.id !== env.id) {
      throw new Error(`request ${subject}: reply id mismatch`);
    }
    if (reply.kind !== "result" && reply.kind !== "error") {
      throw new Error(`request ${subject}: expected result or error envelope`);
    }
    return reply;
  }

  /** Structured log to ev.log.<name>: {component, level, msg, ctx, at}. */
  log(level: string, msg: string, ctx?: unknown): void {
    if (!shouldLog(level, process.env.NIF_LOG_LEVEL ?? "info")) return;
    const payload: Record<string, unknown> = {
      component: this.name,
      level,
      msg,
      at: Date.now() / 1000,
    };
    if (ctx !== undefined) payload.ctx = ctx;
    this.emit("ev.log." + this.name, payload);
  }

  /** Subscribe to a side-channel pattern; handlers run unserialized. */
  subscribe(
    pattern: string,
    handler: (subject: string, payload: unknown) => void
  ): () => void {
    const sub = this.nc!.subscribe(pattern);
    sub.callback = (err, msg) => {
      if (err) return;
      const env = decode(sc.decode(msg.data));
      handler(msg.subject, env.payload);
    };
    this.subs.push(sub);
    return () => {
      void sub.unsubscribe();
    };
  }

  /** Call a tool on another component (request/reply over the bus). */
  async request(
    component: string,
    tool: string,
    args: unknown,
    timeoutMs: number = 5000
  ): Promise<unknown> {
    const env: Envelope = {
      v: 1,
      id: newId(),
      kind: "call",
      tool,
      args,
      caller: this.name,
    };
    const subject = "svc." + component + ".call";
    const msg = await this.nc!.request(subject, sc.encode(encode(env)), {
      timeout: timeoutMs,
    });
    const resp = decode(sc.decode(msg.data));
    if (resp.id !== env.id) {
      throw new Error(`request ${subject}: reply id mismatch`);
    }
    if (resp.kind === "error") {
      throw new Error(resp.error?.message ?? "component error");
    }
    if (resp.kind !== "result") {
      throw new Error(`request ${subject}: expected result envelope`);
    }
    return resp.args;
  }

  /** Connect, announce registration and start serving calls. */
  async connect(): Promise<void> {
    loadDotEnv(
      ".env",
      path.join(process.env.NIF_ROOT ?? "", ".env")
    );
    const url = process.env.NIF_NATS_URL ?? "nats://127.0.0.1:4222";
    this.nc = await connect({
      servers: url,
      maxReconnectAttempts: -1,
      reconnectTimeWait: 1000,
    });
    this.closing = null;

    // queue-grouped call subject: N replicas, one gets each call
    const callSub = this.nc.subscribe("svc." + this.name + ".call", {
      queue: this.name,
    });
    callSub.callback = (err, msg) => {
      if (err) return;
      this.enqueue(() => this.handleCall(msg.subject, msg.reply ?? "", msg.data));
    };
    this.subs.push(callSub);

    // passive event subscriptions + the SDK-managed drain subject
    this.events.push({
      pattern: "ev.sys.drain",
      handler: () => {
        this.requestShutdown();
      },
    });
    for (const e of this.events) {
      const sub = this.nc.subscribe(e.pattern);
      sub.callback = (err, msg) => {
        if (err) return;
        this.enqueue(async () => {
          const env = decode(sc.decode(msg.data));
          await e.handler(this, msg.subject, env.payload);
        });
      };
      this.subs.push(sub);
    }

    // raw wire taps (serialized like events)
    for (const t of this.taps) {
      const sub = this.nc.subscribe(t.pattern);
      sub.callback = (err, msg) => {
        if (err) return;
        this.enqueue(async () => {
          await t.handler(this, msg.subject, msg.data);
        });
      };
      this.subs.push(sub);
    }

    this.announce("reg.publish");
    console.log(
      `${this.name} v${this.version} online on ${url} (${this.tools.length} tools)`
    );
  }

  connected(): boolean {
    return this.nc !== null && !this.nc.isClosed();
  }

  /** Announce departure, drain subscriptions, close the connection. */
  async close(): Promise<void> {
    if (this.handlerContext.getStore() === true) {
      this.closeRequested = true;
      return;
    }
    await this.beginClose();
  }

  private async beginClose(): Promise<void> {
    if (this.closing) {
      await this.closing;
      return;
    }
    if (!this.nc) return;
    const nc = this.nc;
    this.closing = (async () => {
      this.announce("reg.depart");
      for (const s of this.subs) {
        await s.drain();
      }
      await this.chain;
      await nc.flush();
      await nc.close();
      if (this.nc === nc) this.nc = null;
    })();
    await this.closing;
  }

  /** Connect, serve until SIGTERM/SIGINT or ev.sys.drain, then exit 0. */
  async run(): Promise<void> {
    let resolveDone = () => {};
    const done = new Promise<void>((resolve) => {
      resolveDone = resolve;
    });
    const onSignal = () => resolveDone();
    this.stopRun = resolveDone;
    process.once("SIGTERM", onSignal);
    process.once("SIGINT", onSignal);
    try {
      await this.connect();
      await done;
    } finally {
      this.stopRun = null;
      process.removeListener("SIGTERM", onSignal);
      process.removeListener("SIGINT", onSignal);
    }
    await this.shutdown();
  }

  private async shutdown(): Promise<void> {
    if (!this.nc) return;
    await this.close();
  }

  private requestShutdown(): void {
    if (this.stopRun) {
      this.stopRun();
    } else {
      void this.shutdown();
    }
  }

  private announce(subject: string): void {
    const payload = {
      name: this.name,
      version: this.version,
      pid: process.pid,
      tools: this.tools.map((t) => ({ name: t.name, schema: t.schema })),
    };
    this.nc?.publish(subject, sc.encode(JSON.stringify(payload)));
  }

  /** Serialize handler execution (single logical thread). */
  private enqueue(fn: () => Promise<void>): void {
    this.chain = this.chain.then(async () => {
      try {
        await this.handlerContext.run(true, fn);
      } finally {
        if (this.closeRequested) {
          this.closeRequested = false;
          queueMicrotask(() => void this.beginClose());
        }
      }
    }).catch((err) => {
      console.error(`${this.name}: handler error:`, err);
    });
  }

  private async handleCall(subject: string, reply: string, data: Uint8Array): Promise<void> {
    if (!this.nc) return;
    const env = decode(sc.decode(data));
    let resp: Envelope;
    if (env.kind !== "call") {
      resp = { v: 1, id: env.id, kind: "error",
               error: { code: "bad-envelope", message: "expected call envelope" } };
    } else {
      const t = this.tools.find((t) => t.name === env.tool);
      if (!t) {
        resp = { v: 1, id: env.id, kind: "error",
                 error: { code: "no-tool",
                          message: `component ${this.name} has no tool '${env.tool}'` } };
      } else {
        try {
          const res = await t.handler(this, env.args);
          resp = { v: 1, id: env.id, kind: "result", args: res };
        } catch (err) {
          resp = { v: 1, id: env.id, kind: "error",
                   error: { code: "boom", message: String(err) } };
        }
      }
    }
    if (reply) {
      this.nc.publish(reply, sc.encode(encode(resp)));
    }
  }
}

const logLevels = ["debug", "info", "warn", "error"] as const;

function shouldLog(level: string, threshold: string): boolean {
  const levelIndex = logLevels.indexOf(level as (typeof logLevels)[number]);
  if (levelIndex < 0) {
    throw new Error(`invalid log level '${level}' (debug|info|warn|error)`);
  }
  let thresholdIndex = logLevels.indexOf(
    threshold as (typeof logLevels)[number]
  );
  if (thresholdIndex < 0) thresholdIndex = logLevels.indexOf("info");
  return levelIndex >= thresholdIndex;
}

/** Create a component with the given bus identity. */
export function newComponent(name: string, version: string): Component {
  return new Component(name, version);
}

export default { newComponent, Component };
