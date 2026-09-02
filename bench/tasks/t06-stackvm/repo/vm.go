// Package stackvm implements the tiny stack machine specified in README.md:
// vm.go is the executor, asm.go the text assembler.
package stackvm

import "fmt"

// Op is one instruction: Code is the mnemonic, Arg its operand. PUSH and
// the jumps carry an operand; all other instructions ignore it.
type Op struct {
	Code string
	Arg  int
}

// Execute runs prog with the given inputs and returns everything WRITE
// produced, in order.
func Execute(prog []Op, in ...int) ([]int, error) {
	v := &vm{prog: prog, in: append([]int(nil), in...)}
	for pc := 0; pc < len(v.prog); pc++ {
		op := v.prog[pc]
		switch op.Code {
		case "PUSH":
			v.push(op.Arg)
		case "ADD":
			b, _ := v.pop()
			a, _ := v.pop()
			v.push(a + b)
		case "SUB":
			b, _ := v.pop()
			a, _ := v.pop()
			v.push(b - a)
		case "MUL":
			b, _ := v.pop()
			a, _ := v.pop()
			v.push(a * b)
		case "DUP":
			if err := v.need(1); err != nil {
				return nil, err
			}
			x, _ := v.pop()
			v.push(x, x)
		case "SWAP":
			if err := v.need(3); err != nil {
				return nil, err
			}
			s := v.stack
			s[len(s)-1], s[len(s)-3] = s[len(s)-3], s[len(s)-1]
		case "DROP":
			if err := v.need(1); err != nil {
				return nil, err
			}
			v.pop()
		case "EQ":
			b, _ := v.pop()
			a, _ := v.pop()
			if a == b {
				v.push(1)
			} else {
				v.push(0)
			}
		case "LT":
			b, _ := v.pop()
			a, _ := v.pop()
			if a < b {
				v.push(1)
			} else {
				v.push(0)
			}
		case "JMP":
			pc = op.Arg - 1
		case "JZ":
			c, _ := v.pop()
			if c > 0 {
				pc = op.Arg - 1
			}
		case "JNZ":
			c, _ := v.pop()
			if c != 0 {
				pc = op.Arg - 1
			}
		case "READ":
			if v.inPos >= len(v.in) {
				return nil, fmt.Errorf("input exhausted")
			}
			v.push(v.in[v.inPos])
			v.inPos++
		case "WRITE":
			x, _ := v.pop()
			v.out = append(v.out, x)
		case "HALT":
			return v.out, nil
		default:
			return nil, fmt.Errorf("unknown opcode %q at pc %d", op.Code, pc)
		}
	}
	return v.out, nil
}

type vm struct {
	prog  []Op
	stack []int
	in    []int
	inPos int
	out   []int
}

func (v *vm) push(xs ...int) { v.stack = append(v.stack, xs...) }

func (v *vm) pop() (int, error) {
	if len(v.stack) == 0 {
		return 0, nil
	}
	x := v.stack[len(v.stack)-1]
	v.stack = v.stack[:len(v.stack)-1]
	return x, nil
}

func (v *vm) need(n int) error {
	if len(v.stack) < n {
		return fmt.Errorf("stack underflow: need %d elements, have %d", n, len(v.stack))
	}
	return nil
}
