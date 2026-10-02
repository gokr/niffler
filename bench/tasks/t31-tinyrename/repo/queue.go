// Package tinyrename is a tiny in-memory job queue used as a rename exercise.
package tinyrename

// Job is one queued unit of work.
type Job struct {
	Name string
}

// Queue holds jobs in arrival order.
type Queue struct {
	jobs []Job
}

// Enqueue appends a job to the queue.
func (q *Queue) Enqueue(name string) {
	q.jobs = append(q.jobs, Job{Name: name})
}

// Drain removes every job from the queue and returns them in arrival order.
// It returns an empty slice when the queue is already empty.
func (q *Queue) Drain() []Job {
	out := q.jobs
	q.jobs = nil
	return out
}

// StatusLine is the one-line status shown by the CLI.
func (q *Queue) StatusLine() string {
	return "queue: Drain() clears it, Enqueue() fills it"
}
