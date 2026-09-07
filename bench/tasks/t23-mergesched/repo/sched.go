// Package sched merges booked intervals and computes room requirements.
// An interval is half-open [Start, End) with a priority; time is int64
// minutes. See README.md for the exact rules.
package sched

// Interval is a booking. Zero-length (Start == End) occupies no time.
type Interval struct {
	Start    int64
	End      int64
	Priority int
}

// Merge returns the union of bookings: overlapping intervals merge into
// one whose Priority is the MAX of its members. Adjacent bookings
// (a.End == b.Start) stay separate. The result is sorted by Start
// (ties broken by End). Zero-length intervals pass through unchanged.
func Merge(intervals []Interval) []Interval {
	// TODO
	return nil
}

// MinRooms returns how many rooms are needed so that no two live bookings
// share a room at the same instant (maximum overlap of positive-length
// intervals). Zero-length intervals need no room.
func MinRooms(intervals []Interval) int {
	// TODO
	return 0
}
