# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal dotfiles repository plus a single helper TUI that syncs config folders between the
live home directory and versioned snapshots. **The tool is a Rust CLI under `src/`.** Everything
under `profiles/` is *data* — committed snapshots of the user's real config (`.config/hypr`,
`.config/quickshell`, `.claude`, etc.), not source to edit. See `README.md` for the full
user-facing CLI reference.

## Source layout (`src/*.rs`)

A `crossterm`-based interactive TUI with no external state beyond config and git. One binary
crate (`Cargo.toml` at the repo root), split into modules:

- `main.rs` — `clap` arg parsing (four mutually-exclusive flags `-s/-a/-c/-P`; `-a` takes
  zero-or-more names) and dispatch; builds `Paths` and calls into `commands`.
- `model.rs` — the shared types: `Node` (a selection-tree row) and `Paths` (the runtime path
  model). **Everything is keyed by *home-relative* paths** (`.claude`, `.config/hypr`);
  `profiles/` mirrors `~` using those same keys. `Paths::resolve()` finds the repo root from
  the running binary's own directory (or, under `cargo run`, an ancestor holding `config/` +
  `profiles/`).
- `config.rs` — load/save of `config/{ignore,includes,hosts}.toml` and the per-user JSON cache.
- `tree.rs` — tree discovery (`build_sync_tree`/`build_apply_tree`), `prune_ignored`, and the
  selection-resolution logic (`effective_selection`, `blocked_names`, whole-`.config` handling).
- `git.rs` — the `git(...)` subprocess wrapper and `last_sync_info` (a single `git log` pass).
- `copy.rs` — symlink-preserving recursive copy, the includes whitelist, host-override
  relocation/overlay, and `apply_key` (with `<name>.bak-<timestamp>` backups).
- `tui.rs` — the hand-drawn checklist/menu: a `crossterm` raw-mode key loop over a transient
  redraw. Not a TUI framework — touch with care.
- `commands.rs` — the five commands (`cmd_sync`, `cmd_apply`, `cmd_block`, `cmd_clean_backups`,
  `cmd_clean_profile`) and the interactive `run_menu`.
- `ui.rs` — ANSI styling helpers that emit color only when stdout is a TTY.

## Config (read at runtime — no rebuild to change behavior)

- `config/ignore.toml` — folder *names* (not paths) hidden from selection lists; matched
  against both top-level `~` dotfolders and `.config` subdirs. Holds secrets/noise to keep out
  of the repo (`.ssh`, `.gnupg`, browser profiles).
- `config/includes.toml` — per-folder copy whitelists. A listed folder copies *only* its
  whitelisted entries; unlisted folders copy wholesale. Keeps `.claude`'s
  caches/history/projects out of the synced snapshot.
- `config/hosts.toml` — per-machine override paths, keyed by folder. Declared paths live under
  `profiles/hosts/<hostname>/<folder>/...` (one copy per machine) instead of the shared
  snapshot, so machine-specific files never clobber another machine's on sync.
- **Cache**: last selection is remembered per-user in `config/cache/<username>.json`
  (gitignored). Sync/apply pre-check it; clean-profile never pre-checks (safety — avoids an
  accidental delete from a stale selection).

Sync and clean-profile each do `git pull --rebase` → commit → push with a host/user/time
message. Apply backs up anything it replaces to `<name>.bak-<timestamp>` before overwriting.

## Commands

```bash
cargo build --release              # build (dynamic local binary)
cargo clippy --all-targets -- -D warnings   # lint
cargo test                         # unit tests (pure logic)
cargo run -- --sync                # run from source
./tui                              # run the committed binary (interactive menu)
```

## The `tui` binary (important)

The `tui` file at the repo root is a **static `x86_64-unknown-linux-musl`** release build,
**committed by CI** (`.github/workflows/build-tui.yml`) on any push touching `Cargo.toml`,
`Cargo.lock`, `src/**`, or the workflow, with commit message `Build tui binary [skip ci]`.

- Do **not** hand-edit or manually rebuild the committed binary — let CI produce it. If you
  change `src/`, the binary will be stale until CI rebuilds it on push.
- The binary reads `config/*.toml` and writes `profiles/` **relative to its own location**, so
  it must stay at the repo root. Nothing is baked in.
- Local musl build (rarely needed):
  `cargo build --release --target x86_64-unknown-linux-musl` (needs the musl target and
  `musl-tools`).

Runtime deps: none (static binary). `Cargo.lock` is committed.
