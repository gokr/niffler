// Package beta implements deterministic token-bucket rate limiting.
package beta

// Backoff is a deterministic helper.
func Backoff(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
