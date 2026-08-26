package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// A submodule inside the vault (a folder shared with someone who isn't on
// Obsidian Sync, backed by its own GitHub repo) is discovered from
// .gitmodules, never hardcoded. Each one may have its own deploy key — GitHub
// deploy keys are one-repo — provided as
//
//	GIT_SUBMODULE_DEPLOY_KEY_<NAME>        the private key contents, or
//	GIT_SUBMODULE_DEPLOY_KEY_FILE_<NAME>   a mounted path (preferred)
//
// where <NAME> is the submodule's .gitmodules name (the [submodule "..."]
// header — by default the path it was added at), upper-cased, with every
// character that is not A-Z or 0-9 replaced by an underscore:
//
//	[submodule "vault/Cove QMS"]  ->  GIT_SUBMODULE_DEPLOY_KEY_FILE_VAULT_COVE_QMS
//
// Keys are routed with an SSH host alias per submodule, set as the host of the
// submodule's own origin URL, so .gitmodules keeps the canonical URL for every
// other clone. Only ssh URLs (git@host:path or ssh://host/path) can be routed;
// anything else is left to git as-is.

type submodule struct {
	name   string // .gitmodules name
	path   string // path relative to the repo root, slash-separated
	url    string // canonical URL from .gitmodules
	branch string // remote branch to track (default main)
	env    string // <NAME> suffix of its key env vars
	repo   *repo  // its checkout (path under the repo dir)
	rc     rc     // result this cycle (rcLocalOnly until its cycle ran)
}

func (s *submodule) ctx() string { return "submodule " + s.name }

// onRemote: the submodule's HEAD is known to be on its remote, so the outer
// repo may record it as the gitlink. Otherwise the gitlink keeps its previous
// value — the outer push must never reference a commit the remote lacks.
func (s *submodule) onRemote() bool { return s.rc == rcOK }

// envName derives the <NAME> suffix: upper-case, every byte outside A-Z/0-9
// becomes "_" (per byte, like `tr -c` under LC_ALL=C).
func envName(name string) string {
	b := []byte(strings.ToUpper(name))
	for i, c := range b {
		if !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') {
			b[i] = '_'
		}
	}
	return string(b)
}

// sshAlias is the ssh Host alias used to route a submodule's key.
func sshAlias(env string) string {
	return "bridge-submodule-" + strings.ReplaceAll(strings.ToLower(env), "_", "-")
}

func keyFile(home, env string) string {
	return filepath.Join(home, ".ssh", "id_submodule_"+env)
}

// sshURL is a parsed ssh remote: git@host:path (scp form) or
// ssh://[user@]host[:port]/path.
type sshURL struct {
	user, host, port, path string
	scp                    bool
}

var (
	sshFormRe = regexp.MustCompile(`^ssh://(?:([^@/]+)@)?([^:/]+)(?::([0-9]+))?(/.*)$`)
	scpFormRe = regexp.MustCompile(`^(?:([^@/]+)@)?([^:/]+):(.*)$`)
)

// parseSSHURL returns ok=false for anything that isn't an ssh URL (https,
// file paths, ...): those have no deploy key to route.
func parseSSHURL(url string) (sshURL, bool) {
	if m := sshFormRe.FindStringSubmatch(url); m != nil {
		return sshURL{user: m[1], host: m[2], port: m[3], path: m[4]}, true
	}
	if !strings.Contains(url, "://") {
		if m := scpFormRe.FindStringSubmatch(url); m != nil {
			return sshURL{user: m[1], host: m[2], path: m[3], scp: true}, true
		}
	}
	return sshURL{}, false
}

// withHost is the same URL with the host swapped for alias.
func (u sshURL) withHost(alias string) string {
	user := ""
	if u.user != "" {
		user = u.user + "@"
	}
	if u.scp {
		return user + alias + ":" + u.path
	}
	port := ""
	if u.port != "" {
		port = ":" + u.port
	}
	return "ssh://" + user + alias + port + u.path
}

// unsafePath: absolute, or with an empty, "." or ".." component (or ".git",
// when the value becomes a directory under .git/modules).
func unsafePath(p string, rejectGit bool) bool {
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." || (rejectGit && seg == ".git") {
			return true
		}
	}
	return false
}

