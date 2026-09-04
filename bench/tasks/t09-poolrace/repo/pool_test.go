package pool

import "testing"

func TestSumSmall(t *testing.T) {
	jobs := make([]int, 20)
	for i := range jobs {
		jobs[i] = i + 1
	}
	if got := Run(jobs, 4); got != 420 {
		t.Fatalf("Run = %d, want 420", got)
	}
}

func TestManyJobs(t *testing.T) {
	jobs := make([]int, 100)
	for i := range jobs {
		jobs[i] = i + 1
	}
	if got := Run(jobs, 8); got != 10100 {
		t.Fatalf("Run = %d, want 10100", got)
	}
}

func TestEmpty(t *testing.T) {
	if got := Run(nil, 4); got != 0 {
		t.Fatalf("Run(nil) = %d, want 0", got)
	}
}

func TestSingleWorker(t *testing.T) {
	if got := Run([]int{1, 2, 3}, 1); got != 12 {
		t.Fatalf("Run = %d, want 12", got)
	}
}
