package tinyrename

// RunOnce queues the given jobs and hands the whole batch to the caller.
func RunOnce(q *Queue, names ...string) []Job {
	for _, name := range names {
		q.Enqueue(name)
	}
	return q.Drain()
}

// RunAll drains whatever is left, so a worker never leaves jobs behind.
func RunAll(q *Queue) []Job {
	left := q.Drain()
	return left
}
