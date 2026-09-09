# Scripts

| Script | Where it runs | What it does |
| --- | --- | --- |
| `skillsync.sh` | Any machine | Pulls skills from this repository and installs them locally. Read-only client. |
| `pull.sh` | The dev machine with a checkout at `~/source/dotfiles` | Fast-forwards the checkout and installs its skills. |
| `send.sh` | Same | Copies local skills into the checkout, commits, and pushes. |

## skillsync.sh

Needs bash, git, and coreutils. Works on Linux, macOS, and Git Bash on Windows.

Each run asks GitHub for the tip of `main`. If it matches the commit recorded
in `~/.agents/.skillsync-state`, the run exits immediately. Otherwise it makes a
shallow clone, validates every skill under `.agents/skills`, and installs each
one:

- `~/.agents/skills/<name>` is replaced wholesale, so files deleted upstream
  disappear locally too;
- `~/.claude/skills/<name>` becomes an absolute symlink to the canonical copy
  (on Windows: symlink, then junction, then a plain copy as fallbacks);
- anything else under either directory is never touched, and a skill removed
  from the repository stays on the machine.

```
skillsync.sh                 # check, fetch if changed, install
skillsync.sh --check         # exit 0 if up to date, 3 if an update is available
skillsync.sh --dry-run       # print the ADD/UPDATE/REPLACE/LINK manifest only
skillsync.sh --force         # reinstall even when the recorded commit matches
skillsync.sh --self-update   # also refresh this script from the repository
skillsync.sh --source DIR    # install from a local checkout instead of cloning
```

`--repo`, `--branch`, `--skills-dir`, `--claude-dir`, and `--state-file`
override the defaults, as do the matching `SKILLSYNC_*` environment variables.
Exit status is 1 when any skill was skipped as invalid; valid siblings still
install.

### Install on a new machine

Linux and macOS:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/Harrison-Blair/dotfiles/main/scripts/skillsync.sh -o ~/.local/bin/skillsync.sh
chmod +x ~/.local/bin/skillsync.sh
~/.local/bin/skillsync.sh
```

Windows, from Git Bash:

```sh
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/Harrison-Blair/dotfiles/main/scripts/skillsync.sh -o ~/bin/skillsync.sh
bash ~/bin/skillsync.sh
```

### Run on a schedule

All three recipes run at login and then hourly, with `--self-update` so the
client keeps itself current.

**Linux (systemd user timer).** Save as `~/.config/systemd/user/skillsync.service`:

```ini
[Unit]
Description=Sync agent skills from dotfiles

[Service]
Type=oneshot
ExecStart=%h/.local/bin/skillsync.sh --self-update
```

and `~/.config/systemd/user/skillsync.timer`:

```ini
[Unit]
Description=Sync agent skills hourly

[Timer]
OnStartupSec=1min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

Then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now skillsync.timer
journalctl --user -u skillsync.service   # logs
```

**macOS (launchd).** Save as `~/Library/LaunchAgents/dev.harrison.skillsync.plist`,
replacing `USERNAME`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.harrison.skillsync</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/USERNAME/.local/bin/skillsync.sh</string>
    <string>--self-update</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>/tmp/skillsync.log</string>
  <key>StandardErrorPath</key><string>/tmp/skillsync.log</string>
</dict>
</plist>
```

Then:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.harrison.skillsync.plist
launchctl kickstart gui/$(id -u)/dev.harrison.skillsync   # run now
```

**Windows (Task Scheduler).** From an elevated PowerShell, with Git installed
at the default location:

```powershell
$bash = 'C:\Program Files\Git\bin\bash.exe'
$args = "-lc `"~/bin/skillsync.sh --self-update`""
$action = New-ScheduledTaskAction -Execute $bash -Argument $args
$triggers = @(
  (New-ScheduledTaskTrigger -AtLogOn),
  (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 1))
)
$settings = New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable
Register-ScheduledTask -TaskName 'SkillSync' -Action $action -Trigger $triggers -Settings $settings
Start-ScheduledTask -TaskName 'SkillSync'   # run now
```

Symlinks on Windows need Developer Mode or an elevated task; without either
the client falls back to directory junctions, which need no privileges.

### Tests

```sh
bash scripts/tests/skillsync_test.sh
```

The suite builds a throwaway upstream repository and a fake `HOME`, then
drives the client through the real clone path.
