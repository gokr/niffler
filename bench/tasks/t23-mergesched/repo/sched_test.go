package sched

import (
	"reflect"
	"testing"
)

func TestMergeDisjoint(t *testing.T) {
	got := Merge([]Interval{{0, 10, 1}, {20, 30, 2}, {40, 50, 3}})
	want := []Interval{{0, 10, 1}, {20, 30, 2}, {40, 50, 3}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMergeOverlapKeepsMaxPriority(t *testing.T) {
	got := Merge([]Interval{{0, 10, 1}, {5, 15, 9}})
	want := []Interval{{0, 15, 9}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMergeAdjacentStaysSeparate(t *testing.T) {
	got := Merge([]Interval{{0, 10, 1}, {10, 20, 1}})
	want := []Interval{{0, 10, 1}, {10, 20, 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMergeUnsortedNestedAndContainment(t *testing.T) {
	got := Merge([]Interval{{30, 40, 5}, {0, 100, 1}, {10, 20, 7}})
	want := []Interval{{0, 100, 7}} // contains all; priority = max(5,1,7)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMergeZeroLengthPassesThrough(t *testing.T) {
	got := Merge([]Interval{{5, 5, 3}, {0, 10, 1}})
	want := []Interval{{0, 10, 1}, {5, 5, 3}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMergeTieSortByEnd(t *testing.T) {
	got := Merge([]Interval{{10, 5, 1}, {10, 2, 1}})
	want := []Interval{{10, 2, 1}, {10, 5, 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestMinRooms(t *testing.T) {
	cases := []struct {
		name string
		in   []Interval
		want int
	}{
		{"empty", nil, 0},
		{"single", []Interval{{0, 10, 1}}, 1},
		{"disjoint", []Interval{{0, 10, 1}, {10, 20, 1}}, 1}, // adjacent is fine
		{"two overlapping", []Interval{{0, 10, 1}, {5, 15, 1}}, 2},
		{"three same time", []Interval{{0, 10, 1}, {0, 10, 1}, {0, 10, 1}}, 3},
		{"staircase", []Interval{{0, 10, 1}, {5, 15, 1}, {11, 20, 1}}, 2},
		{"zero-length needs nothing", []Interval{{5, 5, 1}, {5, 5, 1}}, 0},
		{"zero-length amid overlap", []Interval{{0, 10, 1}, {5, 5, 1}, {9, 20, 1}}, 2},
		{"touch at point", []Interval{{0, 10, 1}, {10, 20, 1}, {20, 30, 1}}, 1},
	}
	for _, c := range cases {
		if got := MinRooms(c.in); got != c.want {
			t.Fatalf("%s: got %d want %d", c.name, got, c.want)
		}
	}
}
