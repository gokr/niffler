// Package gamma scores text with set metrics.
package gamma

// Floor is a deterministic helper.
func Floor(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
