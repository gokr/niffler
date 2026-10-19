"use strict";

// The TS SDK's tool-result image helpers: the counterpart of the Nim SDK's
// resultImage/withImages and the Go SDK's ResultImage/WithImages. A result may
// carry `images` beside `text` (docs/WIRE.md "Tool results"), which is the one
// channel by which a component returns something the model SEES. Core owns the
// bound (byte-sniffed allowlist, caps, projection), so these helpers only build
// the wire shape and must not invent anything core does not read.

const assert = require("node:assert/strict");
const { resultImage, withImages, okResult } = require("../dist");

function main() {
  const image = resultImage("AAAA", "image/png", {
    name: "shot.png",
    width: 1280,
    height: 800,
  });
  assert.equal(image.type, "image");
  assert.equal(image.data, "AAAA");
  assert.equal(image.mimeType, "image/png");
  assert.equal(image.name, "shot.png");
  assert.equal(image.width, 1280);
  assert.equal(image.height, 800);

  // Advisory metadata is omitted when unknown rather than sent as zero: a 0x0
  // dimension would read as a real measurement to the caption.
  const bare = resultImage("AAAA", "image/png");
  for (const key of ["name", "width", "height"]) {
    assert.ok(!(key in bare), `resultImage sent ${key} for an unknown value`);
  }
  // The pixels are RAW base64: the data-URL prefix belongs to the provider
  // projection core builds, not to the result field.
  assert.ok(!("url" in bare), "resultImage must not pre-build a data URL");
  // An explicit zero is still omitted (0 is not a dimension).
  assert.ok(!("width" in resultImage("AAAA", "image/png", { width: 0 })));

  const result = withImages(okResult({ text: "[image: shot.png]" }), [image]);
  assert.equal(result.ok, true);
  assert.equal(result.text, "[image: shot.png]");
  assert.equal(result.images.length, 1);
  assert.equal(result.images[0].data, "AAAA");

  // withImages must not mutate its input (handlers reuse result objects).
  const base = { text: "x" };
  const attached = withImages(base, [image]);
  assert.ok(!("images" in base), "withImages mutated its argument");
  assert.equal(attached.text, "x");

  console.log("OK: resultImage carries the wire shape");
  console.log("OK: withImages attaches images beside text");
  console.log("WIRE IMAGES TEST PASSED");
}

main();
