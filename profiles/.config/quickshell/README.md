# Quickshell config

A [Quickshell](https://quickshell.org) (QML) desktop shell for Hyprland: a top bar with
workspaces, clock, audio, network, memory/cpu/temperature, battery, screenshot, and a
power menu — plus a PAM lock screen and a greetd greeter.

## Install & run

```bash
yay -S quickshell         # AUR (or: yay -S quickshell-git for the latest)
qs                        # run the default config (this shell.qml)
```

Autostart from Hyprland (`~/.config/hypr/hyprland.conf`):

```
exec-once = qs
```

For the **greeter + lock screen** (greetd, cage, PAM, ACLs), see
[`session-setup/README.md`](session-setup/README.md).

## Dependencies

Derived from the imports and external commands the modules actually use. Package names are
for Arch.

| Used by | What | Package(s) |
| --- | --- | --- |
| core | Quickshell | `quickshell` (AUR) |
| compositor | `Quickshell.Hyprland`, lock screen (`WlSessionLock`) | `hyprland` |
| fonts | "Noto Sans Mono" (text), "Symbols Nerd Font" (icons) | `noto-fonts`, `ttf-nerd-fonts-symbols` |
| Audio.qml | `Quickshell.Services.Pipewire` + launches `pavucontrol` | `pipewire`, `wireplumber`, `pavucontrol` |
| Battery.qml | `Quickshell.Services.UPower` | `upower` |
| Network.qml | `nmcli` / `nmtui` | `networkmanager` |
| Screenshot.qml | `grim -g "$(slurp)" - \| swappy -f -` | `grim`, `slurp`, `swappy` |
| Temperature.qml | `sensors -j` | `lm_sensors` |
| Cpu/Memory/Network/Temperature menus | `kitty -e btop` / `nmtui` / `watch sensors` | `kitty`, `btop` (`watch` ← `procps-ng`, base) |
| Notification.qml | `swaync-client -t -sw` | `swaync` |
| PowerMenu.qml | `loginctl`, `systemctl` (logout/reboot/shutdown) | `polkit` (active-session actions; usually already present) |
| greeter + lock | greetd greeter, PAM lock | `greetd`, `cage`, `pam` (base) — see `session-setup/` |

### Optional

- `nvidia-utils` — only for GPU temperature in `Temperature.qml` (it probes
  `command -v nvidia-smi` and silently skips GPU temp if absent).

## Layout

```
shell.qml              # entrypoint: one Bar per monitor
greeter.qml            # greetd greeter entrypoint (run under cage by greetd)
services/              # singletons: Theme, Lock (WlSessionLock + PAM + IPC)
components/            # shared: Group, Icon, MenuButton, PopupMenu, Separator
modules/Bar.qml        # the bar layout
modules/widgets/       # bar widgets (Audio, Clock, PowerMenu, …)
session-setup/         # greetd/PAM files + setup guide
```
