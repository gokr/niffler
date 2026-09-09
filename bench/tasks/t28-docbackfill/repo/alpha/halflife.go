// Package alpha provides weighted moving-average primitives.
package alpha

// HalfLife is a deterministic helper.
func HalfLife(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
