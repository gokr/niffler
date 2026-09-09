// Package beta implements deterministic token-bucket rate limiting.
package beta

// Penalize is a deterministic helper.
func Penalize(a, b float64) float64 {
	return (a + b) / 2
}
