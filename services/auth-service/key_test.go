package main

import "testing"

func TestGenerateAPIKeyHasExpectedPrefixAndLength(t *testing.T) {
	key, err := generateAPIKey()
	if err != nil {
		t.Fatalf("generateAPIKey retornou erro: %v", err)
	}
	if len(key) <= len("tm_key_") {
		t.Fatalf("chave gerada muito curta: %q", key)
	}
	if key[:7] != "tm_key_" {
		t.Fatalf("chave gerada sem o prefixo esperado: %q", key)
	}
}

func TestGenerateAPIKeyIsRandom(t *testing.T) {
	k1, _ := generateAPIKey()
	k2, _ := generateAPIKey()
	if k1 == k2 {
		t.Fatal("duas chamadas a generateAPIKey geraram a mesma chave")
	}
}

func TestHashAPIKeyIsDeterministic(t *testing.T) {
	h1 := hashAPIKey("minha-chave")
	h2 := hashAPIKey("minha-chave")
	if h1 != h2 {
		t.Fatalf("hashAPIKey não é determinístico: %q != %q", h1, h2)
	}
	if len(h1) != 64 {
		t.Fatalf("hash SHA-256 deveria ter 64 chars hex, tem %d", len(h1))
	}
}

func TestHashAPIKeyDiffersForDifferentInput(t *testing.T) {
	if hashAPIKey("a") == hashAPIKey("b") {
		t.Fatal("hashes de entradas diferentes colidiram")
	}
}
