# dotfiles

A repository to hold my dotfiles and a little helper tool I had claude build to manage my profiles between devices.

## TUI

`tui` (built from `src/tui.py`) copies config folders between your live home directory and
versioned snapshots in `profiles/`.

Run with no arguments for an interactive menu (Sync / Apply / Clean backups / Quit), or use
flags directly:

- `tui --sync` — copy selected folders from `~` into `profiles/` and push.
- `tui --apply [NAME...]` — restore folders from `profiles/` into `~` (backs up anything it
  replaces to `<name>.bak-<timestamp>`). With no names it's interactive; pass home-relative
  names (e.g. `.config/hypr`, `.claude`) for a non-interactive apply.
- `tui --clean-backups` — list and delete `*.bak-*` left in `~` and `~/.config`.

### Selecting folders

Sync and apply both show an interactive checkbox list (↑/↓ move, space toggle, enter
confirm, q/esc cancel). The selectable folders are the dotfolders in `~` plus the subdirs of
`~/.config`, shown hierarchically — `~/.config`'s subdirs are nested under a `.config` row.
Check `.config` itself to sync/apply the **whole** folder, or check individual subdirs.

Your last selection is remembered per-user in `.data/cache/<username>.json` (gitignored) and
pre-checked on the next run.

### Layout

- `profiles/` mirrors home-relative paths: `profiles/.claude`, `profiles/.config/<name>`.
- `.data/ignore.toml` — folder names hidden from the list (noise/secrets like `.ssh`,
  `.gnupg`, `.cache`, browser profile dirs). Edited freely; read at runtime.
- `.data/includes.toml` — per-folder copy whitelists. By default `.claude` only syncs
  `agents/`, `commands/`, `teams/`, `plugins/`, `CLAUDE.md`, `settings.json`,
  `statusline-command.sh` (so its caches/history/projects stay out of the repo).
