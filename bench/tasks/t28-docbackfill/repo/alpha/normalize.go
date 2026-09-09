// Package alpha - weighted moving-average primitives.
package alpha

// Normalize is a deterministic helper.
func Normalize(a, b float64) float64 {
	return (a - b) * (a - b)
}
