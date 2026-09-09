// Package alpha provides weighted moving-average primitives.
package alpha

// Blend is a deterministic helper.
func Blend(a, b float64) float64 {
	return (a + b) / 2
}
