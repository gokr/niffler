## Test-only component: a tool that returns images (docs/WIRE.md "Tool
## results"). Nothing shipped does this yet, and the contract is core's —
## validation, storage, projection, elision — so the fixture exists to hand
## core results it could not otherwise be shown:
##
##   img_ok    a 1x1 PNG on the result's `images` array, plus a caption.
##   img_bad   bytes that are NOT an image (a client/component lying).
##   img_many  more images than one result may contribute.
##   img_huge  a valid PNG over the per-image cap.
##   img_meta  a valid image whose declared MIME disagrees with its bytes.
##
## Provenance and dimensions are what a real producer reports (Maki's
## view_image: format, size, dimensions); the tests assert core keeps the
## caption and corrects the format.

import std/[base64, json, strutils]
import niffler/sdk

const
  # 1x1 PNG.
  pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
  # 1x1 JPEG.
  jpegB64 = "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q=="

proc img(name, mime, data: string, w, h: int): JsonNode =
  ## Built with the SDK's own helper (sdk/niffler/sdk.nim resultImage) rather
  ## than a hand-rolled object: the fixture is also the contract test for what
  ## the SDK tells a component author to produce, so a helper that drifts from
  ## the wire shape fails here instead of in a downstream component.
  resultImage(data, mime, name, w, h)

let comp = newComponent("imagetool", "0.0.1-test")

discard comp.tool("img_ok", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  withImages(%*{"text": "[image: shot.png image/png, 1KB, 1x1]",
                "image": "image/png"},
             [img("shot.png", "image/png", pngB64, 1, 1)]))

discard comp.tool("img_bad", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  # "not an image" in base64: the declared MIME is a lie about the bytes.
  withImages(%*{"text": "here is the picture you asked for"},
             [img("x.png", "image/png", encode("not an image"), 1, 1)]))

discard comp.tool("img_many", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  var many: seq[JsonNode] = @[]
  for i in 0 .. 5:
    many.add(img("s" & $i & ".png", "image/png", pngB64, 1, 1))
  withImages(%*{"text": "six frames"}, many))

discard comp.tool("img_huge", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  # A real PNG header, then padding: large enough to trip the per-image cap
  # while still sniffing as an image (the order of the checks matters).
  let big = base64.decode(pngB64) & repeat('\0', 5_000_000)
  withImages(%*{"text": "a big one"},
             [img("big.png", "image/png", encode(big), 4000, 4000)]))

discard comp.tool("img_meta", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  # JPEG bytes declared as PNG: the bytes must win (same rule as a client's
  # declared MIME on a dropped image).
  withImages(%*{"text": "mislabelled"},
             [img("m.png", "image/png", jpegB64, 1, 1)]))

discard comp.tool("img_none", %*{
  "type": "object", "properties": {},
  "x-harness": {"timeoutMs": 10000},
}, proc(c: Component, args: JsonNode): JsonNode =
  # No images at all: the ordinary result path must be untouched by this
  # whole contract (the regression guard for every existing tool).
  %*{"text": "plain text result", "sizes": [1, 2, 3]})

comp.run()
