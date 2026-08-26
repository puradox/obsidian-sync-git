package main

import "testing"

func TestEnvName(t *testing.T) {
	cases := map[string]string{
		"vault/Cove QMS": "VAULT_COVE_QMS",
		"notes-2.0":      "NOTES_2_0",
		"already_UPPER":  "ALREADY_UPPER",
		"vault/Café":     "VAULT_CAF__", // per byte, like tr -c under LC_ALL=C
	}
	for in, want := range cases {
		if got := envName(in); got != want {
			t.Errorf("envName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSSHAlias(t *testing.T) {
	if got := sshAlias("VAULT_COVE_QMS"); got != "bridge-submodule-vault-cove-qms" {
		t.Errorf("sshAlias = %q", got)
	}
}

func TestParseSSHURL(t *testing.T) {
	cases := []struct {
		url     string
		ok      bool
		aliased string // withHost("x")
		host    string
	}{
		{"git@github.com:coveqms/notes.git", true, "git@x:coveqms/notes.git", "github.com"},
		{"github.com:coveqms/notes.git", true, "x:coveqms/notes.git", "github.com"},
		{"ssh://git@github.com:22/coveqms/notes.git", true, "ssh://git@x:22/coveqms/notes.git", "github.com"},
		{"ssh://github.com/coveqms/notes.git", true, "ssh://x/coveqms/notes.git", "github.com"},
		{"https://github.com/a/b.git", false, "", ""},
		{"/tmp/remotes/notes.git", false, "", ""},
		{"../notes.git", false, "", ""},
		{"file:///tmp/notes.git", false, "", ""},
	}
	for _, c := range cases {
		u, ok := parseSSHURL(c.url)
		if ok != c.ok {
			t.Errorf("parseSSHURL(%q) ok = %v, want %v", c.url, ok, c.ok)
			continue
		}
		if !ok {
			continue
		}
		if u.host != c.host {
			t.Errorf("parseSSHURL(%q).host = %q, want %q", c.url, u.host, c.host)
		}
		if got := u.withHost("x"); got != c.aliased {
			t.Errorf("parseSSHURL(%q).withHost(x) = %q, want %q", c.url, got, c.aliased)
		}
	}
}

func TestUnsafePath(t *testing.T) {
	cases := []struct {
		p         string
		rejectGit bool
		want      bool
	}{
		{"vault/Cove QMS", false, false},
		{"vault", false, false},
		{"/etc/x", false, true},
		{"vault/../x", false, true},
		{"vault/./x", false, true},
		{"vault//x", false, true},
		{"vault/.git/x", false, false},
		{"vault/.git/x", true, true},
		{"../../../tmp/x", true, true},
	}
	for _, c := range cases {
		if got := unsafePath(c.p, c.rejectGit); got != c.want {
			t.Errorf("unsafePath(%q, %v) = %v, want %v", c.p, c.rejectGit, got, c.want)
		}
	}
}

func TestVaultRel(t *testing.T) {
	cases := []struct{ repo, vault, want string }{
		{"/vault", "/vault", ""},
		{"/vault", "/vault/vault", "vault"},
		{"/vault", "/vault/a/b", "a/b"},
	}
	for _, c := range cases {
		if got := (config{repoDir: c.repo, vaultDir: c.vault}).vaultRel(); got != c.want {
			t.Errorf("vaultRel(%q, %q) = %q, want %q", c.repo, c.vault, got, c.want)
		}
	}
}
