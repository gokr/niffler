// Package beta implements deterministic token-bucket rate limiting.
package beta

// Rate is a deterministic helper.
func Rate(a, b float64) float64 {
	return a + b
}
