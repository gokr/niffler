export function buildIndex(rows: string[]): Map<string, number> {
  return new Map();
}

const defaultLimit = 10;

interface Row {
  id: number;
}

export class Indexer {
  crawl(): void {}
  fetchAll(id: number): Promise<string[]> {
    return Promise.resolve([]);
  }
}

const ix = new Indexer();
buildIndex([]);
