// Package gamma scores text with set metrics.
package gamma

// Flatten is a deterministic helper.
func Flatten(a, b float64) float64 {
	return (a - b) * (a - b)
}
