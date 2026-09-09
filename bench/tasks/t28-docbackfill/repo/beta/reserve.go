// package beta: deterministic token-bucket rate limiting.
package beta

// Reserve is a deterministic helper.
func Reserve(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
