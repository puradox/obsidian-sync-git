# shellcheck shell=bash
# Git submodule support shared by entrypoint.sh and bridge.sh (sourced, not run).
#
# A submodule inside the vault (e.g. a folder shared with someone who isn't on
# Obsidian Sync, backed by its own GitHub repo) is discovered from .gitmodules,
# never hardcoded. Each one may have its own deploy key — GitHub deploy keys
# are one-repo — provided as
#
#   GIT_SUBMODULE_DEPLOY_KEY_<NAME>        the private key contents, or
#   GIT_SUBMODULE_DEPLOY_KEY_FILE_<NAME>   a mounted path (preferred)
#
# where <NAME> is the submodule's .gitmodules name (the [submodule "..."]
# header — by default the path it was added at), upper-cased, with every
# character that is not A-Z or 0-9 replaced by an underscore:
#
#   [submodule "vault/Cove QMS"]  ->  GIT_SUBMODULE_DEPLOY_KEY_FILE_VAULT_COVE_QMS
#
# Keys are routed with an SSH host alias per submodule, set as the host of the
# submodule's own origin URL, so .gitmodules keeps the canonical URL for every
# other clone. Only ssh URLs (git@host:path or ssh://host/path) can be routed;
# anything else is left to git as-is.

# submodule_env_name NAME -> the <NAME> suffix of the key env vars.
submodule_env_name() {
  printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9' '_'
}

# submodule_ssh_alias ENVNAME -> the ssh Host alias used to route its key.
submodule_ssh_alias() {
  printf 'bridge-submodule-%s' "$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]_' '[:lower:]-')"
}

# submodule_key_file ENVNAME -> where entrypoint.sh installs that key.
submodule_key_file() { printf '%s/.ssh/id_submodule_%s' "$HOME" "$1"; }

