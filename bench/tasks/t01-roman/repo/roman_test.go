package roman

import "testing"

func TestRoman(t *testing.T) {
	cases := []struct {
		in   int
		want string
	}{
		{1, "I"}, {2, "II"}, {4, "IV"}, {9, "IX"}, {14, "XIV"},
		{40, "XL"}, {90, "XC"}, {400, "CD"}, {900, "CM"},
		{1994, "MCMXCIV"}, {2026, "MMXXVI"}, {3999, "MMMCMXCIX"},
	}
	for _, c := range cases {
		if got := Roman(c.in); got != c.want {
			t.Errorf("Roman(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRomanRange(t *testing.T) {
	for _, n := range []int{0, -1, 4000, 10000} {
		if got := Roman(n); got != "" {
			t.Errorf("Roman(%d) = %q, want \"\" for out-of-range", n, got)
		}
	}
}
