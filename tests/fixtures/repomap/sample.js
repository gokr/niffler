export function buildIdx(rows) {
  return rows.map(r => r * 2);
}
class Collector {
  add(v) { this.vs.push(v); }
}
const total = buildIdx([1, 2]);
