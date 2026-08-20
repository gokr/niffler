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
) => void;

export interface Tool {
  name: string;
  schema: Record<string, unknown>;
  handler: ToolHandler;
}

interface EventBinding {
  pattern: string;
  handler: EventHandler;
}

function matches(pattern: string, subject: string): boolean {
  if (pattern === subject) return true;
  if (pattern === ">") return true;
  if (pattern.endsWith(".>")) {
    return subject.startsWith(pattern.slice(0, -2));
  }
  return false;
}

export class Component {
  name: string;
  version: string;

  nc: NatsConnection | null = null;
  private tools: Tool[] = [];
  private events: EventBinding[] = [];
  private subs: Subscription[] = [];
  /** Serializes handlers (mirrors the Nim SDK's single thread). */
  private chain: Promise<unknown> = Promise.resolve();

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

  /** Publish a fire-and-forget event. */
  emit(subject: string, payload: unknown): void {
    const env: Envelope = { v: 1, id: newId(), kind: "event", payload };
    this.nc?.publish(subject, sc.encode(encode(env)));
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
    const env = { v: 1, id: newId(), kind: "call" as EnvelopeKind, tool, args };
    const subject = "svc." + component + ".call";
    const msg = await this.nc!.request(subject, sc.encode(encode(env)), {
      timeout: timeoutMs,
    });
    const resp = decode(sc.decode(msg.data));
    if (resp.kind === "error") {
      throw new Error(resp.error?.message ?? "component error");
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
        void this.shutdown();
      },
    });
    for (const e of this.events) {
      const sub = this.nc.subscribe(e.pattern);
      sub.callback = (err, msg) => {
        if (err) return;
        const env = decode(sc.decode(msg.data));
        for (const b of this.events) {
          if (matches(b.pattern, msg.subject)) {
            b.handler(this, msg.subject, env.payload);
          }
        }
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
    if (!this.nc) return;
    this.announce("reg.depart");
    for (const s of this.subs) {
      await s.drain();
    }
    await new Promise((r) => setTimeout(r, 200));
    await this.nc.close();
    this.nc = null;
  }

  /** Connect, serve until SIGTERM/SIGINT or ev.sys.drain, then exit 0. */
  async run(): Promise<void> {
    await this.connect();
    const done = new Promise<void>((resolve) => {
      const onSignal = () => resolve();
      process.on("SIGTERM", onSignal);
      process.on("SIGINT", onSignal);
    });
    await done;
    await this.shutdown();
    process.exit(0);
  }

  private async shutdown(): Promise<void> {
    if (!this.nc) return;
    await this.close();
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
    this.chain = this.chain.then(fn).catch((err) => {
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

/** Create a component with the given bus identity. */
export function newComponent(name: string, version: string): Component {
  return new Component(name, version);
}

export default { newComponent, Component };
