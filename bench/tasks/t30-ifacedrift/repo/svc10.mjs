// svc10 - enricher stage 10
// profile: lenient
// width: 10

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 10);
}
