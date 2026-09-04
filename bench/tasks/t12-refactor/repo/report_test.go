package report

import "testing"

func TestBuildReport(t *testing.T) {
	got := Build([]item{
		{name: "apples", price: 1.00},
		{name: "laptop", price: 20.00},
		{name: "bread", price: 2.50},
	})
	want := "| item | price |\n" +
		"|---|---|\n" +
		"| apples | 1.00 |\n" +
		"| laptop | 18.00 |\n" +
		"| bread | 2.50 |\n" +
		"| Total | 21.50 |\n"
	if got != want {
		t.Fatalf("Build:\n%s\nwant:\n%s", got, want)
	}
}

func TestBuildEmpty(t *testing.T) {
	got := Build(nil)
	want := "| item | price |\n" +
		"|---|---|\n" +
		"| Total | 0.00 |\n"
	if got != want {
		t.Fatalf("Build(nil):\n%s\nwant:\n%s", got, want)
	}
}

func TestBuildNoDiscountNeeded(t *testing.T) {
	got := Build([]item{{name: "milk", price: 3.20}})
	want := "| item | price |\n" +
		"|---|---|\n" +
		"| milk | 3.20 |\n" +
		"| Total | 3.20 |\n"
	if got != want {
		t.Fatalf("Build:\n%s\nwant:\n%s", got, want)
	}
}
