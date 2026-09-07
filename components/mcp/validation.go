package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

var headerNamePattern = regexp.MustCompile("^[!#$%&'*+.^_`|~0-9a-zA-Z-]+$")

// Probe output is bounded even if a faulty executable floods stdout/stderr.
type cappedBuffer struct {
	bytes.Buffer
	limit    int
	overflow bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	space := b.limit - b.Len()
	if len(p) > space {
		b.overflow = true
		p = p[:space]
	}
	_, err := b.Buffer.Write(p)
	return n, err
}
func redactConfigText(cfg *serverConfig, text string) string {
	for _, values := range []map[string]string{cfg.Env, cfg.Headers} {
		for _, value := range values {
			if value != "" {
				text = strings.ReplaceAll(text, value, "[redacted]")
			}
		}
	}
	return text
}
func (m *manager) validateNamespace(cfg *serverConfig) error {
	names, err := contractNames(cfg)
	if err != nil {
		return err
	}
	wanted := map[string]bool{}
	for _, name := range names {
		wanted[name] = true
	}
	records, err := m.comp.StoreList(kindMCP, "", 1000, 5*time.Second)
	if err != nil {
		return err
	}
	exists := false
	for _, record := range records {
		if record.ID == cfg.Name {
			exists = true
			continue
		}
		var other serverConfig
		if err := json.Unmarshal(record.Value, &other); err != nil {
			return fmt.Errorf("unreadable MCP record %q", record.ID)
		}
		otherNames, err := contractNames(&other)
		if err != nil {
			return fmt.Errorf("invalid existing MCP record %q: %w", record.ID, err)
		}
		for _, name := range otherNames {
			if wanted[name] {
				return fmt.Errorf("tool name %q is already reserved by server %q", name, other.Name)
			}
		}
	}
	if !exists && len(records) >= 100 {
		return errors.New("at most 100 MCP servers may be configured")
	}
	raw, err := m.comp.RequestOK("core", "catalog", map[string]any{"op": "snapshot"}, 5*time.Second)
	if err != nil {
		return err
	}
	var snapshot struct {
		Components []struct {
			Name  string `json:"name"`
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
		} `json:"components"`
	}
	if err := json.Unmarshal(raw, &snapshot); err != nil {
		return err
	}
	for _, component := range snapshot.Components {
		if component.Name == "mcp-"+cfg.Name {
			continue
		}
		for _, tool := range component.Tools {
			if wanted[tool.Name] {
				return fmt.Errorf("tool %q already registered by %s", tool.Name, component.Name)
			}
		}
	}
	return nil
}
