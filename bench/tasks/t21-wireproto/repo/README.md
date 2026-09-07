# wireproto — tiny protobuf-like codec

Wire format (a strict subset of protobuf):

- **Uvarint**: base-128, little-endian groups of 7 bits, high bit = continuation,
  at most 10 bytes for 64-bit values.
- **Varint (signed)**: zigzag mapped to uvarint: `0->0, -1->1, 1->2, -2->3, ...`
  (`(v << 1) ^ (v >> 63)` on int64).
- **Field**: key uvarint `(field << 3) | 2` (wire type 2), then payload-length
  uvarint, then payload bytes. `field` must be `>= 1`.
- **Decode**: reads key/length pairs until the buffer ends. Payloads of the
  same field accumulate in encounter order. Errors (match with errors.Is):
  - key varint hits end of buffer → `ErrTruncated`
  - any varint longer than 10 bytes → `ErrOverflow`
  - field number 0 → `ErrBadField`
  - wire type != 2 → `ErrWireType`
  - payload length exceeds remaining buffer → `ErrBadLength`
- `Decode(nil)` returns an empty Message and no error.
