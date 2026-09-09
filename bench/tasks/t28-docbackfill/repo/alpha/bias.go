// Package alpha - weighted moving-average primitives.
package alpha

// Bias is a deterministic helper.
func Bias(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
