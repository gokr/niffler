// Owner half of the configuration surface (docs/research/CONFIG-CONTRACT.md),
// mirroring sdk/niffler/configowner.nim.
//
// A component that owns settings keeps owning them: its values stay in its own
// store record, written by its own code. This removes the boilerplate every
// owner would otherwise repeat — the get/patch/reset protocol, the
// compare-and-set write, the idempotent declaration, and the
// stored > env > default read — while leaving the decisions to the owner.
//
// No wire change: the declaration is published through the existing
// config_declare tool, so nothing here affects the envelope or the other SDKs.
package sdk

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// OwnerStore names where an owner keeps its values.
type OwnerStore struct {
	Kind string // store kind holding this owner's values
	ID   string // store id inside that kind ("main" for a singleton)
}

type ownerValues struct {
	Values map[string]any `json:"values"`
}

// LoadOwnerValues reads the current explicit values and their revision. An
// absent record is an empty configuration at revision 0.
func (c *Component) LoadOwnerValues(store OwnerStore, timeout time.Duration) (map[string]any, int) {
	item, err := c.StoreGet(store.Kind, store.ID, timeout)
	if err != nil {
		return map[string]any{}, 0
	}
	var doc ownerValues
	if err := json.Unmarshal(item.Value, &doc); err != nil || doc.Values == nil {
		return map[string]any{}, item.Rev
	}
	return doc.Values, item.Rev
}

// OwnerGet answers the `get` operation config_get forwards.
func (c *Component) OwnerGet(store OwnerStore, timeout time.Duration) any {
	values, rev := c.LoadOwnerValues(store, timeout)
	return map[string]any{"ok": true, "values": values, "rev": rev}
}

// OwnerPatch applies a merge patch under compare-and-set. config has already
// validated the schema; this owns the write. A stale revision is a refusal,
// never a lost update. An explicit nil UNSETS a value (that is how a secret is
// cleared); it is not the same as omitting the property.
func (c *Component) OwnerPatch(store OwnerStore, patch map[string]any, expectRev int, timeout time.Duration) any {
	values, rev := c.LoadOwnerValues(store, timeout)
	if expectRev != -2 && expectRev != rev {
		return map[string]any{"ok": false, "code": "rev-conflict",
			"error": fmt.Sprintf("rev-conflict: revision %d != %d", expectRev, rev)}
	}
	next := make(map[string]any, len(values)+len(patch))
	for k, v := range values {
		next[k] = v
	}
	for k, v := range patch {
		if v == nil {
			delete(next, k)
			continue
		}
		next[k] = v
	}
	newRev, err := c.StorePut(store.Kind, store.ID, ownerValues{Values: next}, rev, timeout)
	if err != nil {
		return map[string]any{"ok": false, "code": "store-unavailable",
			"error": "cannot write settings: " + err.Error()}
	}
	return map[string]any{"ok": true, "rev": newRev, "values": next}
}

// OwnerReset drops explicit values so declared defaults apply again. An empty
// list means every property.
func (c *Component) OwnerReset(store OwnerStore, properties []string, expectRev int, timeout time.Duration) any {
	values, rev := c.LoadOwnerValues(store, timeout)
	if expectRev != -2 && expectRev != rev {
		return map[string]any{"ok": false, "code": "rev-conflict",
			"error": fmt.Sprintf("rev-conflict: revision %d != %d", expectRev, rev)}
	}
	next := make(map[string]any, len(values))
	if len(properties) == 0 {
		next = map[string]any{}
	} else {
		for k, v := range values {
			next[k] = v
		}
		for _, name := range properties {
			delete(next, name)
		}
	}
	if rev == 0 {
		// Nothing stored: writing an empty record would make an untouched
		// domain look configured.
		return map[string]any{"ok": true, "rev": 0, "values": next}
	}
	newRev, err := c.StorePut(store.Kind, store.ID, ownerValues{Values: next}, rev, timeout)
	if err != nil {
		return map[string]any{"ok": false, "code": "store-unavailable",
			"error": "cannot write settings: " + err.Error()}
	}
	return map[string]any{"ok": true, "rev": newRev, "values": next}
}

// OwnerArgs is the decoded owner-tool call config forwards.
type OwnerArgs struct {
	Op         string         `json:"op"`
	Patch      map[string]any `json:"patch"`
	Properties []string       `json:"properties"`
	ExpectRev  *int           `json:"expectRev"`
}

// OwnerOp dispatches one get/patch/reset call. An unknown op refuses rather
// than defaulting to a read, so a caller bug cannot look like success.
func (c *Component) OwnerOp(store OwnerStore, args OwnerArgs, timeout time.Duration) any {
	expect := -2
	if args.ExpectRev != nil {
		expect = *args.ExpectRev
	}
	switch args.Op {
	case "get":
		return c.OwnerGet(store, timeout)
	case "patch":
		return c.OwnerPatch(store, args.Patch, expect, timeout)
	case "reset":
		return c.OwnerReset(store, args.Properties, expect, timeout)
	default:
		return map[string]any{"ok": false, "code": "bad-request",
			"error": "unsupported config op '" + args.Op + "'"}
	}
}