// discoverSubmodules reads <repo>/.gitmodules, keeping only submodules whose
// path lies inside the vault. Entries with an unsafe path or name are skipped
// with a warning. Branch defaults to main; `branch = ...` overrides
// (`branch = .`, git's "same branch as the superproject", also means main).
func discoverSubmodules(cfg config) []*submodule {
	gm := filepath.Join(cfg.repoDir, ".gitmodules")
	if !isFile(gm) {
		return nil
	}
	list, err := gitConfigZ(gm, "--get-regexp", `^submodule\..*\.path$`)
	if err != nil {
		return nil
	}
	vaultRel := cfg.vaultRel()
	var subs []*submodule
	for _, entry := range strings.Split(list, "\x00") {
		if entry == "" {
			continue
		}
		key, path, _ := strings.Cut(entry, "\n")
		name := strings.TrimSuffix(strings.TrimPrefix(key, "submodule."), ".path")
		path = strings.TrimSuffix(strings.TrimPrefix(path, "./"), "/")
		if unsafePath(path, false) {
			logErr("ignoring submodule %q: unsafe path %q", name, path)
			continue
		}
		// The name becomes .git/modules/<name>, so it must be as safe as the path.
		if unsafePath(name, true) {
			logErr("ignoring submodule %q: unsafe name", name)
			continue
		}
		// Only submodules inside the vault are the bridge's business.
		if vaultRel != "" && !strings.HasPrefix(path+"/", vaultRel+"/") {
			continue
		}
		url, _ := gitConfig(gm, "--get", "submodule."+name+".url")
		branch, _ := gitConfig(gm, "--get", "submodule."+name+".branch")
		if url == "" {
			logErr("ignoring submodule %q: no url in .gitmodules", name)
			continue
		}
		if branch == "" || branch == "." {
			branch = "main"
		}
		env := envName(name)
		for _, prev := range subs {
			if prev.env == env {
				logErr("submodules %q and %q both map to %s — they will share one deploy key setting", name, prev.name, env)
			}
		}
		subs = append(subs, &submodule{
			name: name, path: path, url: url, branch: branch, env: env,
			repo: &repo{dir: filepath.Join(cfg.repoDir, filepath.FromSlash(path))},
			rc:   rcLocalOnly,
		})
	}
	return subs
}

func gitConfig(file string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"config", "-f", file}, args...)...).Output()
	return strings.TrimRight(string(out), "\n"), err
}

func gitConfigZ(file string, args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"config", "-f", file, "-z"}, args...)...).Output()
	return string(out), err
}

// hasKey: a deploy key was installed for the submodule.
func (s *submodule) hasKey(cfg config) bool {
	st, err := os.Stat(keyFile(cfg.home, s.env))
	return err == nil && st.Size() > 0
}

// needsNoKey: a local path (or file:// URL) — reachable without any
// credentials, so nothing to route. An https:// or git:// URL is neither that
// nor routable: the bridge has no way to authenticate to it.
func needsNoKey(url string) bool {
	return !strings.Contains(url, "://") || strings.HasPrefix(url, "file://")
}

// canReachRemote: the bridge can talk to the submodule's remote — its key is
// installed and routed (ssh), or the URL needs no key at all.
func (s *submodule) canReachRemote(cfg config) bool {
	if _, ok := parseSSHURL(s.url); ok {
		return s.hasKey(cfg)
	}
	return needsNoKey(s.url)
}

// routable: the submodule has a key AND an ssh URL to route it to.
func (s *submodule) routable(cfg config) (sshURL, bool) {
	if !s.hasKey(cfg) {
		return sshURL{}, false
	}
	return parseSSHURL(s.url)
}

// routedURL is what the submodule's own origin should use: the canonical URL
// with the host swapped for its ssh alias when routable, else the canonical
// URL itself. Set on the submodule's remote — not a global insteadOf, which is
// a prefix rewrite and would also catch any other URL the canonical one is a
// prefix of (the outer repo's, say).
func (s *submodule) routedURL(cfg config) string {
	if u, ok := s.routable(cfg); ok {
		return u.withHost(sshAlias(s.env))
	}
	return s.url
}

// configureSubmoduleRouting (re)writes the per-submodule ssh Host aliases for
// every discovered submodule that has a key. Idempotent — run at the start of
// every cycle so submodules added later (or keys added on restart) pick up
// routing without manual steps; the file is only replaced when it changes.
//
// $HOME/.ssh/config Includes the alias file; each alias block carries ONLY
// that submodule's IdentityFile (ssh accumulates IdentityFile across matching
// Host blocks, and GitHub authenticates the first key it recognises, so the
// outer deploy key must never be offered to a submodule host — the outer
// key's block excludes the aliases).
func configureSubmoduleRouting(cfg config, subs []*submodule) error {
	var b bytes.Buffer
	b.WriteString("# Generated by the bridge from .gitmodules — do not edit.\n")
	for _, s := range subs {
		u, ok := s.routable(cfg)
		if !ok {
			continue
		}
		fmt.Fprintf(&b, "Host %s\n  HostName %s\n  HostKeyAlias %s\n", sshAlias(s.env), u.host, u.host)
		if u.port != "" {
			fmt.Fprintf(&b, "  Port %s\n", u.port)
		}
		if u.user != "" {
			fmt.Fprintf(&b, "  User %s\n", u.user)
		}
		fmt.Fprintf(&b, "  IdentityFile %s\n\n", keyFile(cfg.home, s.env))
	}
	conf := filepath.Join(cfg.home, ".ssh", "bridge_submodules.conf")
	if cur, err := os.ReadFile(conf); err == nil && bytes.Equal(cur, b.Bytes()) {
		return nil
	}
	tmp, err := os.CreateTemp(filepath.Dir(conf), "bridge_submodules.conf.")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(b.Bytes()); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Rename(tmp.Name(), conf); err != nil {
		os.Remove(tmp.Name())
		return err
	}

	// Earlier bridge versions routed with global url.insteadOf rewrites; drop
	// any left behind so they can't catch unrelated URLs.
	out, _ := exec.Command("git", "config", "--global", "--name-only", "--get-regexp", `^url\..*bridge-submodule-.*\.insteadof$`).Output()
	for _, name := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if name == "" {
			continue
		}
		section := strings.TrimSuffix(strings.TrimPrefix(name, "url."), ".insteadof")
		_ = exec.Command("git", "config", "--global", "--remove-section", "url."+section).Run()
	}
	return nil
}
