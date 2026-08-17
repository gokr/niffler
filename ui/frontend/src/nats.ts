// The single transport-aware file in the frontend.
//
// Everything else talks to this interface; the bridge implements it over
// NATS inside the Wails shell. To run the same SPA against a WebSocket
// proxy later, swap this file only.

import { Send, Emit, Online, BusUrl } from "../wailsjs/go/main/Bridge";
import { EventsOn } from "../wailsjs/runtime/runtime";

export interface NatEvent {
  subject: string;
  payload: any;
}

function bridge(): any {
  const w = window as any;
  if (!w.go?.main?.Bridge) {
    throw new Error(
      "not running inside the Wails shell (window.go missing) — " +
        "launch ./ui/build/bin/niffler-ui (or run `wails dev` in ui/)"
    );
  }
  return w.go.main.Bridge;
}

/** True when running inside the Wails shell (not a plain browser). */
export function isWails(): boolean {
  return !!(window as any).go?.main?.Bridge;
}

/** Call a tool on a component over the bus. Resolves with the result JSON. */
export async function send(
  component: string,
  tool: string,
  args: any,
  timeoutMs = 180000
): Promise<any> {
  const raw = await bridge().Send(component, tool, JSON.stringify(args), timeoutMs);
  const parsed = JSON.parse(raw);
  if (parsed && parsed.error) throw new Error(parsed.error);
  return parsed;
}

/** Publish a fire-and-forget event. */
export function emit(subject: string, payload: any): void {
  bridge().Emit(subject, JSON.stringify(payload));
}

/** Subscribe to bus events whose concrete subject starts with `prefix`.
 * Returns an unsubscribe function. */
export function on(prefix: string, cb: (ev: NatEvent) => void): () => void {
  return EventsOn("nats", (ev: NatEvent) => {
    if (ev && typeof ev.subject === "string" && ev.subject.startsWith(prefix)) {
      cb(ev);
    }
  });
}

/** Bridge bus connection state (snapshot). */
export function online(): Promise<boolean> {
  return bridge().Online();
}

/** Bus address the bridge is using. */
export function busUrl(): Promise<string> {
  return bridge().BusUrl();
}

/** Live connection state: cb(online, url) on every change. */
export function onStatus(cb: (online: boolean, url: string) => void): () => void {
  if (!isWails()) return () => {};
  return EventsOn("nats-status", (ev: any) => cb(!!ev?.online, ev?.url ?? ""));
}
