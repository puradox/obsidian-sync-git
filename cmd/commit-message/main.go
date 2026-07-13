// commit-message prints a commit message for the currently STAGED vault
// changes: a one-line subject, plus a short bulleted body when the change is
// big enough.
//
// Provider selection (first match wins):
//  1. An OpenAI-compatible Chat Completions endpoint (Groq, Gemini's OpenAI
//     endpoint, Ollama, OpenRouter, ...) when LLM_API_BASE + LLM_API_KEY +
//     LLM_MODEL are all set.
//  2. The native Anthropic Messages API when ANTHROPIC_API_KEY is set.
//  3. A deterministic fallback.
//
// ANY failure — no config, no network, timeout, bad response — falls back,
// with the reason on stderr (the bridge discards stderr; a manual run shows
// it). This program NEVER fails and NEVER blocks the commit: it always prints
// a non-empty message and exits 0. Run it with the git repo root as the
// current working directory.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	statCap    = 4000 // bytes of `git diff --cached --stat` sent to the model
	sampleCap  = 8000 // bytes of the raw staged diff sent to the model
	subjectCap = 300  // bytes kept from the model's subject line
	bodyCap    = 1200 // bytes kept from the model's body
	maxBullets = 5

	// Default completion budget for the OpenAI-compatible path. On reasoning
	// models (gpt-oss / qwen on Groq, DeepSeek-R1, ...) max_tokens also covers
	// the hidden "thinking" tokens emitted before any visible text, and a big
	// diff can burn well over 1024 tokens of thought — so the default is sized
	// for them. Override with LLM_MAX_TOKENS.
	defaultMaxTokens = 4096

	// Sized so a reasoning model thinking through a 12KB prompt at the 4096
	// budget can finish; a hung provider still can't stall the commit for
	// long, and the cycle's own BRIDGE_CYCLE_TIMEOUT backstops everything.
	openAITimeout    = 30 * time.Second
	anthropicTimeout = 10 * time.Second
)

func main() {
	msg, err := aiMessage()
	if err != nil {
		fmt.Fprintf(os.Stderr, "commit-message: falling back: %v\n", err)
		msg = fallbackMessage(time.Now().UTC())
	}
	fmt.Print(msg)
}

