package main

import "testing"

func TestDisplayTextMarksCursor(t *testing.T) {
	snapshot := Snapshot{Row: 2, Col: 1, Lines: []string{"one", "two"}}
	if got, want := snapshot.DisplayText(), "one\nt▏wo"; got != want {
		t.Fatalf("DisplayText() = %q, want %q", got, want)
	}
}
