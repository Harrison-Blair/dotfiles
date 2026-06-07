# dotfiles

A repository to hold my dotfiles and a little helper tool I had claude build to manage my profiles between devices.

> [!NOTE]
> This README, and the helper tool it documents, were mostly written with Claude.

## TUI

`tui` (built from `src/tui.py`) copies config folders between your live home directory and
versioned snapshots in `profiles/`.

Run with no arguments for an interactive menu (Sync to cloud / Apply from profiles / Clean
profile / Clean backups / Quit), or use flags directly (mutually exclusive):

- `-s`, `--sync` — copy selected folders from `~` into `profiles/`, then `git pull --rebase`,
  commit (`Sync from <host> at <time> by <user>`), and push.
- `-a`, `--apply [NAME...]` — restore folders from `profiles/` into `~` (backs up anything it
  replaces to `<name>.bak-<timestamp>`). With no names it's interactive; pass home-relative
  names (e.g. `.config/hypr`, `.claude`) for a non-interactive apply.
- `-c`, `--clean-backups` — list and delete `*.bak-*` left in `~` and `~/.config`.
- `-P`, `--clean-profile` — delete selected folders **from** `profiles/` (parts or the whole
  `.config`, same selection rules as sync), then `git pull --rebase`, commit (`Clean profile
  from <host> at <time> by <user>: <folders>`), and push. The checkbox list annotates each
  folder with when it was last synced, from where, and by whom (read from git history); a
  confirmation prompt guards the deletion.
- `-v`, `--verbose` — enable verbose output.

When apply finds nothing selected from `profiles/`, it falls back to an interactive list of
the `*.bak-*` backups in `~` and `~/.config` and restores the one you pick (re-backing up the
current copy first).

### Selecting folders

Sync, apply, and clean-profile all show an interactive checkbox list (↑/↓ or j/k move, space
toggle, enter confirm, q/esc cancel). The selectable folders are the dotfolders in `~` (or in
`profiles/` for apply/clean-profile) plus the subdirs of `.config`, shown hierarchically —
`.config`'s subdirs are nested under a `.config` row. Check `.config` itself to act on the
**whole** folder (children then show as implied `[-]`), or check individual subdirs.

Sync and apply remember your last selection per-user in `config/cache/<username>.json`
(gitignored) and pre-check it on the next run. Clean-profile never pre-checks (it starts
empty so a cached selection can't cause an accidental delete).

### Layout

- `profiles/` mirrors home-relative paths: `profiles/.claude`, `profiles/.config/<name>`.
- `config/ignore.toml` — folder names hidden from the list (noise/secrets like `.ssh`,
  `.gnupg`, `.cache`, browser profile dirs). Edited freely; read at runtime.
- `config/includes.toml` — per-folder copy whitelists. By default `.claude` only syncs
  `agents/`, `commands/`, `teams/`, `plugins/`, `CLAUDE.md`, `settings.json`,
  `statusline-command.sh` (so its caches/history/projects stay out of the repo).

### Building

The `tui` binary at the repo root is a PyInstaller `--onefile` build of `src/tui.py`,
committed by the **Build Tui Helper** GitHub Actions workflow
(`.github/workflows/build-tui.yml`) on pushes that touch `src/tui.py`, `src/tui.spec`,
`pyproject.toml`, or the workflow itself (commit message `Build tui binary [skip ci]`).

To build locally: `pyinstaller --onefile --name tui --console src/tui.py` (deps:
`rich==15.0.0`, `pyinstaller`; Python version pinned in `.python-version`; `src/tui.spec` is
the generated spec).

Nothing is baked into the binary — it reads `config/*.toml` and writes `profiles/` relative to
its own location, so the `tui` binary must live at the repo root.
