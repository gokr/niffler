// svc08 - normalizer stage 08
// profile: lenient
// width: 8

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 8);
}
