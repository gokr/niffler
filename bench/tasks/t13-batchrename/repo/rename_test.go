package batchrename

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Verify behavior is unchanged under the new name.
func TestCallsReturnDoubles(t *testing.T) {
	cases := map[string]int{
		"f01": 2, "f02": 4, "f03": 6, "f04": 8, "f05": 10,
		"f06": 12, "f07": 14, "f08": 16, "f09": 18, "f10": 20,
		"f11": 22, "f12": 24, "f13": 26, "f14": 28, "f15": 30,
		"f16": 32, "f17": 34, "f18": 36, "f19": 38, "f20": 40,
		"f21": 42, "f22": 44, "f23": 46, "f24": 48, "f25": 50,
	}
	got := map[string]int{}
	for _, f := range []func() int{f01, f02, f03, f04, f05, f06, f07, f08,
		f09, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20,
		f21, f22, f23, f24, f25} {
		_ = f
	}
	got["f01"] = f01()
	got["f02"] = f02()
	got["f03"] = f03()
	got["f04"] = f04()
	got["f05"] = f05()
	got["f06"] = f06()
	got["f07"] = f07()
	got["f08"] = f08()
	got["f09"] = f09()
	got["f10"] = f10()
	got["f11"] = f11()
	got["f12"] = f12()
	got["f13"] = f13()
	got["f14"] = f14()
	got["f15"] = f15()
	got["f16"] = f16()
	got["f17"] = f17()
	got["f18"] = f18()
	got["f19"] = f19()
	got["f20"] = f20()
	got["f21"] = f21()
	got["f22"] = f22()
	got["f23"] = f23()
	got["f24"] = f24()
	got["f25"] = f25()
	for name, want := range cases {
		if got[name] != want {
			t.Fatalf("%s() = %d, want %d", name, got[name], want)
		}
	}
}

// Verify no non-test source still mentions OldName.
func TestNoOldNameRemains(t *testing.T) {
	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if strings.Contains(string(b), "OldName") {
			t.Errorf("%s still mentions OldName", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}
