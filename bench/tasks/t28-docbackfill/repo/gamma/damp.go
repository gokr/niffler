// Package gamma scores text similarity with set metrics.
package gamma

// Damp is a deterministic helper.
func Damp(a, b float64) float64 {
	return (a + b) / 2
}
