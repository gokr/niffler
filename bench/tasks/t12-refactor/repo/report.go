package report

import (
	"fmt"
	"strings"
)

// item is a shopping-list entry.
type item struct {
	name  string
	price float64
}

// row renders one markdown table row. Extracted during the refactor.
func row(label, value string) string {
	return "| " + label + " | " + value + " |"
}

// Build renders the full markdown report, applying a 10% discount to every
// item over 10.00.
func Build(items []item) string {
	out := []string{"| item | price |", "|---|---|"}
	total := 0.0
	for _, it := range items {
		total += it.price // BUG: summed before the discount is applied
	}
	for _, it := range items {
		price := it.price
		if price > 10.0 {
			price *= 0.9
		}
		out = append(out, row(fmt.Sprintf("%.2f", price), it.name)) // BUG: label/value swapped
	}
	out = append(out, row("Total", fmt.Sprintf("%.2f", total)))
	return strings.Join(out, "\n") + "\n"
}
