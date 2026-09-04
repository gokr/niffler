// async helpers. The test suite fails — fix the bugs below.

// fetchAll: fetch every url (via the async fetchOne) and return the
// results in the SAME order as the input urls.
async function fetchAll(urls, fetchOne) {
  const results = [];
  await Promise.all(
    urls.map(async (u) => {
      const r = await fetchOne(u);
      results.push(r); // BUG: completion order, not input order
    }),
  );
  return results;
}

// retry: call fn until it resolves or `attempts` calls have failed;
// then reject with the last error.
async function retry(fn, attempts) {
  for (let i = 0; i <= attempts; i++) {
    try {
      return await fn();
    } catch (e) {
      // BUG: the last error is swallowed and undefined resolves
    }
  }
}

// sequential: run every fn one after another and return the results in
// order.
async function sequential(fns) {
  const out = [];
  for (const f of fns) {
    out.push(f()); // BUG: promise pushed, not awaited
  }
  return out;
}

module.exports = { fetchAll, retry, sequential };