# submodule_parse_ssh_url URL: sets SSH_USER, SSH_HOST, SSH_PORT, SSH_PATH and
# SSH_FORM (scp|url); returns 1 for anything that isn't an ssh URL.
submodule_parse_ssh_url() {
  local url="$1"
  SSH_USER="" SSH_HOST="" SSH_PORT="" SSH_PATH="" SSH_FORM=""
  if [[ "$url" =~ ^ssh://(([^@/]+)@)?([^:/]+)(:([0-9]+))?(/.*)$ ]]; then
    SSH_USER="${BASH_REMATCH[2]}" SSH_HOST="${BASH_REMATCH[3]}"
    SSH_PORT="${BASH_REMATCH[5]}" SSH_PATH="${BASH_REMATCH[6]}" SSH_FORM=url
  elif [[ "$url" != *://* && "$url" =~ ^(([^@/]+)@)?([^:/]+):(.*)$ ]]; then
    SSH_USER="${BASH_REMATCH[2]}" SSH_HOST="${BASH_REMATCH[3]}"
    SSH_PATH="${BASH_REMATCH[4]}" SSH_FORM=scp
  else
    return 1
  fi
}

# submodule_alias_url ALIAS  (after submodule_parse_ssh_url) -> the same URL
# with the host swapped for the ssh alias.
submodule_alias_url() {
  local alias="$1"
  if [ "$SSH_FORM" = url ]; then
    printf 'ssh://%s%s%s%s' "${SSH_USER:+$SSH_USER@}" "$alias" "${SSH_PORT:+:$SSH_PORT}" "$SSH_PATH"
  else
    printf '%s%s:%s' "${SSH_USER:+$SSH_USER@}" "$alias" "$SSH_PATH"
  fi
}

# in_vault PATH: the repo-relative PATH lies inside the vault (VAULT_DIR within
# REPO_DIR; every path is when the vault is the repo root).
in_vault() {
  local vault_rel="${VAULT_DIR#"$REPO_DIR"}"
  vault_rel="${vault_rel#/}"
  [ -z "$vault_rel" ] || [[ "$1/" == "$vault_rel/"* ]]
}

# discover_submodules: read $REPO_DIR/.gitmodules into the parallel arrays
# SUB_NAME / SUB_PATH / SUB_URL / SUB_BRANCH / SUB_ENV, keeping only submodules
# whose path lies inside the vault (VAULT_DIR within REPO_DIR). Entries with an
# unsafe path (absolute, or containing "..") are skipped with a warning.
# Branch defaults to main; set `branch = ...` in .gitmodules to override
# (`branch = .`, git's "same branch as the superproject", also means main).
discover_submodules() {
  local gm="$REPO_DIR/.gitmodules" entry key name path url branch env prev
  SUB_NAME=() SUB_PATH=() SUB_URL=() SUB_BRANCH=() SUB_ENV=()
  [ -f "$gm" ] || return 0
  while IFS= read -r -d '' entry; do
    key="${entry%%$'\n'*}"; path="${entry#*$'\n'}"
    name="${key#submodule.}"; name="${name%.path}"
    path="${path#./}"; path="${path%/}"
    # The name becomes .git/modules/<name>, so it must be as safe as the path.
    case "/$path/" in
      //*|*/../*|*/./*|*//*)
        printf '[submodules] WARNING: ignoring submodule "%s": unsafe path "%s"\n' "$name" "$path" >&2
        continue ;;
    esac
    case "/$name/" in
      //*|*/../*|*/./*|*//*|*/.git/*)
        printf '[submodules] WARNING: ignoring submodule "%s": unsafe name\n' "$name" >&2
        continue ;;
    esac
    # Only submodules inside the vault are the bridge's business.
    in_vault "$path" || continue
    url="$(git config -f "$gm" --get "submodule.$name.url" 2>/dev/null || true)"
    branch="$(git config -f "$gm" --get "submodule.$name.branch" 2>/dev/null || true)"
    if [ -z "$url" ]; then
      printf '[submodules] WARNING: ignoring submodule "%s": no url in .gitmodules\n' "$name" >&2
      continue
    fi
    [ "$branch" = . ] && branch=main
    env="$(submodule_env_name "$name")"
    # ${arr[@]+"${arr[@]}"}: an empty array is an unbound variable under set -u
    # on bash < 4.4 (macOS's /bin/bash).
    for prev in ${SUB_ENV[@]+"${SUB_ENV[@]}"}; do
      [ "$prev" = "$env" ] && printf '[submodules] WARNING: submodules "%s" and another both map to %s — they will share one deploy key setting\n' "$name" "$env" >&2
    done
    SUB_NAME+=("$name"); SUB_PATH+=("$path"); SUB_URL+=("$url")
    SUB_BRANCH+=("${branch:-main}"); SUB_ENV+=("$env")
  done < <(git config -f "$gm" -z --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
}

# submodule_has_key I: a deploy key was installed for submodule I.
submodule_has_key() { [ -s "$(submodule_key_file "${SUB_ENV[$1]}")" ]; }

# submodule_needs_no_key URL: a local path (or file:// URL) — reachable without
# any credentials, so nothing to route. An https:// or git:// URL is neither
# that nor routable: the bridge has no way to authenticate to it.
submodule_needs_no_key() { [[ "$1" != *://* || "$1" == file://* ]]; }

# submodule_can_reach_remote I: the bridge can talk to submodule I's remote —
# its key is installed and routed (ssh), or the URL needs no key at all.
submodule_can_reach_remote() {
  if submodule_parse_ssh_url "${SUB_URL[$1]}"; then
    submodule_has_key "$1"
  else
    submodule_needs_no_key "${SUB_URL[$1]}"
  fi
}

# submodule_routable I: submodule I has a key AND an ssh URL to route it to
# (leaves the SSH_* variables set for it).
submodule_routable() { submodule_has_key "$1" && submodule_parse_ssh_url "${SUB_URL[$1]}"; }

# submodule_routed_url I -> the URL the submodule's own origin should use: the
# canonical URL with the host swapped for its ssh alias when routable, else the
# canonical URL itself. Set on the submodule's remote (not a global insteadOf,
# which is a prefix rewrite and would also catch any other URL the canonical
# one is a prefix of — the outer repo's, say).
submodule_routed_url() {
  if submodule_routable "$1"; then
    submodule_alias_url "$(submodule_ssh_alias "${SUB_ENV[$1]}")"
  else
    printf '%s' "${SUB_URL[$1]}"
  fi
}

# configure_submodule_routing: (re)write the per-submodule ssh Host aliases for
# every discovered submodule that has a key. Idempotent — run it at the start
# of every cycle so submodules added later (or keys added on restart) pick up
# routing without manual steps; the file is only replaced when it changes.
#
# $HOME/.ssh/config Includes the alias file; each alias block carries ONLY that
# submodule's IdentityFile (ssh accumulates IdentityFile across matching Host
# blocks, and GitHub authenticates the first key it recognises, so the outer
# deploy key must never be offered to a submodule host — the outer key's block
# excludes the aliases).
configure_submodule_routing() {
  local conf="$HOME/.ssh/bridge_submodules.conf" tmp i alias name
  tmp="$(mktemp "$conf.XXXXXX")" || return 1
  {
    printf '# Generated by the bridge from .gitmodules — do not edit.\n'
    for i in "${!SUB_NAME[@]}"; do
      submodule_routable "$i" || continue
      alias="$(submodule_ssh_alias "${SUB_ENV[$i]}")"
      printf 'Host %s\n  HostName %s\n  HostKeyAlias %s\n' "$alias" "$SSH_HOST" "$SSH_HOST"
      [ -n "$SSH_PORT" ] && printf '  Port %s\n' "$SSH_PORT"
      [ -n "$SSH_USER" ] && printf '  User %s\n' "$SSH_USER"
      printf '  IdentityFile %s\n\n' "$(submodule_key_file "${SUB_ENV[$i]}")"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if cmp -s "$tmp" "$conf" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$conf"; then rm -f "$tmp"; return 1; fi

  # Earlier bridge versions routed with global url.insteadOf rewrites; drop any
  # left behind so they can't catch unrelated URLs.
  while IFS= read -r name; do
    name="${name#url.}"; name="${name%.insteadof}"
    git config --global --remove-section "url.$name" 2>/dev/null || true
  done < <(git config --global --name-only --get-regexp '^url\..*bridge-submodule-.*\.insteadof$' 2>/dev/null || true)
}
