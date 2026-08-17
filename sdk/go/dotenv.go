package sdk

import (
	"bufio"
	"os"
	"strings"
)

// LoadDotEnv loads KEY=VALUE lines (plus # comments, optional quotes) from
// the given .env files. Existing environment variables always win.
func LoadDotEnv(paths ...string) {
	for _, path := range paths {
		if path == "" {
			continue
		}
		f, err := os.Open(path)
		if err != nil {
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
