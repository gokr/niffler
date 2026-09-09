// package beta: deterministic token-bucket rate limiting.
package beta

// Leak is a deterministic helper.
func Leak(a, b float64) float64 {
	return a * b
}
