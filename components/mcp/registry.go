package main

import (
	"fmt"
	"regexp"
	"strings"
)

type registryInput struct {
	Name       string         `json:"name"`
	Type       string         `json:"type"`
	Value      string         `json:"value"`
	Default    string         `json:"default"`
	IsRequired bool           `json:"isRequired"`
	IsSecret   bool           `json:"isSecret"`
	Variables  map[string]any `json:"variables"`
}
type registryServer struct {
	Name        string `json:"name"`
	Title       string `json:"title"`
	Description string `json:"description"`
	Version     string `json:"version"`
	Packages    []struct {
		RegistryType string `json:"registryType"`
		Identifier   string `json:"identifier"`
		Version      string `json:"version"`
		Transport    struct {
			Type string `json:"type"`
		} `json:"transport"`
		RuntimeArguments     []registryInput `json:"runtimeArguments"`
		PackageArguments     []registryInput `json:"packageArguments"`
		EnvironmentVariables []registryInput `json:"environmentVariables"`
	} `json:"packages"`
	Remotes []struct {
		Type      string          `json:"type"`
		URL       string          `json:"url"`
		Headers   []registryInput `json:"headers"`
		Variables map[string]any  `json:"variables"`
	} `json:"remotes"`
}

var npmIdentifier = regexp.MustCompile(`^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$`)
var pypiIdentifier = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]*$`)
var packageVersion = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._+-]*$`)

func registryCandidate(srv registryServer) registryEntry {
	base := registryEntry{Name: srv.Name, Title: srv.Title, Description: srv.Description, Version: srv.Version}
	candidates := []registryEntry{}
	finish := func(entry registryEntry) registryEntry {
		entry.Installable = len(entry.Requirements) == 0
		if !entry.Installable {
			entry.NotInstallable = "configuration required: " + strings.Join(entry.Requirements, ", ")
		}
		return entry
	}
	values := func(inputs []registryInput, kind string, requirements *[]string) map[string]string {
		out := map[string]string{}
		for _, input := range inputs {
			value := input.Value
			if value == "" && !input.IsSecret {
				value = input.Default
			}
			if strings.ContainsAny(value, "{}") || len(input.Variables) > 0 {
				*requirements = append(*requirements, kind+" "+input.Name+" variables")
				continue
			}
			if value != "" {
				out[input.Name] = value
			} else if input.IsRequired || input.IsSecret {
				// A required input, or any secret without a supplied value,
				// blocks a ready-to-install claim until the caller provides it.
				*requirements = append(*requirements, kind+" "+input.Name)
			}
		}
		return out
	}
	for _, remote := range srv.Remotes {
		if (remote.Type != "streamable-http" && remote.Type != "sse") || remote.URL == "" {
			continue
		}
		entry := base
		entry.Transport = "http"
		if remote.Type == "sse" {
			entry.Transport = "sse"
		}
		entry.URL = remote.URL
		if strings.ContainsAny(remote.URL, "{}") || len(remote.Variables) > 0 {
			entry.Requirements = append(entry.Requirements, "endpoint variables")
		}
		headers := values(remote.Headers, "header", &entry.Requirements)
		entry.Config = map[string]any{"name": registrySuggestedName(srv.Name), "type": entry.Transport, "url": entry.URL}
		if len(headers) > 0 {
			entry.Config["headers"] = headers
		}
		candidates = append(candidates, finish(entry))
	}
	for _, pkg := range srv.Packages {
		if pkg.Transport.Type != "stdio" {
			continue
		}
		entry := base
		entry.Transport = "stdio"
		if !packageVersion.MatchString(pkg.Version) {
			continue
		}
		identifier := pkg.Identifier
		switch pkg.RegistryType {
		case "npm":
			if !npmIdentifier.MatchString(identifier) {
				continue
			}
			entry.Command = "npx"
			identifier += "@" + pkg.Version
		case "pypi":
			if !pypiIdentifier.MatchString(identifier) {
				continue
			}
			entry.Command = "uvx"
			identifier += "==" + pkg.Version
		default:
			continue
		}
		buildArgs := func(inputs []registryInput) []string {
			args := []string{}
			for i, input := range inputs {
				value := input.Value
				if value == "" && !input.IsSecret {
					value = input.Default
				}
				if len(input.Variables) > 0 || strings.ContainsAny(value, "{}") || value == "" && input.IsRequired {
					entry.Requirements = append(entry.Requirements, fmt.Sprintf("argument %s/%d", input.Name, i))
					continue
				}
				if value == "" {
					continue
				}
				if input.Type == "named" {
					if !strings.HasPrefix(input.Name, "-") {
						entry.Requirements = append(entry.Requirements, "invalid named argument "+input.Name)
						continue
					}
					args = append(args, input.Name)
				}
				args = append(args, value)
			}
			return args
		}
		runtimeArgs := buildArgs(pkg.RuntimeArguments)
		if entry.Command == "npx" && !contains(runtimeArgs, "-y") && !contains(runtimeArgs, "--yes") {
			runtimeArgs = append([]string{"-y"}, runtimeArgs...)
		}
		entry.Args = append(runtimeArgs, identifier)
		entry.Args = append(entry.Args, buildArgs(pkg.PackageArguments)...)
		env := values(pkg.EnvironmentVariables, "environment", &entry.Requirements)
		entry.Config = map[string]any{"name": registrySuggestedName(srv.Name), "type": "stdio", "command": entry.Command, "args": entry.Args}
		if len(env) > 0 {
			entry.Config["env"] = env
		}
		candidates = append(candidates, finish(entry))
	}
	for _, entry := range candidates {
		if entry.Installable {
			return entry
		}
	}
	if len(candidates) > 0 {
		return candidates[0]
	}
	base.NotInstallable = "no supported http/sse remote or versioned npm/pypi stdio package"
	return base
}
func contains(items []string, value string) bool {
	for _, s := range items {
		if s == value {
			return true
		}
	}
	return false
}
