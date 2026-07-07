#!/usr/bin/env bash
# Print a commit message for the currently STAGED vault changes: a one-line
# subject, plus a short bulleted body when the change is big enough.
#
# Provider selection (first match wins):
#   1. An OpenAI-compatible Chat Completions endpoint (Groq, Gemini's OpenAI
#      endpoint, Ollama, OpenRouter, ...) when LLM_API_BASE + LLM_API_KEY +
#      LLM_MODEL are all set.
#   2. The native Anthropic Messages API when ANTHROPIC_API_KEY is set.
#   3. A deterministic fallback.
#
# ANY failure — no config, no network, timeout, bad response — falls back. This
# script NEVER fails and NEVER blocks the commit: it always prints a non-empty
# line and exits 0. Run it with the git repo root as the current directory.
set -uo pipefail

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
nfiles="$(git diff --cached --name-only 2>/dev/null | grep -c .)"  # grep -c always prints a number
fallback="vault auto-commit: ${nfiles} files changed (${now})"

emit() { printf '%s' "$1"; exit 0; }

# The API paths need curl + jq; without them, fall back.
command -v curl >/dev/null 2>&1 || emit "$fallback"
command -v jq   >/dev/null 2>&1 || emit "$fallback"

# Shared prompt (same for every provider). The byte truncation can split a
# multibyte UTF-8 char, which jq's --arg rejects — iconv -c drops the fragment.
stat="$(git diff --cached --stat 2>/dev/null | head -c 4000 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
sample="$(git diff --cached 2>/dev/null | head -c 8000 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"

# The body allowance scales with content, not file count: one bullet line per
# ~1000 characters of diff, capped at 5. Small diffs get a subject line only.
nbullets=$(( ${#sample} / 1000 ))
[ "$nbullets" -gt 5 ] && nbullets=5

if [ "$nbullets" -ge 1 ]; then
  format_rules="Line 1: a concise subject (<= 72 chars, no trailing period).
Then a blank line, then a body of at most ${nbullets} plain-text bullet
line(s) ('- ') naming the most significant changes — content matters, not
file count. Output ONLY the commit message: no preamble, no quotes, no
markdown headings, no code fences."
else
  format_rules="Reply with a single concise line (<= 72 chars). Output ONLY the
summary line: no preamble, no quotes, no trailing period, no markdown."
fi

prompt="You write git commit messages. Summarize the following staged changes to an Obsidian notes vault.
${format_rules}

--- git diff --stat (cached) ---
${stat}

--- diff sample (truncated) ---
${sample}"

llm_base="${LLM_API_BASE:-}"
llm_key="${LLM_API_KEY:-}"
llm_model="${LLM_MODEL:-}"
anthropic_key="${ANTHROPIC_API_KEY:-}"

# Use the OpenAI-compatible path only when it is fully configured AND the base URL
# has an explicit http(s) scheme — a schemeless base would make curl default to
# http:// and send the Bearer key in cleartext.
use_openai=false
if [ -n "$llm_base" ] && [ -n "$llm_key" ] && [ -n "$llm_model" ]; then
  case "$llm_base" in
    http://* | https://*) use_openai=true ;;
    *) : ;;  # schemeless base: refuse and fall through to the next provider
  esac
fi

if [ "$use_openai" = true ]; then
  # --- OpenAI-compatible Chat Completions (Groq / Gemini / Ollama / ...) ---
  # A generous max_tokens leaves room for models that "think" before answering
  # (e.g. Gemini Flash-Lite); non-thinking models stop after the one line anyway.
  mt="${LLM_MAX_TOKENS:-1024}"
  case "$mt" in ''|*[!0-9]*) mt=1024 ;; esac   # coerce a non-integer back to the default
  payload="$(jq -n --arg m "$llm_model" --arg p "$prompt" --argjson mt "$mt" \
    '{model:$m, max_tokens:$mt, temperature:0.2, messages:[{role:"user", content:$p}]}' 2>/dev/null)" \
    || emit "$fallback"
  resp="$(curl -sS --max-time 15 "${llm_base%/}/chat/completions" \
    -H 'content-type: application/json' \
    -H "authorization: Bearer ${llm_key}" \
    --data-binary "$payload" 2>/dev/null)" || emit "$fallback"
  msg="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // ""' 2>/dev/null)"

elif [ -n "$anthropic_key" ]; then
  # --- native Anthropic Messages API ---
  model="${ANTHROPIC_MODEL:-claude-haiku-4-5}"
  payload="$(jq -n --arg m "$model" --arg p "$prompt" \
    '{model:$m, max_tokens:512, messages:[{role:"user", content:$p}]}' 2>/dev/null)" \
    || emit "$fallback"
  resp="$(curl -sS --max-time 10 https://api.anthropic.com/v1/messages \
    -H 'content-type: application/json' \
    -H "x-api-key: ${anthropic_key}" \
    -H 'anthropic-version: 2023-06-01' \
    --data-binary "$payload" 2>/dev/null)" || emit "$fallback"
  msg="$(printf '%s' "$resp" | jq -r 'first(.content[]? | select(.type=="text") | .text) // ""' 2>/dev/null)"

else
  emit "$fallback"
fi

# Clean up: drop CRs, stray code fences, and leading blank lines. The prompt's
# length limits are advisory only, so both parts are byte-capped — a model that
# ignores the instructions must not produce a multi-KB commit message.
msg="$(printf '%s' "${msg:-}" | tr -d '\r' | sed -e '/^```/d' -e '/./,$!d')"
subject="$(printf '%s\n' "$msg" | head -n1 | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' | head -c 300)"
[ -n "$subject" ] || emit "$fallback"
if [ "$nbullets" -ge 1 ]; then
  # Enforce the allowance: keep at most nbullets body lines, byte-capped.
  body="$(printf '%s\n' "$msg" | tail -n +2 | sed -e '/./,$!d' -e 's/[[:space:]]*$//' | head -n "$nbullets" | head -c 1200)"
  [ -n "$body" ] && emit "$(printf '%s\n\n%s' "$subject" "$body")"
fi
emit "$subject"