// Declaration is the shape every owner publishes through config_declare.
// Application is required and typed, because "when does this take effect" is a
// claim the owner must make deliberately — config refuses a declaration that
// omits it (there is no silent "immediate" default).
type Declaration struct {
	Domain      string         // stable id, unique per owner
	Owner       string         // component that answers get/patch/reset
	OwnerTool   string         // its tool; "" when it owns no state
	Title       string         // presentation
	Description string         //
	Kind        string         // store kind holding the values
	ID          string         // store id; "" for a collection
	Application Application    // when a change takes effect
	Version     int            // declaration revision
	Schema      map[string]any // JSON Schema subset + per-property x-config
}

// Application is the declared timing of a change. Only these four exist.
type Application string

const (
	// Applied on the owner's next read of its values.
	Immediate Application = "immediate"
	// Applied to the next turn, never mid-turn.
	NextTurn Application = "next turn"
	// Applied when the next conversation starts.
	NextConversation Application = "next conversation"
	// Needs the owner restarted (a subscription set, a buffer already sized).
	ComponentRestart Application = "component restart"
)

// Payload renders the declaration as config_declare expects it.
func (d Declaration) Payload() map[string]any {
	version := d.Version
	if version == 0 {
		version = 1
	}
	return map[string]any{
		"domain": d.Domain, "version": version, "owner": d.Owner,
		"ownerTool": d.OwnerTool, "title": d.Title,
		"description": d.Description, "kind": d.Kind, "id": d.ID,
		"application": string(d.Application), "schema": d.Schema,
	}
}

// DeclareConfigAs publishes a declaration. Best effort, like DeclareConfig:
// a harness without the config component is not an error.
func (c *Component) DeclareConfigAs(d Declaration, timeout time.Duration) bool {
	return c.DeclareConfig(d.Payload(), timeout)
}

// OwnerToolSchema is the hidden schema every owner tool shares.
func OwnerToolSchema(domain, description string) map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"op":         map[string]any{"type": "string", "enum": []string{"get", "patch", "reset"}},
			"patch":      map[string]any{"type": "object"},
			"properties": map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
			"expectRev":  map[string]any{"type": "integer"},
		},
		"required": []string{"op"},
		"description": "Owner-side settings protocol for the " + domain +
			" configuration domain. Called by the config component, which validates the schema and enforces approval; never call it directly.",
		"x-harness": map[string]any{"hidden": true},
	}
}

// DeclareConfig publishes this owner's declaration. Best effort by design: a
// harness without the config component is a supported deployment, so a failed
// declaration must not take the owner down — it only means the domain is not
// discoverable. Returns whether it landed.
func (c *Component) DeclareConfig(declaration map[string]any, timeout time.Duration) bool {
	raw, err := c.RequestOK("config", "config_declare",
		map[string]any{"declaration": declaration}, timeout)
	if err != nil {
		return false
	}
	var reply struct {
		OK bool `json:"ok"`
	}
	if json.Unmarshal(raw, &reply) != nil {
		return false
	}
	return reply.OK
}

// SettingString reads one string setting: stored value, else the environment
// (the migration path every owner keeps while its variable is retired), else
// the default.
func SettingString(values map[string]any, name, envName, fallback string) string {
	if v, ok := values[name].(string); ok {
		return v
	}
	if env := strings.TrimSpace(os.Getenv(envName)); env != "" {
		return env
	}
	return fallback
}

// SettingBool reads one boolean setting. The env fallback keeps the historical
// spellings so an existing deployment does not silently flip.
func SettingBool(values map[string]any, name, envName string, fallback bool) bool {
	if v, ok := values[name].(bool); ok {
		return v
	}
	switch strings.ToLower(strings.TrimSpace(os.Getenv(envName))) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return fallback
}

// SettingFloat reads one non-negative float setting (JSON numbers decode as
// float64). A negative stored value is treated as ABSENT rather than as a
// fallback: a nonsense stored value must not mask a valid environment value,
// and it must never silently disable a feature. The schema refuses it too, so
// this is defence in depth against a hand-edited record.
func SettingFloat(values map[string]any, name, envName string, fallback float64) float64 {
	if v, ok := values[name].(float64); ok && v >= 0 {
		return v
	}
	if raw := strings.TrimSpace(os.Getenv(envName)); raw != "" {
		if parsed, err := strconv.ParseFloat(raw, 64); err == nil && parsed >= 0 {
			return parsed
		}
	}
	return fallback
}
