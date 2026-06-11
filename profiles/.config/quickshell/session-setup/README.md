# Session setup — greeter + lock screen

System-side glue for the Quickshell login/lock stack. The UI itself lives in
`~/.config/quickshell` (`greeter.qml`, `services/Lock.qml`, the power menu); this
directory only holds the two files that have to be copied into `/etc` and documents the
one-time commands.

There is **no install script** on purpose — it's a handful of one-time commands, and the
privilege boundary matters: the ACL step needs no root, the `/etc` writes do. Run them by
hand so each is deliberate (this touches your login path).

## What's here

- `quickshell-lock` — PAM service for the lock screen → `/etc/pam.d/quickshell-lock`.
  Defers to the system stack (`include system-auth`). The lock's `PamContext` selects it
  by the property `config: "quickshell-lock"`.
- `config.toml` — greetd config → `/etc/greetd/config.toml`. Runs the greeter Quickshell
  under cage on VT 1 (`-d`, no decorations; `-m last`, single monitor — cage ignores
  client output requests, so the monitor is whichever connector enumerates last).

## One-time setup

### 1. Greeter filesystem access (no sudo — you own these paths)

The greeter runs as the `greeter` user, which can't read your home by default
(`/home/penguin` is `0700`). Grant it just enough: **traverse** your home, **read** the
quickshell tree. Everything under `quickshell/` is already world-readable, so this is the
only gate.

```bash
setfacl -m  u:greeter:--x  /home/penguin                        # traverse only (not list/read)
setfacl -R  -m  u:greeter:r-X /home/penguin/.config/quickshell  # read the quickshell tree
setfacl -R -d -m u:greeter:r-X /home/penguin/.config/quickshell # default: new files inherit
```

Why this is enough / safe:
- `--x` on `$HOME` is a turnstile — greeter can pass through but `ls ~` stays denied.
- Secrets (`600`/`700` keys, password stores) remain unreadable; the read grant is scoped
  to `quickshell/`.
- The **default** ACL means components you add later are auto-readable — nothing to re-run.
- Requires `/home` to be readable before login. It's a plain local ext4 mount, so it is.
  (If you ever switch to login-time home encryption, the pre-login greeter can't read it.)

### 2. System files (sudo)

```bash
sudo install -m 0644 quickshell-lock /etc/pam.d/quickshell-lock
sudo install -m 0644 config.toml     /etc/greetd/config.toml
```

The lock works after step 1 of this section alone (just the PAM file) — you can test it
before touching greetd at all.

## One source of truth

The greeter runs **live** from `~/.config/quickshell` via the ACL — there is no copy.
Editing the greeter, theme, or shared components needs **no re-run** of anything (the
default ACL covers new files). Only redo a step if you change *that* file: the greetd
command (`config.toml`) or the PAM stack (`quickshell-lock`).

## Enable, test, roll back

Test **before** committing the login path:

```bash
# Lock — with a spare TTY (Ctrl+Alt+F3) logged in as an escape hatch:
qs ipc call lock lock          # engage; type your password to release

# Greeter — validate the QML nested first (renders in a window, no greetd):
cage -s -- qs -p /home/penguin/.config/quickshell/greeter.qml
# Confirm the greeter user can actually read it after the ACL grant.
# NOTE: just read the file — do NOT launch qs as greeter. The greeter user has no
# login session here, so no XDG_RUNTIME_DIR / Wayland display, and qs would crash.
# Under real greetd those are provided. A successful cat = the ACL is correct.
sudo -u greeter cat /home/penguin/.config/quickshell/greeter.qml >/dev/null && echo "greeter can read it"
```

Only then commit to the login path. Keep a root login on a **second VT (or SSH)** ready:

```bash
sudo systemctl enable greetd   # then reboot
```

getty is never disabled manually — `greetd.service` declares
`Conflicts=getty@tty1.service`, so systemd stops the tty1 getty when greetd activates;
other VTs keep their on-demand gettys (your escape hatch). If the greeter misbehaves,
switch to the spare VT and revert:

```bash
sudo systemctl disable greetd
```

Optional: bind the lock in Hyprland — `bind = SUPER, L, exec, qs ipc call lock lock`.
