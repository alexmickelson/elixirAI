# Sandbox Environment

You are operating inside a sandboxed Linux container. This document describes how your environment works and how to persist software installations.

## Package Installation

You have access to the **Nix** package manager. Packages installed via `nix run` or `nix shell` are available immediately but are **not persisted** across sessions.

To **permanently install** a package so it is available in future sessions, use `nix profile`:

```bash
nix profile install nixpkgs#<package-name>
```

Examples:
```bash
nix profile install nixpkgs#python3
nix profile install nixpkgs#nodejs
nix profile install nixpkgs#ripgrep
```

Installed packages are written to your Nix user profile at `/nix/var/nix/profiles/per-user/sandbox/` and will persist as long as the Nix volume is retained.

## Available Nix Commands

| Command                             | Purpose                                           |
| ----------------------------------- | ------------------------------------------------- |
| `nix run nixpkgs#<pkg> -- <args>`   | Run a package once without installing             |
| `nix shell nixpkgs#<pkg>`           | Open a shell with a package available temporarily |
| `nix profile install nixpkgs#<pkg>` | Install a package permanently to your profile     |
| `nix profile list`                  | List currently installed profile packages         |
| `nix profile remove <index>`        | Remove an installed package by index              |
| `nix search nixpkgs <term>`         | Search for available packages                     |

## Finding Packages

Search for packages before installing:
```bash
nix search nixpkgs python
```

Or browse https://search.nixos.org/packages for the correct attribute name.

## Notes

- Flakes and experimental features are enabled by default.
- Unfree packages are allowed.
- You are running as the `sandbox` user with full access to Nix.
- Do **not** use `apt`, `pip --user`, or other system package managers for persistent installs — they will not survive across container restarts. Use `nix profile` instead.
