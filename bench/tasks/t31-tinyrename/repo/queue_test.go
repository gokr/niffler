package tinyrename

import (
	"strings"
	"testing"
)

func TestDrainAllReturnsJobsInOrder(t *testing.T) {
	q := &Queue{}
	q.Enqueue("a")
	q.Enqueue("b")
	got := q.DrainAll()
	if len(got) != 2 || got[0].Name != "a" || got[1].Name != "b" {
		t.Fatalf("DrainAll() = %+v, want a then b", got)
	}
	if left := q.DrainAll(); len(left) != 0 {
		t.Fatalf("second DrainAll() = %+v, want empty", left)
	}
}

func TestRunOnceAndRunAllUseTheRenamedCall(t *testing.T) {
	q := &Queue{}
	if got := RunOnce(q, "x"); len(got) != 1 || got[0].Name != "x" {
		t.Fatalf("RunOnce = %+v", got)
	}
	q.Enqueue("y")
	if got := RunAll(q); len(got) != 1 || got[0].Name != "y" {
		t.Fatalf("RunAll = %+v", got)
	}
}

func TestStatusLineNamesTheCurrentAPI(t *testing.T) {
	q := &Queue{}
	if !strings.Contains(q.StatusLine(), "DrainAll()") {
		t.Fatalf("StatusLine = %q, want the renamed call", q.StatusLine())
	}
}
