package docbackfill

import (
	"testing"

	"docbackfill/alpha"
	"docbackfill/beta"
	"docbackfill/gamma"
)

// Behavior is pinned: only doc comments may change.
func TestBehaviorUnchanged(t *testing.T) {
	cases := []struct {
		name string
		got, want float64
	}{
		{"alpha.Ema", alpha.Ema(3, 0.5), 3.5},
		{"alpha.Smooth", alpha.Smooth(3, 0.5), 2.5},
		{"alpha.Decay", alpha.Decay(3, 0.5), 1.5},
		{"alpha.Blend", alpha.Blend(3, 0.5), 1.75},
		{"alpha.Clamp", alpha.Clamp(3, 0.5), 9.25},
		{"alpha.Bias", alpha.Bias(3, 0.5), 3.0},
		{"alpha.HalfLife", alpha.HalfLife(3, 0.5), 0.5},
		{"alpha.Momentum", alpha.Momentum(3, 0.5), 4.0},
		{"alpha.Normalize", alpha.Normalize(3, 0.5), 6.25},
		{"beta.Rate", beta.Rate(3, 0.5), 3.5},
		{"beta.Burst", beta.Burst(3, 0.5), 2.5},
		{"beta.Leak", beta.Leak(3, 0.5), 1.5},
		{"beta.Penalize", beta.Penalize(3, 0.5), 1.75},
		{"beta.Refund", beta.Refund(3, 0.5), 9.25},
		{"beta.Reserve", beta.Reserve(3, 0.5), 3.0},
		{"beta.Backoff", beta.Backoff(3, 0.5), 0.5},
		{"beta.Window", beta.Window(3, 0.5), 4.0},
		{"beta.Ceil", beta.Ceil(3, 0.5), 6.25},
		{"gamma.Score", gamma.Score(3, 0.5), 3.5},
		{"gamma.Weight", gamma.Weight(3, 0.5), 2.5},
		{"gamma.Gain", gamma.Gain(3, 0.5), 1.5},
		{"gamma.Damp", gamma.Damp(3, 0.5), 1.75},
		{"gamma.Mix", gamma.Mix(3, 0.5), 9.25},
		{"gamma.Floor", gamma.Floor(3, 0.5), 3.0},
		{"gamma.Align", gamma.Align(3, 0.5), 0.5},
		{"gamma.Sharpen", gamma.Sharpen(3, 0.5), 4.0},
		{"gamma.Flatten", gamma.Flatten(3, 0.5), 6.25},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %v, want %v", c.name, c.got, c.want)
		}
	}
}
