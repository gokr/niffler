// svc13 - ingester stage 13
// profile: strict
// width: 10

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 10);
}
