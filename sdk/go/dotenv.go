package sdk

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// trustedRoot is the directory a .env may come from, or "" when there is none.
//
// ResolveNatsUrl's home root is right for BUS discovery (a binary in
// <root>/var/bin resolves that clone), but as a TRUST anchor it is unsound on
// its own: for a binary outside that layout, climbing three directories lands
// on "/" or "/tmp", which would make every path "inside the root" (verified —
// a hostile .env then loaded). So an explicit NIF_ROOT is trusted, and a
// derived root counts only when it actually looks like a clone (niffler.nimble
// or a var/bin directory). No trusted root means no .env is loaded at all:
// the environment is then the only source, which is the safe answer.
func trustedRoot() string {
	if explicit := os.Getenv("NIF_ROOT"); explicit != "" {
		if abs, err := filepath.Abs(explicit); err == nil {
			return resolvePath(abs)
		}
		return ""
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	root := filepath.Dir(filepath.Dir(filepath.Dir(resolvePath(exe))))
	if !looksLikeClone(root) {
		return ""
	}
	return root
}

// resolvePath returns an absolute path with symlinks resolved where possible
// (a path that does not exist yet keeps its absolute spelling).
func resolvePath(p string) string {
	abs, err := filepath.Abs(p)
	if err != nil {
		abs = p
	}
	if resolved, err := filepath.EvalSymlinks(abs); err == nil {
		return resolved
	}
	return abs
}

func looksLikeClone(root string) bool {
	if _, err := os.Stat(filepath.Join(root, "niffler.nimble")); err == nil {
		return true
	}
	info, err := os.Stat(filepath.Join(root, "var", "bin"))
	return err == nil && info.IsDir()
}

// withinHarnessRoot reports whether path IS the harness root's own .env —
// <root>/.env and nothing else. Containment alone would not be enough: a
// conversation workspace and a plugin checkout both live INSIDE the root, so a
// committed .env in one of those checkouts is precisely the file that must not
// be honoured.
func withinHarnessRoot(path string) bool {
	root := trustedRoot()
	if root == "" {
		return false
	}
	return resolvePath(path) == filepath.Join(root, ".env")
}

// LoadDotEnv loads KEY=VALUE lines (plus # comments, optional quotes) from
// the given .env files. Existing environment variables always win.
//
// Only the harness root's own .env is honoured (see trustedRoot). A .env
// sitting in an arbitrary working directory must never be read: the harness is
// routinely launched from inside the repositories it is working on, and a
// committed .env there would otherwise hand that repository
// NIF_AUTO_APPROVE=1 (approval bypass) or a NIF_NATS_URL pointing at a bus it
// controls. A refused file is reported on stderr, so a legitimate
// misconfiguration stays diagnosable instead of disappearing silently.
func LoadDotEnv(paths ...string) {
	for _, path := range paths {
		if path == "" {
			continue
		}
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		if !withinHarnessRoot(path) {
			fmt.Fprintf(os.Stderr, "dotenv: IGNORING .env — only <root>/.env is trusted:"+
				" %s (a working directory is not a trust boundary)\n", path)
			f.Close()
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			eq := strings.Index(line, "=")
			if eq <= 0 {
				continue
			}
			key := strings.TrimSpace(line[:eq])
			value := strings.TrimSpace(line[eq+1:])
			value = strings.Trim(value, `"`)
			if key != "" && os.Getenv(key) == "" {
				os.Setenv(key, value)
			}
		}
		f.Close()
	}
}
