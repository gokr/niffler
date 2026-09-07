// Package wireproto implements a tiny protobuf-like binary codec:
// unsigned/signed varints and length-delimited fields (wire type 2).
// See README.md for the exact wire format and error rules.
package wireproto

import "errors"

var (
	ErrTruncated = errors.New("wireproto: truncated varint")
	ErrOverflow  = errors.New("wireproto: varint exceeds 64 bits")
	ErrBadField  = errors.New("wireproto: invalid field number")
	ErrWireType  = errors.New("wireproto: unsupported wire type")
	ErrBadLength = errors.New("wireproto: field length exceeds buffer")
)

// AppendUvarint appends the base-128 varint of v (protobuf encoding).
func AppendUvarint(b []byte, v uint64) []byte {
	// TODO
	return b
}

// AppendVarint appends the zigzag-encoded varint of v (sint64 semantics:
// 0->0, -1->1, 1->2, -2->3, ...).
func AppendVarint(b []byte, v int64) []byte {
	// TODO
	return b
}

// AppendField appends a length-delimited field: key = (field<<3)|2 as a
// uvarint, then the payload length as a uvarint, then the payload bytes.
// field must be >= 1.
func AppendField(b []byte, field int, payload []byte) []byte {
	// TODO
	return b
}

// Message holds decoded fields in encounter order.
type Message struct {
	// Fields maps field number -> payloads in order of appearance.
	Fields map[int][][]byte
}

// Decode parses data into a Message. Only wire type 2 (length-delimited)
// is supported; anything else is ErrWireType. Field number 0 is ErrBadField.
// Truncated varints are ErrTruncated; varints longer than 10 bytes (or
// overflowing 64 bits) are ErrOverflow; a payload longer than the remaining
// buffer is ErrBadLength. Use errors.Is to match.
func Decode(data []byte) (*Message, error) {
	// TODO
	return nil, nil
}
