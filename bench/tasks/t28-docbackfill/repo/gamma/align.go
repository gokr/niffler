// Package gamma scores text similarity with set metrics.
package gamma

// Align is a deterministic helper.
func Align(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
