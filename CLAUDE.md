# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A personal dotfiles repository plus a single-file helper TUI that syncs config folders
between the live home directory and versioned snapshots. **All actual code lives in
`src/tui.py`** (~640 lines). Everything under `profiles/` is *data* — committed snapshots of
the user's real config (`.config/hypr`, `.config/quickshell`, `.claude`, etc.), not source to
edit. See `README.md` for the full user-facing CLI reference.

## The one source file: `src/tui.py`

A `rich`-based interactive TUI with no external state beyond config and git. Key design facts:

- **Path model**: everything is keyed by *home-relative* paths (`.claude`,
  `.config/hypr`). `profiles/` mirrors `~` using those same keys. `Node` (a dataclass tree
  with optional `.config` children) is the single representation used by sync, apply, and
  clean-profile.
- **Config-driven, read at runtime** (no rebuild to change behavior):
  - `config/ignore.toml` — folder *names* (not paths) hidden from selection lists; matched
    against both top-level `~` dotfolders and `.config` subdirs. Holds secrets/noise to keep
    out of the repo (`.ssh`, `.gnupg`, browser profiles).
  - `config/includes.toml` — per-folder copy whitelists. A listed folder copies *only* its
    whitelisted entries; unlisted folders copy wholesale. Used to keep `.claude`'s
    caches/history/projects out of the synced snapshot.
- **Cache**: last selection is remembered per-user in `config/cache/<username>.json`
  (gitignored). Sync/apply pre-check it; clean-profile never pre-checks (safety — avoids an
  accidental delete from a stale selection).
- **Commands** (`cmd_sync`, `cmd_apply`, `cmd_clean_backups`, `cmd_clean_profile`): sync and
  clean-profile each do `git pull --rebase` → commit → push with a host/user/time message.
  Apply backs up anything it replaces to `<name>.bak-<timestamp>` before overwriting.
- **Custom key input**: `interactive_select` / `menu_select` use raw terminal key reading
  (`_read_key`, `_key_loop`) over a Rich `Live` render — not a TUI framework. Touch with care.

## Commands

```bash
ruff check src/tui.py              # lint
pyright src/tui.py                 # type-check (code uses py3.9+ type hints)
./tui                              # run the committed binary (interactive menu)
python src/tui.py --sync           # run from source
```

There are no tests. Verify changes by running the tool against the live tree.

## The `tui` binary (important)

The `tui` file at the repo root is a PyInstaller `--onefile` build of `src/tui.py`, **committed
by CI** (`.github/workflows/build-tui.yml`) on any push touching `src/tui.py`, `src/tui.spec`,
`pyproject.toml`, or the workflow, with commit message `Build tui binary [skip ci]`.

- Do **not** hand-edit or manually rebuild the committed binary — let CI produce it. If you
  change `src/tui.py`, the binary will be stale until CI rebuilds it on push.
- The binary reads `config/*.toml` and writes `profiles/` **relative to its own location**, so
  it must stay at the repo root. Nothing is baked in.
- Local build (rarely needed): `pyinstaller --onefile --name tui --console src/tui.py`.

Python version is pinned in `.python-version`; runtime dep is `rich==15.0.0`.
