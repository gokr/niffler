# tinyrename

A tiny job queue, used to exercise a rename.

```go
q := &Queue{}
q.Enqueue("job")
jobs := q.Drain() // clears the queue
```

`RunOnce` queues a batch and drains it; `RunAll` drains whatever is left.
