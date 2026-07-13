package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCleanSubjectOnly(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"plain", "add meeting notes", "add meeting notes"},
		{"leading blanks and fence", "```\n\nadd meeting notes\n```", "add meeting notes"},
		{"collapses whitespace", "  add\t\tmeeting   notes  ", "add meeting notes"},
		{"crlf", "add meeting notes\r\n", "add meeting notes"},
		{"body ignored when no allowance", "subject\n\n- a bullet", "subject"},
		{"nothing usable", "```\n\n```", ""},
	}
	for _, c := range cases {
		if got := clean(c.raw, 0); got != c.want {
			t.Errorf("%s: clean(%q, 0) = %q, want %q", c.name, c.raw, got, c.want)
		}
	}
}

func TestCleanWithBody(t *testing.T) {
	raw := "subject line\n\n- one\n- two\n- three"
	want := "subject line\n\n- one\n- two"
	if got := clean(raw, 2); got != want {
		t.Errorf("clean() = %q, want %q", got, want)
	}
	// A subject with no body stays a bare subject even when a body is allowed.
	if got := clean("subject line\n\n\n", 3); got != "subject line" {
		t.Errorf("clean() = %q, want %q", got, "subject line")
	}
}

func TestCleanCapsSubjectBytes(t *testing.T) {
	got := clean(strings.Repeat("x", 1000), 0)
	if len(got) != subjectCap {
		t.Errorf("subject length = %d, want %d", len(got), subjectCap)
	}
}

func TestTruncUTF8DropsSplitRune(t *testing.T) {
	s := "aé" // é is 2 bytes; cutting at 2 splits it
	if got := truncUTF8(s, 2); got != "a" {
		t.Errorf("truncUTF8(%q, 2) = %q, want %q", s, got, "a")
	}
}

func TestMaxTokensFromEnv(t *testing.T) {
	cases := map[string]int{
		"":     defaultMaxTokens,
		"abc":  defaultMaxTokens,
		"-5":   defaultMaxTokens,
		"0":    defaultMaxTokens,
		"2048": 2048,
	}
	for in, want := range cases {
		if got := maxTokensFromEnv(in); got != want {
			t.Errorf("maxTokensFromEnv(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestHasHTTPScheme(t *testing.T) {
	for base, want := range map[string]bool{
		"https://api.groq.com/openai/v1": true,
		"http://localhost:11434/v1":      true,
		"api.groq.com/openai/v1":         false,
	} {
		if got := hasHTTPScheme(base); got != want {
			t.Errorf("hasHTTPScheme(%q) = %v, want %v", base, got, want)
		}
	}
}

// chatServer fakes an OpenAI-compatible /chat/completions endpoint.
func chatServer(t *testing.T, content, finishReason string, status int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/chat/completions" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if got := r.Header.Get("authorization"); got != "Bearer k" {
			t.Errorf("authorization = %q", got)
		}
		var req struct {
			Model     string `json:"model"`
			MaxTokens int    `json:"max_tokens"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("bad request body: %v", err)
		}
		if req.MaxTokens != defaultMaxTokens {
			t.Errorf("max_tokens = %d, want %d", req.MaxTokens, defaultMaxTokens)
		}
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{{
				"finish_reason": finishReason,
				"message":       map[string]string{"role": "assistant", "content": content},
			}},
		})
	}))
}

func TestOpenAIChat(t *testing.T) {
	srv := chatServer(t, "add meeting notes", "stop", http.StatusOK)
	defer srv.Close()
	got, err := openAIChat(srv.URL, "k", "m", "prompt", defaultMaxTokens)
	if err != nil || got != "add meeting notes" {
		t.Errorf("openAIChat() = %q, %v", got, err)
	}
}

func TestOpenAIChatReasoningBudgetExhausted(t *testing.T) {
	srv := chatServer(t, "", "length", http.StatusOK)
	defer srv.Close()
	_, err := openAIChat(srv.URL, "k", "m", "prompt", defaultMaxTokens)
	if err == nil || !strings.Contains(err.Error(), "LLM_MAX_TOKENS") {
		t.Errorf("want LLM_MAX_TOKENS hint, got %v", err)
	}
}

func TestOpenAIChatHTTPError(t *testing.T) {
	srv := chatServer(t, "", "", http.StatusTooManyRequests)
	defer srv.Close()
	if _, err := openAIChat(srv.URL, "k", "m", "prompt", defaultMaxTokens); err == nil {
		t.Error("want error on HTTP 429, got nil")
	}
}
