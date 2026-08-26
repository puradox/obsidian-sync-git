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
# Keys are routed with an SSH host alias per submodule plus a git
# url.<alias>.insteadOf rewrite, so .gitmodules keeps the canonical URL for
# every other clone. Only ssh URLs (git@host:path or ssh://host/path) can be
# routed; anything else is left to git as-is.

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

# discover_submodules: read $REPO_DIR/.gitmodules into the parallel arrays
# SUB_NAME / SUB_PATH / SUB_URL / SUB_BRANCH / SUB_ENV, keeping only submodules
# whose path lies inside the vault (VAULT_DIR within REPO_DIR). Entries with an
# unsafe path (absolute, or containing "..") are skipped with a warning.
# Branch defaults to main; set `branch = ...` in .gitmodules to override.
discover_submodules() {
  local gm="$REPO_DIR/.gitmodules" vault_rel entry key name path url branch
  SUB_NAME=() SUB_PATH=() SUB_URL=() SUB_BRANCH=() SUB_ENV=()
  [ -f "$gm" ] || return 0
  vault_rel="${VAULT_DIR#"$REPO_DIR"}"; vault_rel="${vault_rel#/}"
  while IFS= read -r -d '' entry; do
    key="${entry%%$'\n'*}"; path="${entry#*$'\n'}"
    name="${key#submodule.}"; name="${name%.path}"
    path="${path#./}"; path="${path%/}"
    case "/$path/" in
      //*|*/../*|*/./*|*//*)
        printf '[submodules] WARNING: ignoring submodule "%s": unsafe path "%s"\n' "$name" "$path" >&2
        continue ;;
    esac
    # Only submodules inside the vault are the bridge's business.
    [ -z "$vault_rel" ] || [[ "$path/" == "$vault_rel/"* ]] || continue
    url="$(git config -f "$gm" --get "submodule.$name.url" 2>/dev/null || true)"
    branch="$(git config -f "$gm" --get "submodule.$name.branch" 2>/dev/null || true)"
    if [ -z "$url" ]; then
      printf '[submodules] WARNING: ignoring submodule "%s": no url in .gitmodules\n' "$name" >&2
      continue
    fi
    SUB_NAME+=("$name"); SUB_PATH+=("$path"); SUB_URL+=("$url")
    SUB_BRANCH+=("${branch:-main}"); SUB_ENV+=("$(submodule_env_name "$name")")
  done < <(git config -f "$gm" -z --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
}

# submodule_has_key I: a deploy key was installed for submodule I.
submodule_has_key() { [ -s "$(submodule_key_file "${SUB_ENV[$1]}")" ]; }

# submodule_can_reach_remote I: the bridge can talk to submodule I's remote —
# either its key is installed and routed, or the URL isn't ssh at all (a local
# path in tests, https, ...) so there is no deploy key to route.
submodule_can_reach_remote() {
  submodule_parse_ssh_url "${SUB_URL[$1]}" || return 0
  submodule_has_key "$1"
}

# configure_submodule_routing: (re)write the per-submodule ssh Host aliases and
# git url.insteadOf rewrites for every discovered submodule that has a key.
# Idempotent — run it at the start of every cycle so submodules added later
# (or keys added on restart) pick up routing without manual steps.
#
# $HOME/.ssh/config Includes the alias file; each alias block carries ONLY that
# submodule's IdentityFile (ssh accumulates IdentityFile across matching Host
# blocks, and GitHub authenticates the first key it recognises, so the outer
# deploy key must never be offered to a submodule host — the outer key's block
# excludes the aliases).
configure_submodule_routing() {
  local conf="$HOME/.ssh/bridge_submodules.conf" tmp i alias alias_url name
  tmp="$(mktemp "$conf.XXXXXX")" || return 1
  {
    printf '# Generated by the bridge from .gitmodules — do not edit.\n'
    for i in "${!SUB_NAME[@]}"; do
      submodule_has_key "$i" || continue
      submodule_parse_ssh_url "${SUB_URL[$i]}" || continue
      alias="$(submodule_ssh_alias "${SUB_ENV[$i]}")"
      printf 'Host %s\n  HostName %s\n  HostKeyAlias %s\n' "$alias" "$SSH_HOST" "$SSH_HOST"
      [ -n "$SSH_PORT" ] && printf '  Port %s\n' "$SSH_PORT"
      [ -n "$SSH_USER" ] && printf '  User %s\n' "$SSH_USER"
      printf '  IdentityFile %s\n\n' "$(submodule_key_file "${SUB_ENV[$i]}")"
    done
  } > "$tmp"
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$conf"; then rm -f "$tmp"; return 1; fi

  # Replace every bridge-managed insteadOf so removed submodules lose theirs.
  while IFS= read -r name; do
    name="${name#url.}"; name="${name%.insteadof}"
    git config --global --remove-section "url.$name" 2>/dev/null || true
  done < <(git config --global --name-only --get-regexp '^url\..*bridge-submodule-.*\.insteadof$' 2>/dev/null || true)
  for i in "${!SUB_NAME[@]}"; do
    submodule_has_key "$i" || continue
    submodule_parse_ssh_url "${SUB_URL[$i]}" || continue
    alias_url="$(submodule_alias_url "$(submodule_ssh_alias "${SUB_ENV[$i]}")")"
    git config --global "url.$alias_url.insteadOf" "${SUB_URL[$i]}"
  done
}
