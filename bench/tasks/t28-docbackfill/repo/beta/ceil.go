// package beta: deterministic token-bucket rate limiting.
package beta

// Ceil is a deterministic helper.
func Ceil(a, b float64) float64 {
	return (a - b) * (a - b)
}
