// In-memory todo store.
//
//   const store = new TodoStore();
//   store.add("buy milk")   -> { id: 1, text: "buy milk", done: false }
//   store.complete(1)       -> { id: 1, text: "buy milk", done: true }
//   store.list()            -> all todos, oldest first
//   store.list({done:true}) -> only completed todos
//   store.remove(1)         -> true if it existed and was removed, else false
//
// Ids are integers starting at 1, incremented per add. complete() on an
// unknown id returns null. The store starts empty on every construction.
export class TodoStore {
  add(text) {
    throw new Error("not implemented");
  }

  complete(id) {
    throw new Error("not implemented");
  }

  list(filter = {}) {
    throw new Error("not implemented");
  }

  remove(id) {
    throw new Error("not implemented");
  }
}
