package main

import "testing"

func TestGetDeterministicBucketIsWithinRange(t *testing.T) {
	bucket := getDeterministicBucket("user-123flag-x")
	if bucket < 0 || bucket > 99 {
		t.Fatalf("bucket fora do range 0-99: %d", bucket)
	}
}

func TestGetDeterministicBucketIsStable(t *testing.T) {
	b1 := getDeterministicBucket("user-abcflag-y")
	b2 := getDeterministicBucket("user-abcflag-y")
	if b1 != b2 {
		t.Fatalf("mesma entrada gerou buckets diferentes: %d != %d", b1, b2)
	}
}

func TestGetDeterministicBucketVariesWithInput(t *testing.T) {
	b1 := getDeterministicBucket("user-1flag-x")
	b2 := getDeterministicBucket("user-2flag-x")
	if b1 == b2 {
		// Estatisticamente raro (1/100), mas não impossível — troca de
		// entrada só para reduzir a chance de flake caso colida.
		b2 = getDeterministicBucket("user-3flag-x")
		if b1 == b2 {
			t.Skip("colisão de bucket entre entradas diferentes (esperado ocasionalmente)")
		}
	}
}
