package sdk

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Typed access to the store component's document contract
// (put/get/list/del, docs/WIRE.md). One layer instead of per-component
// "store unreachable" boilerplate; the store's error codes become sentinel
// errors so call sites read as intent (fail closed vs best effort) rather
// than ok-flag chains. Mirrors sdk/niffler/sdk.nim's store client 1:1.

// Store access errors — typed so callers can distinguish a concurrency race
// or a miss from a store outage (which arrives as the bus layer's error).
var (
	// ErrStoreConflict reports a put whose expectRev lost an
	// optimistic-concurrency race.
	ErrStoreConflict = errors.New("store: revision conflict")
	// ErrStoreNotFound reports a get for an absent document.
	ErrStoreNotFound = errors.New("store: not found")
)

// StoreItem is one document from the store.
type StoreItem struct {
	ID    string          `json:"id"`
	Rev   int             `json:"rev"`
	Value json.RawMessage `json:"value"`
}

type storeReply struct {
	OK         *bool  `json:"ok"`
	Error      string `json:"error"`
	Code       string `json:"code"`
	CurrentRev *int   `json:"currentRev"`
}

// storeCall is Request plus the store's ok-check with the error-code
// mapping. An unreachable store arrives as the bus layer's error from
// Request itself and passes through unchanged.
func (c *Component) storeCall(tool, kind, id string, args any, timeout time.Duration) (json.RawMessage, error) {
	raw, err := c.Request("store", tool, args, timeout)
	if err != nil {
		return nil, err
	}
	var reply storeReply
	if err := json.Unmarshal(raw, &reply); err != nil {
		return raw, nil // not the {ok} convention's shape — pass through
	}
	if reply.OK == nil || *reply.OK {
		return raw, nil
	}
	switch reply.Code {
	case "rev-conflict":
		if reply.CurrentRev != nil {
			return nil, fmt.Errorf("%w (current rev %d)", ErrStoreConflict, *reply.CurrentRev)
		}
		return nil, ErrStoreConflict
	case "not-found":
		return nil, ErrStoreNotFound
	}
	if reply.Error != "" {
		return nil, errors.New(reply.Error)
	}
	return nil, errors.New("store call failed")
}

// StorePut upserts a document (kind/id) into the store and returns its new
// revision. expectRev > 0 fails with ErrStoreConflict when the current
// revision differs (optimistic concurrency).
func (c *Component) StorePut(kind, id string, value any, expectRev int, timeout time.Duration) (int, error) {
	raw, err := c.storeCall("put", kind, id, map[string]any{
		"kind": kind, "id": id, "value": value, "expectRev": expectRev,
	}, timeout)
	if err != nil {
		return 0, err
	}
	var reply struct {
		Rev int `json:"rev"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return 0, err
	}
	return reply.Rev, nil
}

// StoreGet fetches a document by kind and id; ErrStoreNotFound when absent.
func (c *Component) StoreGet(kind, id string, timeout time.Duration) (*StoreItem, error) {
	raw, err := c.storeCall("get", kind, id,
		map[string]any{"kind": kind, "id": id}, timeout)
	if err != nil {
		return nil, err
	}
	var reply struct {
		Rev   int             `json:"rev"`
		Value json.RawMessage `json:"value"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return nil, err
	}
	return &StoreItem{ID: id, Rev: reply.Rev, Value: reply.Value}, nil
}

// StoreList lists documents of a kind, ordered by id, optionally filtered
// by an id prefix. limit is capped by the store itself.
func (c *Component) StoreList(kind, idPrefix string, limit int, timeout time.Duration) ([]StoreItem, error) {
	raw, err := c.storeCall("list", kind, idPrefix, map[string]any{
		"kind": kind, "idPrefix": idPrefix, "limit": limit,
	}, timeout)
	if err != nil {
		return nil, err
	}
	var reply struct {
		Items []StoreItem `json:"items"`
	}
	if err := json.Unmarshal(raw, &reply); err != nil {
		return nil, err
	}
	if reply.Items == nil {
		return []StoreItem{}, nil
	}
	return reply.Items, nil
}

// StoreDel deletes a document; idempotent (a missing target is not an error).
func (c *Component) StoreDel(kind, id string, timeout time.Duration) error {
	_, err := c.storeCall("del", kind, id,
		map[string]any{"kind": kind, "id": id}, timeout)
	return err
}
