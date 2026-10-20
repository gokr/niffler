package main

// Document ownership is decided ONCE, when the store boots — never by a tool
// argument (a model-supplied scope would be a privilege boundary, and core's
// clients must never choose whose history they read).
//
// Resolution order for the owner, first hit wins:
//
//	NIF_INSTANCE_ID                     explicit bootstrap override
//	$NIF_ROOT/var/instance-id           the durable identity the harness wrote
//	"" (legacy)                         no identity available: single-instance
//	                                    or test mode, reported as unbound
//
// The empty owner is NOT a shared-deployment mode: two instances that both
// run unbound write the same keys. Shared TiDB deployments must supply an
// identity, which is why an already-bound dataset refuses a different one.
import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func validInstanceID(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, c := range id {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// resolveStoreIdentity finds this process's instance identity without ever
// creating one: the store must not invent an identity the harness does not
// know about (core registers whatever var/instance-id holds).
func resolveStoreIdentity() string {
	if id := strings.TrimSpace(os.Getenv("NIF_INSTANCE_ID")); id != "" {
		if !validInstanceID(id) {
			fmt.Fprintln(os.Stderr, "store: ignoring malformed NIF_INSTANCE_ID")
			return ""
		}
		return id
	}
	// A shared dataset has no local file to be authoritative about, so the
	// root read is the same convenience path, not a substitute for an
	// identity when the deployment is actually shared.
	root := os.Getenv("NIF_ROOT")
	if root == "" {
		root = "."
	}
	raw, err := os.ReadFile(filepath.Join(root, "var", "instance-id"))
	if err != nil {
		return ""
	}
	id := strings.TrimSpace(string(raw))
	if !validInstanceID(id) {
		fmt.Fprintln(os.Stderr, "store: ignoring malformed var/instance-id")
		return ""
	}
	return id
}

// documentOwner applies the resolved owner to handlers built by tests and by
// main. Absent means legacy ("").
func documentOwner(owner []string) string {
	if len(owner) == 0 {
		return ""
	}
	return owner[0]
}
