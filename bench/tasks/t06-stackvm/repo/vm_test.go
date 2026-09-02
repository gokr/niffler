package stackvm

import (
	"reflect"
	"testing"
)

func run(t *testing.T, src string, in []int) []int {
	t.Helper()
	prog, err := Assemble(src)
	if err != nil {
		t.Fatalf("assemble: %v", err)
	}
	out, err := Execute(prog, in...)
	if err != nil {
		t.Fatalf("execute: %v", err)
	}
	return out
}

func runErr(t *testing.T, src string, in []int) {
	t.Helper()
	prog, err := Assemble(src)
	if err != nil {
		return // an assembler rejection is a fine failure too
	}
	if _, err := Execute(prog, in...); err == nil {
		t.Fatalf("%q: expected an error, got none", src)
	}
}

func TestArithmetic(t *testing.T) {
	cases := []struct {
		src  string
		want []int
	}{
		{"PUSH 7\nPUSH 5\nSUB\nWRITE", []int{2}},
		{"PUSH 3\nPUSH 4\nADD\nWRITE", []int{7}},
		{"PUSH 6\nPUSH 4\nMUL\nWRITE", []int{24}},
		{"PUSH 17\nPUSH 5\nMOD\nWRITE", []int{2}},
		{"PUSH 17\nPUSH 5\nMOD\nPUSH 2\nMOD\nWRITE", []int{0}},
		{"PUSH 3\nNEG\nWRITE", []int{-3}},
		{"PUSH 3\nNEG\nNEG\nWRITE", []int{3}},
	}
	for _, c := range cases {
		if got := run(t, c.src, nil); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got %v, want %v", c.src, got, c.want)
		}
	}
}

func TestStackOps(t *testing.T) {
	cases := []struct {
		src  string
		want []int
	}{
		{"PUSH 1\nPUSH 2\nDUP\nWRITE\nWRITE\nWRITE", []int{2, 2, 1}},
		{"PUSH 7\nDUP\nWRITE\nWRITE", []int{7, 7}},
		{"PUSH 1\nPUSH 2\nSWAP\nWRITE\nWRITE", []int{1, 2}},
		{"PUSH 1\nPUSH 2\nOVER\nWRITE\nWRITE\nWRITE", []int{1, 2, 1}},
		{"PUSH 9\nDROP\nPUSH 4\nWRITE", []int{4}},
	}
	for _, c := range cases {
		if got := run(t, c.src, nil); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got %v, want %v", c.src, got, c.want)
		}
	}
}

func TestCompare(t *testing.T) {
	cases := []struct {
		src  string
		want []int
	}{
		{"PUSH 3\nPUSH 3\nEQ\nWRITE", []int{1}},
		{"PUSH 3\nPUSH 4\nEQ\nWRITE", []int{0}},
		{"PUSH 3\nPUSH 4\nLT\nWRITE", []int{1}},
		{"PUSH 4\nPUSH 3\nLT\nWRITE", []int{0}},
	}
	for _, c := range cases {
		if got := run(t, c.src, nil); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got %v, want %v", c.src, got, c.want)
		}
	}
}

func TestInputOutput(t *testing.T) {
	// Inputs are pushed in order: the last input ends on top.
	cases := []struct {
		src  string
		in   []int
		want []int
	}{
		{"READ\nREAD\nWRITE\nWRITE", []int{7, 3}, []int{3, 7}},
		{"READ\nWRITE", []int{42}, []int{42}},
	}
	for _, c := range cases {
		if got := run(t, c.src, c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q (in %v): got %v, want %v", c.src, c.in, got, c.want)
		}
	}
}

