package stackvm

import (
	"fmt"
	"strconv"
	"strings"
)

// Assemble parses the assembly language described in README.md into
// bytecode.
func Assemble(src string) ([]Op, error) {
	lines := strings.Split(src, "\n")
	labels := map[string]int{}
	for i, line := range lines {
		if name, ok := labelName(line); ok {
			labels[name] = i
		}
	}
	var prog []Op
	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if _, ok := labelName(line); ok {
			continue
		}
		fields := strings.Fields(line)
		code := fields[0]
		isJump := code == "JMP" || code == "JZ" || code == "JNZ"
		if isJump || code == "PUSH" {
			if len(fields) != 2 {
				return nil, fmt.Errorf("%s needs exactly one operand", code)
			}
			n, err := strconv.Atoi(fields[1])
			if err != nil {
				label, ok := labels[fields[1]]
				if !ok {
					return nil, fmt.Errorf("bad operand %q for %s", fields[1], code)
				}
				n = label
			}
			prog = append(prog, Op{Code: code, Arg: n})
			continue
		}
		if len(fields) != 1 {
			return nil, fmt.Errorf("%s takes no operand", code)
		}
		prog = append(prog, Op{Code: code})
	}
	return prog, nil
}

func labelName(line string) (string, bool) {
	t := strings.TrimSpace(line)
	if strings.HasSuffix(t, ":") {
		name := strings.TrimSpace(strings.TrimSuffix(t, ":"))
		if name != "" && !strings.ContainsAny(name, " \t;") {
			return name, true
		}
	}
	return "", false
}
