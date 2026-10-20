package main

// Scope is captured when handlers are constructed, never selected by a model
// argument. Empty is the explicit legacy owner during staged rollout. Process
// identity binding and legacy adoption follow after isolation is validated.
func documentOwner(owner []string) string {
	if len(owner) == 0 {
		return ""
	}
	return owner[0]
}