// fallbackMessage is the deterministic label used whenever no AI message could
// be produced. It must never be empty.
func fallbackMessage(now time.Time) string {
	n := 0
	for line := range strings.Lines(gitOutput("diff", "--cached", "--name-only")) {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return fmt.Sprintf("vault auto-commit: %d files changed (%s)", n, now.Format("2006-01-02T15:04:05Z"))
}

func aiMessage() (string, error) {
	stat := truncUTF8(gitOutput("diff", "--cached", "--stat"), statCap)
	sample := truncUTF8(gitOutput("diff", "--cached"), sampleCap)

	// The body allowance scales with content, not file count: one bullet line
	// per ~1000 bytes of diff, capped. Small diffs get a subject line only.
	nbullets := min(len(sample)/1000, maxBullets)

	raw, err := callProvider(buildPrompt(stat, sample, nbullets))
	if err != nil {
		return "", err
	}
	msg := clean(raw, nbullets)
	if msg == "" {
		return "", errors.New("model returned no usable text")
	}
	return msg, nil
}

func gitOutput(args ...string) string {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

// truncUTF8 caps s at n bytes, dropping any multibyte character the cut split.
func truncUTF8(s string, n int) string {
	if len(s) > n {
		s = s[:n]
	}
	return strings.ToValidUTF8(s, "")
}

// buildPrompt is the shared prompt, identical for every provider.
func buildPrompt(stat, sample string, nbullets int) string {
	formatRules := `Reply with a single concise line (<= 72 chars). Output ONLY the
summary line: no preamble, no quotes, no trailing period, no markdown.`
	if nbullets >= 1 {
		formatRules = fmt.Sprintf(`Line 1: a concise subject (<= 72 chars, no trailing period).
Then a blank line, then a body of at most %d plain-text bullet
line(s) ('- ') naming the most significant changes — content matters, not
file count. Output ONLY the commit message: no preamble, no quotes, no
markdown headings, no code fences.`, nbullets)
	}

	return fmt.Sprintf(`You write git commit messages. Summarize the following staged changes to an Obsidian notes vault.
%s

--- git diff --stat (cached) ---
%s

--- diff sample (truncated) ---
%s`, formatRules, stat, sample)
}

func callProvider(prompt string) (string, error) {
	base := os.Getenv("LLM_API_BASE")
	key := os.Getenv("LLM_API_KEY")
	model := os.Getenv("LLM_MODEL")
	if base != "" && key != "" && model != "" {
		// Require an explicit http(s) scheme — a schemeless base would default
		// to http:// and send the Bearer key in cleartext. Refuse and fall
		// through to the next provider instead.
		if hasHTTPScheme(base) {
			return openAIChat(base, key, model, prompt, maxTokensFromEnv(os.Getenv("LLM_MAX_TOKENS")))
		}
		fmt.Fprintln(os.Stderr, "commit-message: LLM_API_BASE has no http(s):// scheme; ignoring the OpenAI-compatible provider")
	}
	if key := os.Getenv("ANTHROPIC_API_KEY"); key != "" {
		model := os.Getenv("ANTHROPIC_MODEL")
		if model == "" {
			model = "claude-haiku-4-5"
		}
		return anthropicChat(key, model, prompt)
	}
	return "", errors.New("no AI provider configured")
}

func hasHTTPScheme(base string) bool {
	return strings.HasPrefix(base, "http://") || strings.HasPrefix(base, "https://")
}

// maxTokensFromEnv coerces a missing or malformed LLM_MAX_TOKENS to the default.
func maxTokensFromEnv(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n <= 0 {
		return defaultMaxTokens
	}
	return n
}

// openAIChat calls an OpenAI-compatible Chat Completions endpoint
// (Groq / Gemini / Ollama / ...).
func openAIChat(base, key, model, prompt string, maxTokens int) (string, error) {
	payload := map[string]any{
		"model":       model,
		"max_tokens":  maxTokens,
		"temperature": 0.2,
		"messages":    []map[string]string{{"role": "user", "content": prompt}},
	}
	body, err := postJSON(
		strings.TrimSuffix(base, "/")+"/chat/completions",
		map[string]string{"authorization": "Bearer " + key},
		payload, openAITimeout)
	if err != nil {
		return "", err
	}

	var r struct {
		Choices []struct {
			FinishReason string `json:"finish_reason"`
			Message      struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return "", fmt.Errorf("unparseable chat completions response: %w", err)
	}
	if len(r.Choices) == 0 {
		return "", errors.New("chat completions response has no choices")
	}
	c := r.Choices[0]
	if c.Message.Content == "" && c.FinishReason == "length" {
		return "", errors.New("completion budget exhausted before any visible text (a reasoning model spent it all thinking) — raise LLM_MAX_TOKENS")
	}
	return c.Message.Content, nil
}

// anthropicChat calls the native Anthropic Messages API.
func anthropicChat(key, model, prompt string) (string, error) {
	payload := map[string]any{
		"model":      model,
		"max_tokens": 512,
		"messages":   []map[string]string{{"role": "user", "content": prompt}},
	}
	body, err := postJSON(
		"https://api.anthropic.com/v1/messages",
		map[string]string{"x-api-key": key, "anthropic-version": "2023-06-01"},
		payload, anthropicTimeout)
	if err != nil {
		return "", err
	}

	var r struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(body, &r); err != nil {
		return "", fmt.Errorf("unparseable messages response: %w", err)
	}
	for _, c := range r.Content {
		if c.Type == "text" {
			return c.Text, nil
		}
	}
	return "", errors.New("messages response has no text block")
}

func postJSON(url string, headers map[string]string, payload any, timeout time.Duration) ([]byte, error) {
	reqBody, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, err
	}
	req.Header.Set("content-type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("HTTP %d from %s: %s", resp.StatusCode, url, errSnippet(body))
	}
	return body, nil
}

// errSnippet flattens an error body to one short line for the stderr log.
func errSnippet(body []byte) string {
	s := strings.Join(strings.Fields(string(body)), " ")
	return truncUTF8(s, 200)
}

var spaceRuns = regexp.MustCompile(" +")

// clean normalizes a model reply into the final commit message: no CRs or code
// fences, a tidied subject line capped at subjectCap bytes, and (when the diff
// earned a body) at most nbullets body lines capped at bodyCap bytes. The
// prompt's length limits are advisory only, so both parts are byte-capped — a
// model that ignores the instructions must not produce a multi-KB commit
// message. Returns "" when nothing usable remains.
func clean(raw string, nbullets int) string {
	raw = strings.ReplaceAll(raw, "\r", "")
	var lines []string
	for _, l := range strings.Split(raw, "\n") {
		if !strings.HasPrefix(l, "```") {
			lines = append(lines, strings.TrimRight(l, " \t"))
		}
	}
	for len(lines) > 0 && lines[0] == "" {
		lines = lines[1:]
	}
	if len(lines) == 0 {
		return ""
	}

	subject := strings.ReplaceAll(lines[0], "\t", " ")
	subject = strings.TrimSpace(spaceRuns.ReplaceAllString(subject, " "))
	subject = truncUTF8(subject, subjectCap)
	if subject == "" {
		return ""
	}

	if nbullets >= 1 {
		body := lines[1:]
		for len(body) > 0 && body[0] == "" {
			body = body[1:]
		}
		if len(body) > nbullets {
			body = body[:nbullets]
		}
		if b := strings.TrimRight(truncUTF8(strings.Join(body, "\n"), bodyCap), "\n"); b != "" {
			return subject + "\n\n" + b
		}
	}
	return subject
}
