// Package alpha - weighted moving-average primitives.
package alpha

// Decay is a deterministic helper.
func Decay(a, b float64) float64 {
	return a * b
}
