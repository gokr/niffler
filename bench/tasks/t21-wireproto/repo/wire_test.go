package wireproto

import (
	"bytes"
	"errors"
	"math"
	"testing"
)

func TestUvarintVectors(t *testing.T) {
	cases := []struct {
		v    uint64
		want []byte
	}{
		{0, []byte{0x00}}, {1, []byte{0x01}}, {127, []byte{0x7f}},
		{128, []byte{0x80, 0x01}}, {300, []byte{0xac, 0x02}},
		{16384, []byte{0x80, 0x80, 0x01}},
		{math.MaxUint64, []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}},
	}
	for _, c := range cases {
		got := AppendUvarint(nil, c.v)
		if !bytes.Equal(got, c.want) {
			t.Fatalf("uvarint(%d) = % x, want % x", c.v, got, c.want)
		}
	}
}

func TestZigzagVectors(t *testing.T) {
	cases := []struct {
		v    int64
		want []byte
	}{
		{0, []byte{0x00}}, {-1, []byte{0x01}}, {1, []byte{0x02}},
		{-2, []byte{0x03}}, {math.MaxInt32, []byte{0xfe, 0xff, 0xff, 0xff, 0x0f}},
		{math.MinInt64, []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}},
		{math.MaxInt64, []byte{0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}},
	}
	for _, c := range cases {
		got := AppendVarint(nil, c.v)
		if !bytes.Equal(got, c.want) {
			t.Fatalf("varint(%d) = % x, want % x", c.v, got, c.want)
		}
	}
}

func TestAppendField(t *testing.T) {
	got := AppendField(nil, 1, []byte("hi"))
	want := []byte{0x0a, 0x02, 'h', 'i'}
	if !bytes.Equal(got, want) {
		t.Fatalf("field 1 = % x, want % x", got, want)
	}
	got = AppendField(nil, 2, []byte("abc"))
	want = []byte{0x12, 0x03, 'a', 'b', 'c'}
	if !bytes.Equal(got, want) {
		t.Fatalf("field 2 = % x, want % x", got, want)
	}
}

func TestDecodeRoundTrip(t *testing.T) {
	var buf []byte
	buf = AppendField(buf, 1, []byte("hi"))
	buf = AppendField(buf, 2, []byte("abc"))
	buf = AppendField(buf, 1, []byte("again")) // repeated field
	m, err := Decode(buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Fields[1]) != 2 || string(m.Fields[1][0]) != "hi" || string(m.Fields[1][1]) != "again" {
		t.Fatalf("field 1 = %q", m.Fields[1])
	}
	if string(m.Fields[2][0]) != "abc" {
		t.Fatalf("field 2 = %q", m.Fields[2])
	}
}

func TestDecodeEmpty(t *testing.T) {
	m, err := Decode(nil)
	if err != nil || m == nil || len(m.Fields) != 0 {
		t.Fatalf("empty input: m=%v err=%v", m, err)
	}
}

func TestDecodeErrors(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want error
	}{
		{"truncated varint", []byte{0x80}, ErrTruncated},
		{"varint overflow 11 bytes", []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01}, ErrOverflow},
		{"field 0", []byte{0x02, 0x00}, ErrBadField},
		{"wire type 0", []byte{0x08, 0x01}, ErrWireType},
		{"length beyond buffer", []byte{0x0a, 0x05, 'a'}, ErrBadLength},
	}
	for _, c := range cases {
		_, err := Decode(c.data)
		if !errors.Is(err, c.want) {
			t.Fatalf("%s: got %v, want %v", c.name, err, c.want)
		}
	}
}

func TestDecodeLargeFieldNumber(t *testing.T) {
	// field 15 payload "x": key = (15<<3)|2 = 122 = 0x7a
	buf := AppendField(nil, 15, []byte("x"))
	m, err := Decode(buf)
	if err != nil || string(m.Fields[15][0]) != "x" {
		t.Fatalf("field 15: m=%v err=%v", m, err)
	}
}
