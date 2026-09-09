// svc06 - emitter stage 06
// profile: strict
// width: 6

import { parse, formatV2 } from "./lib.mjs";

export function transform(raw) {
  const obj = parse(raw);
  return format(obj, 6);
}