func TestJumps(t *testing.T) {
	// prog: 0 READ, 1 JZ, 2 PUSH 1, 3 WRITE, 4 HALT, 5 PUSH 9, 6 WRITE
	jz := "READ\nJZ 5\nPUSH 1\nWRITE\nHALT\nPUSH 9\nWRITE"
	jnz := "READ\nJNZ 5\nPUSH 1\nWRITE\nHALT\nPUSH 9\nWRITE"
	cases := []struct {
		src  string
		in   []int
		want []int
	}{
		{jz, []int{0}, []int{9}},  // JZ taken on zero
		{jz, []int{7}, []int{1}},  // JZ not taken on non-zero
		{jnz, []int{0}, []int{1}}, // JNZ not taken on zero
		{jnz, []int{2}, []int{9}}, // JNZ taken on non-zero
		{"JMP 3\nPUSH 1\nWRITE\nPUSH 2\nWRITE", nil, []int{2}},
		{"PUSH 1\nWRITE\nHALT\nPUSH 2\nWRITE", nil, []int{1}}, // HALT stops early
		{"PUSH 5\nWRITE", nil, []int{5}},                      // implicit halt at the end
	}
	for _, c := range cases {
		if got := run(t, c.src, c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q (in %v): got %v, want %v", c.src, c.in, got, c.want)
		}
	}
}

func TestVMErrorPaths(t *testing.T) {
	cases := [][]Op{
		{{"DROP", 0}},                           // underflow
		{{"PUSH", 1}, {"ADD", 0}},               // underflow
		{{"SWAP", 0}},                           // underflow
		{{"OVER", 0}},                           // underflow
		{{"NEG", 0}},                            // underflow
		{{"PUSH", 1}, {"PUSH", 0}, {"MOD", 0}},  // modulo by zero
		{{"READ", 0}},                           // no input
		{{"READ", 0}, {"READ", 0}, {"READ", 0}}, // input exhausted
		{{"JMP", 99}},                           // target out of range
		{{"JZ", -1}},                            // target out of range
		{{"FOO", 0}},                            // unknown opcode
	}
	for _, prog := range cases {
		if _, err := Execute(prog); err == nil {
			t.Errorf("%v: expected an error, got none", prog)
		}
	}
}

func TestAssemble(t *testing.T) {
	// Labels resolve to instruction indexes, not source lines: "loop" sits
	// on source line 3 but DUP is instruction 1.
	prog, err := Assemble("start:\nPUSH 1\n\nloop:\nDUP\nJMP loop\n")
	if err != nil {
		t.Fatalf("assemble: %v", err)
	}
	if len(prog) != 3 {
		t.Fatalf("want 3 ops, got %d: %+v", len(prog), prog)
	}
	if prog[2].Code != "JMP" || prog[2].Arg != 1 {
		t.Fatalf("loop label must resolve to instruction 1, got %+v", prog[2])
	}

	// Comments and blank lines are ignored.
	prog, err = Assemble("PUSH 1 ; the one\n\nWRITE ; out\n")
	if err != nil {
		t.Fatalf("comments must be accepted: %v", err)
	}
	if len(prog) != 2 {
		t.Fatalf("want 2 ops, got %d: %+v", len(prog), prog)
	}

	// Malformed programs are errors.
	for _, src := range []string{
		"JMP nowhere",    // unknown label
		"FROB 1",         // unknown mnemonic
		"PUSH",           // missing operand
		"JZ",             // missing operand
		"ADD 3",          // non-operand instruction with an operand
		"a:\na:\nPUSH 1", // duplicate label
	} {
		if _, err := Assemble(src); err == nil {
			t.Errorf("%q: expected an assemble error, got none", src)
		}
	}
}

// sumSrc sums 1..n: the full pipeline (labels, comments, OVER, SWAP, SUB
// operand order, JZ, JMP).
const sumSrc = `; sum of 1..n
  READ        ; n
  PUSH 0      ; acc
  SWAP        ; [acc, n]
loop:
  DUP
  JZ done
  SWAP        ; [n, acc]
  OVER        ; [n, acc, n]
  ADD         ; [n, acc+n]
  SWAP        ; [acc+n, n]
  PUSH 1
  SUB         ; [acc+n, n-1]
  JMP loop
done:
  DROP
  WRITE
  HALT
`

func TestSumProgram(t *testing.T) {
	for _, c := range []struct{ n, want int }{{0, 0}, {1, 1}, {5, 15}, {10, 55}} {
		got := run(t, sumSrc, []int{c.n})
		if len(got) != 1 || got[0] != c.want {
			t.Errorf("sum(1..%d): got %v, want [%d]", c.n, got, c.want)
		}
	}
}
