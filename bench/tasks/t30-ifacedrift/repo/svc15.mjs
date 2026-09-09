// svc15 - router stage 15
// profile: lenient
// width: 6

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 6);
}
