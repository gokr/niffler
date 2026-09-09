// svc11 - aggregator stage 11
// profile: strict
// width: 8

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 8);
}
