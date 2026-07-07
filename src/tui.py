import argparse
import json
import os
import re
import select
import shutil
import socket
import subprocess
import sys
import termios
import tomllib
import tty
from dataclasses import dataclass
from datetime import datetime
from getpass import getuser
from pathlib import Path

from rich.console import Console
from rich.live import Live
from rich.prompt import Confirm, Prompt
from rich.text import Text

HOME = Path.home()
CONFIG_DIR = HOME / ".config"
CLAUDE_DIR = HOME / ".claude"
REPO_ROOT = (
    Path(sys.executable).resolve().parent
    if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent.parent
)
PROFILES_DIR = REPO_ROOT / "profiles"
HOSTS_DIR = PROFILES_DIR / "hosts"
DATA_DIR = REPO_ROOT / "config"
CACHE_DIR = DATA_DIR / "cache"
CACHE_VERSION = 1

console = Console()


@dataclass
class Node:
    key: str  # home-relative path, e.g. ".config/hypr", ".claude", ".config"
    label: str  # display text (basename)
    depth: int  # 0 = top-level, 1 = child under .config
    source: Path  # absolute source path
    is_parent: bool = False  # True only for the ".config" aggregate row
    parent_key: str | None = None  # ".config" for children, else None
    checked: bool = False


def _remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


# --- config / cache loading -------------------------------------------------


def load_ignore() -> set[str]:
    try:
        with (DATA_DIR / "ignore.toml").open("rb") as f:
            data = tomllib.load(f)
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return set()
    return set(data.get("ignore", []))


def save_ignore(selected: set[str], nodes: list[Node], old: set[str]) -> None:
    """Rewrite ignore.toml. Entries in `old` that aren't scannable on this machine
    are preserved untouched (we can't show them, so we don't drop them)."""
    scannable = {n.label for n in nodes}
    final = sorted(selected | (old - scannable))
    lines = [
        "# Folder names hidden from the selection list.",
        "# Matched by name (not path) against BOTH top-level ~ dotfolders and ~/.config subdirs.",
        '# Edit via the TUI "Edit block list" menu, or by hand — read at runtime, no rebuild needed.',
        "ignore = [",
        *[f"  {json.dumps(name)}," for name in final],
        "]",
        "",
    ]
    (DATA_DIR / "ignore.toml").write_text("\n".join(lines))


def load_includes() -> dict[str, list[str]]:
    try:
        with (DATA_DIR / "includes.toml").open("rb") as f:
            data = tomllib.load(f)
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return {}
    return data.get("includes", {})


def load_overrides() -> dict[str, list[str]]:
    try:
        with (DATA_DIR / "hosts.toml").open("rb") as f:
            data = tomllib.load(f)
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return {}
    return data.get("overrides", {})


def cache_path() -> Path:
    return CACHE_DIR / f"{getuser()}.json"


def load_cache() -> dict:
    try:
        with cache_path().open() as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}
    if data.get("version") != CACHE_VERSION:
        return {}
    return data


def preselect(nodes: list[Node], mode: str) -> None:
    saved = set(load_cache().get(mode, {}).get("selected", []))
    for n in nodes:
        if n.key in saved:
            n.checked = True


def preselect_blocked(nodes: list[Node], ignore: set[str]) -> None:
    for n in nodes:
        if n.label in ignore:
            n.checked = True


def save_cache(mode: str, keys: list[str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = load_cache()
    cache["version"] = CACHE_VERSION
    cache[mode] = {"selected": keys}
    with cache_path().open("w") as f:
        json.dump(cache, f, indent=2)


# --- tree discovery ---------------------------------------------------------


def _build_tree(root: Path, ignore: set[str]) -> list[Node]:
    nodes: list[Node] = []
    if not root.is_dir():
        return nodes
    top_names = sorted(
        p.name
        for p in root.iterdir()
        if p.is_dir() and p.name.startswith(".") and p.name not in ignore
    )
    for name in top_names:
        src = root / name
        if name == ".config":
            nodes.append(Node(".config", ".config", 0, src, is_parent=True))
            children = sorted(
                c.name
                for c in src.iterdir()
                if c.is_dir() and not c.name.startswith(".") and c.name not in ignore
            )
            for cname in children:
                nodes.append(
                    Node(f".config/{cname}", cname, 1, src / cname, parent_key=".config")
                )
        else:
            nodes.append(Node(name, name, 0, src))
    return nodes


def build_sync_tree(ignore: set[str]) -> list[Node]:
    return _build_tree(HOME, ignore)


def build_apply_tree(ignore: set[str]) -> list[Node]:
    return _build_tree(PROFILES_DIR, ignore)


def prune_ignored(ignore: set[str]) -> list[str]:
    """Delete folders under profiles/ whose name is in `ignore`, mirroring the
    name matching in _build_tree (top-level dotfolders + .config subdirs). Catches
    a folder ignored *after* it was once synced: its orphaned copy would otherwise
    be re-committed forever by cmd_sync's `git add -f`. Returns pruned keys."""
    pruned: list[str] = []
    if not PROFILES_DIR.is_dir():
        return pruned
    for p in PROFILES_DIR.iterdir():
        if p.is_dir() and p.name.startswith(".") and p.name in ignore:
            _remove(p)
            pruned.append(p.name)
    config = PROFILES_DIR / ".config"
    if config.is_dir():
        for c in config.iterdir():
            if c.is_dir() and c.name in ignore:
                _remove(c)
                pruned.append(f".config/{c.name}")
    return pruned


def _config_whole(nodes: list[Node]) -> bool:
    return any(n.is_parent and n.key == ".config" and n.checked for n in nodes)


def effective_selection(nodes: list[Node]) -> list[str]:
    whole = _config_whole(nodes)
    keys: list[str] = []
    for n in nodes:
        if n.parent_key == ".config":
            if not whole and n.checked:
                keys.append(n.key)
        elif n.checked:
            keys.append(n.key)
    return keys


def blocked_names(nodes: list[Node]) -> set[str]:
    whole = _config_whole(nodes)
    names: set[str] = set()
    for n in nodes:
        if n.is_parent and n.key == ".config":
            if n.checked:
                names.add(".config")
        elif n.parent_key == ".config":
            if not whole and n.checked:
                names.add(n.label)
        elif n.checked:
            names.add(n.label)
    return names


def _format_sync(date_iso: str, subject: str) -> str:
    when = date_iso[:16].replace("T", " ")  # 2026-06-07 19:32
    m = re.search(r"Sync from (\S+) .* by (\S+)", subject)
    if m:
        return f"last sync {when} from {m.group(1)} by {m.group(2)}"
    return f"last commit {when}"


def last_sync_info(keys: list[str]) -> dict[str, str]:
    """Map each profiles/ key to a human-readable 'last synced' line, using a
    single git traversal instead of one subprocess per key."""
    rel = PROFILES_DIR.relative_to(REPO_ROOT).as_posix()
    out = subprocess.run(
        ["git", "log", "--format=%x00%cI%x1f%s", "--name-only", "--", rel],
        cwd=REPO_ROOT, capture_output=True, text=True,
    ).stdout
    info: dict[str, str] = {}
    pending = set(keys)
    cur: tuple[str, str] | None = None
    for line in out.splitlines():  # newest commit first
        if line.startswith("\x00"):
            date_iso, _, subject = line[1:].partition("\x1f")
            cur = (date_iso, subject)
        elif line and cur is not None and pending:
            matched = [
                k for k in pending
                if line == f"{rel}/{k}" or line.startswith(f"{rel}/{k}/")
            ]
            for k in matched:
                info[k] = _format_sync(*cur)
                pending.discard(k)
    for k in pending:
        info[k] = "untracked / never synced"
    return info


# --- interactive selection (Rich Live + raw key input) ----------------------


_ESC_TIMEOUT = 0.05  # seconds to wait for the rest of an escape sequence


def _read_key(fd: int) -> str:
    ch = os.read(fd, 1)
    if ch == b"\x1b":
        # Bare ESC (nothing follows) cancels; otherwise drain the whole sequence.
        if not select.select([fd], [], [], _ESC_TIMEOUT)[0]:
            return "quit"
        intro = os.read(fd, 1)
        if intro not in (b"[", b"O"):
            return ""  # unrecognized escape; ignore
        final = b""
        while select.select([fd], [], [], _ESC_TIMEOUT)[0]:
            b = os.read(fd, 1)
            final += b
            if b and 0x40 <= b[0] <= 0x7E:  # CSI/SS3 final byte
                break
        if intro == b"[":
            if final == b"A":
                return "up"
            if final == b"B":
                return "down"
        return ""  # recognized but unhandled sequence; ignore
    if ch in (b"\r", b"\n"):
        return "enter"
    if ch == b" ":
        return "space"
    if ch in (b"q", b"Q"):
        return "quit"
    if ch in (b"k",):
        return "up"
    if ch in (b"j",):
        return "down"
    if ch in (b"a", b"A"):
        return "all"
    if ch.isdigit():
        return f"digit:{ch.decode()}"
    return ""


def _key_loop(render, on_key) -> bool:
    """Run a raw-mode Rich Live loop. render() -> renderable; on_key(key) ->
    "confirm"/"cancel"/None. Returns True on confirm, False on cancel."""
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return False
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        with Live(render(), console=console, auto_refresh=False, transient=True) as live:
            while True:
                key = _read_key(fd)
                if not key:
                    continue
                action = on_key(key)
                if action == "confirm":
                    return True
                if action == "cancel":
                    return False
                live.update(render())
                live.refresh()
    except KeyboardInterrupt:
        return False
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def _box_header(title: str, description: str | None = None) -> Text:
    """A 45-wide boxed title; optional italic description below, then a blank line."""
    text = Text()
    text.append("-" * 45 + "\n", style="dim")
    text.append("---- ", style="dim")
    text.append(f"{title:^35}", style="bold")
    text.append(" ----\n", style="dim")
    text.append("-" * 45 + "\n", style="dim")
    if description:
        text.append(description + "\n", style="italic")
    text.append("\n")
    return text


def _scroll_top(total: int, cursor: int, top: int, height: int) -> int:
    """Sticky scroll: return the new top-of-window index keeping cursor visible."""
    if total <= height:
        return 0
    if cursor < top:
        top = cursor
    elif cursor >= top + height:
        top = cursor - height + 1
    return max(0, min(top, total - height))


def _checklist_height(description: str | None) -> int:
    """Rows available for list items: terminal height minus header, footer, and
    the two lines reserved for the scroll indicators."""
    header = 5 if description else 4
    return max(1, console.height - header - 2 - 2)


def _render_checklist(
    nodes: list[Node],
    cursor: int,
    top: int,
    height: int,
    title: str,
    info: dict[str, str] | None = None,
    description: str | None = None,
) -> Text:
    whole = _config_whole(nodes)
    text = _box_header(title, description)
    end = min(top + height, len(nodes))
    if top > 0:
        text.append(f"   ↑ {top} more\n", style="dim")
    for i in range(top, end):
        n = nodes[i]
        implied = n.parent_key == ".config" and whole
        glyph = "[-]" if implied else ("[x]" if n.checked else "[ ]")
        label = n.label
        if n.is_parent and n.key == ".config":
            label = f"{label}  (whole folder)"
        pointer = ">" if i == cursor else " "
        style = "reverse" if i == cursor else ("dim" if implied else "")
        text.append(f"{pointer} {'  ' * n.depth}{glyph} {label}", style=style)
        if info and n.key in info:
            text.append(f"  — {info[n.key]}", style="dim")
        text.append("\n")
    if end < len(nodes):
        text.append(f"   ↓ {len(nodes) - end} more\n", style="dim")
    count = len(effective_selection(nodes))
    text.append(
        f"\n{count} selected · ↑/↓ move · space toggle · a all · enter confirm · q cancel",
        style="dim",
    )
    return text


def _toggle(nodes: list[Node], idx: int) -> None:
    n = nodes[idx]
    if n.parent_key == ".config" and _config_whole(nodes):
        return  # children are implied while the parent is checked
    n.checked = not n.checked


def interactive_select(
    nodes: list[Node],
    title: str,
    info: dict[str, str] | None = None,
    description: str | None = None,
) -> list[Node] | None:
    if not nodes:
        return []
    state = {"cursor": 0, "top": 0}

    def on_key(key: str) -> str | None:
        if key == "up":
            state["cursor"] = (state["cursor"] - 1) % len(nodes)
        elif key == "down":
            state["cursor"] = (state["cursor"] + 1) % len(nodes)
        elif key == "space":
            _toggle(nodes, state["cursor"])
        elif key == "all":
            val = any(not n.checked for n in nodes)
            for n in nodes:
                n.checked = val
        elif key == "enter":
            return "confirm"
        elif key == "quit":
            return "cancel"
        return None

    def render() -> Text:
        height = _checklist_height(description)
        state["top"] = _scroll_top(len(nodes), state["cursor"], state["top"], height)
        return _render_checklist(
            nodes, state["cursor"], state["top"], height, title, info, description
        )

    confirmed = _key_loop(render, on_key)
    return nodes if confirmed else None


def menu_select(
    title: str, options: list[tuple[str, str]], description: str | None = None
) -> str | None:
    state = {"cursor": 0}

    def render() -> Text:
        text = _box_header(title, description)
        for i, (key, label) in enumerate(options):
            if key == "quit":
                text.append("\n")
            pointer = ">" if i == state["cursor"] else " "
            style = "reverse" if i == state["cursor"] else ""
            text.append(f"{pointer} {i + 1}. {label}\n", style=style)
        text.append(
            f"\n↑/↓ move · 1-{len(options)} jump · enter select · q quit", style="dim"
        )
        return text

    def on_key(key: str) -> str | None:
        if key == "up":
            state["cursor"] = (state["cursor"] - 1) % len(options)
        elif key == "down":
            state["cursor"] = (state["cursor"] + 1) % len(options)
        elif key.startswith("digit:"):
            idx = int(key[6:]) - 1
            if 0 <= idx < len(options):
                state["cursor"] = idx
                return "confirm"
        elif key == "enter":
            return "confirm"
        elif key == "quit":
            return "cancel"
        return None

    confirmed = _key_loop(render, on_key)
    return options[state["cursor"]][0] if confirmed else None


# --- copy helpers -----------------------------------------------------------


def copy_folder(
    src: Path, dst: Path, includes_list: list[str] | None, ignore: set[str] | None = None
) -> None:
    _remove(dst)
    if includes_list is None:
        dst.parent.mkdir(parents=True, exist_ok=True)
        ignore_fn = (
            (lambda _dir, names: [n for n in names if n in ignore]) if ignore else None
        )
        shutil.copytree(src, dst, symlinks=True, ignore=ignore_fn)
        return
    dst.mkdir(parents=True, exist_ok=True)
    for entry in includes_list:
        s = src / entry
        if not s.exists() and not s.is_symlink():
            continue
        t = dst / entry
        if s.is_dir() and not s.is_symlink():
            shutil.copytree(s, t, symlinks=True)
        else:
            t.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(s, t, follow_symlinks=False)


def relocate_overrides(key: str, hostname: str, overrides: dict[str, list[str]]) -> None:
    """Move declared per-machine paths out of the shared profiles/<key> copy
    into this host's tree under profiles/hosts/<hostname>/."""
    for rel in overrides.get(key, []):
        shared = PROFILES_DIR / key / rel
        if not shared.exists() and not shared.is_symlink():
            continue
        hdst = HOSTS_DIR / hostname / key / rel
        _remove(hdst)
        hdst.parent.mkdir(parents=True, exist_ok=True)
        shared.rename(hdst)
        console.print(f"  host [magenta]{key}/{rel} -> hosts/{hostname}[/magenta]")


def _copy_any(src: Path, dst: Path) -> None:
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, dst, symlinks=True)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst, follow_symlinks=False)


def apply_key(key: str, ts: str, overrides: dict[str, list[str]], hostname: str) -> None:
    src = PROFILES_DIR / key
    if not src.exists():
        console.print(f"[red]Missing {src}, skipping.[/red]")
        return
    dst = HOME / key
    bak: Path | None = None
    if dst.exists() or dst.is_symlink():
        bak = dst.with_name(f"{dst.name}.bak-{ts}")
        dst.rename(bak)
        console.print(f"  backup [dim]{key} -> {bak.name}[/dim]")
    dst.parent.mkdir(parents=True, exist_ok=True)
    _copy_any(src, dst)
    overlay = HOSTS_DIR / hostname / key
    if overlay.is_dir():
        shutil.copytree(overlay, dst, symlinks=True, dirs_exist_ok=True)
    for rel in overrides.get(key, []):
        t = dst / rel
        if t.exists() or t.is_symlink():
            continue
        b = bak / rel if bak else None
        if b is not None and (b.exists() or b.is_symlink()):
            _copy_any(b, t)
            console.print(f"  kept local [yellow]{key}/{rel}[/yellow] (no override for {hostname})")
        else:
            console.print(
                f"[yellow]  warning: {key}/{rel} has no override for {hostname} "
                f"and no local copy — configure it and sync[/yellow]"
            )
    console.print(f"  applied [cyan]{key}[/cyan]")


def _git(*args: str) -> bool:
    """Run a git command in the repo; on failure print a one-liner instead of
    raising (git's own stderr is already visible)."""
    if subprocess.run(["git", *args], cwd=REPO_ROOT).returncode != 0:
        console.print(f"[red]git {args[0]} failed — resolve and retry.[/red]")
        return False
    return True


# --- commands ---------------------------------------------------------------


def cmd_sync(_: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    ignore = load_ignore()
    includes = load_includes()
    overrides = load_overrides()
    nodes = build_sync_tree(ignore)
    if not nodes:
        console.print("[yellow]Nothing to sync.[/yellow]")
        return
    preselect(nodes, "sync")
    result = interactive_select(nodes, "Save dotfiles")
    if result is None:
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            console.print("[red]Sync requires an interactive terminal.[/red]")
        else:
            console.print("[yellow]Cancelled.[/yellow]")
        return
    keys = effective_selection(result)
    if not keys:
        console.print("[yellow]Nothing selected; aborting.[/yellow]")
        return
    save_cache("sync", keys)

    if not _git("pull", "--rebase"):
        return

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    for key in keys:
        src = HOME / key
        if not src.exists():
            console.print(f"[red]Missing {src}, skipping.[/red]")
            continue
        copy_folder(src, PROFILES_DIR / key, includes.get(key), ignore)
        relocate_overrides(key, hostname, overrides)
        console.print(f"  copied [cyan]{key}[/cyan]")

    for key in prune_ignored(ignore):
        console.print(f"  pruned ignored [yellow]{key}[/yellow]")

    rel = PROFILES_DIR.relative_to(REPO_ROOT)
    if not _git("add", "-f", "--", str(rel)):
        return
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT)
    if staged.returncode == 0:
        console.print("[yellow]No changes to commit.[/yellow]")
        return

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Sync from {hostname} at {now} by {getuser()}"
    if not _git("commit", "-m", msg) or not _git("push"):
        return
    console.print(f"[green]Synced:[/green] {msg}")


def cmd_block(_: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    ignore = load_ignore()
    nodes = build_sync_tree(set())
    if not nodes:
        console.print("[yellow]No folders to block.[/yellow]")
        return
    preselect_blocked(nodes, ignore)
    result = interactive_select(
        nodes, "Edit block list",
        description="Checked folders are hidden from the sync list.",
    )
    if result is None:
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            console.print("[red]Editing the block list requires an interactive terminal.[/red]")
        else:
            console.print("[yellow]Cancelled.[/yellow]")
        return
    selected = blocked_names(result)

    if not _git("pull", "--rebase"):
        return
    save_ignore(selected, nodes, ignore)

    rel = (DATA_DIR / "ignore.toml").relative_to(REPO_ROOT)
    if not _git("add", "--", str(rel)):
        return
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT)
    if staged.returncode == 0:
        console.print("[yellow]No changes to the block list.[/yellow]")
        return

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Update block list from {hostname} at {now} by {getuser()}"
    if not _git("commit", "-m", msg) or not _git("push"):
        return
    console.print("[green]Block list updated.[/green]")


def _all_backups() -> list[Path]:
    return sorted(CONFIG_DIR.glob("*.bak-*")) + sorted(HOME.glob("*.bak-*"))


def cmd_apply(args: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    ignore = load_ignore()
    overrides = load_overrides()
    nodes = build_apply_tree(ignore)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")

    if args.apply:
        available = {n.key for n in nodes}
        missing = [n for n in args.apply if n not in available]
        if missing:
            console.print(f"[red]Not found in profiles/: {', '.join(missing)}[/red]")
            return
        for key in args.apply:
            apply_key(key, ts, overrides, hostname)
        return

    backups = _all_backups()
    if not nodes and not backups:
        console.print("[red]No configs or backups found.[/red]")
        return

    if nodes:
        preselect(nodes, "apply")
        info = last_sync_info([n.key for n in nodes])
        result = interactive_select(nodes, "Apply dotfiles", info=info)
        if result is None:
            if not (sys.stdin.isatty() and sys.stdout.isatty()):
                console.print("[red]Apply requires an interactive terminal.[/red]")
            else:
                console.print("[yellow]Cancelled.[/yellow]")
            return
        keys = effective_selection(result)
        if not keys:
            console.print("[yellow]Nothing selected; aborting.[/yellow]")
            return
        save_cache("apply", keys)
        for key in keys:
            apply_key(key, ts, overrides, hostname)
        return

    if backups:
        console.print("[bold]Backups:[/bold]")
        for i, b in enumerate(backups, 1):
            console.print(f"  {i:>2}. {b.name}")
        choices = [str(i) for i in range(1, len(backups) + 1)]
        pick = Prompt.ask("Pick backup", choices=choices, default="1")
        path = backups[int(pick) - 1]
        orig = path.with_name(path.name.split(".bak-", 1)[0])
        if orig.exists() or orig.is_symlink():
            orig.rename(orig.with_name(f"{orig.name}.bak-{ts}"))
        if path.is_dir() and not path.is_symlink():
            shutil.copytree(path, orig, symlinks=True)
        else:
            shutil.copy2(path, orig, follow_symlinks=False)
        console.print(f"  restored [cyan]{orig.name}[/cyan]")
        return

    console.print("[yellow]Nothing selected.[/yellow]")


def cmd_clean_backups(_: argparse.Namespace) -> None:
    backups = _all_backups()
    if not backups:
        console.print("[green]No backups found.[/green]")
        return
    console.print(f"[bold]Found {len(backups)} backup(s):[/bold]")
    for b in backups:
        kind = "dir " if b.is_dir() and not b.is_symlink() else "file"
        console.print(f"  [{kind}] {b}")
    if not Confirm.ask("Delete all of these?", default=False):
        console.print("[yellow]Cancelled.[/yellow]")
        return
    for b in backups:
        _remove(b)
    console.print(f"[green]Deleted {len(backups)} backup(s).[/green]")


def cmd_clean_profile(_: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    ignore = load_ignore()
    nodes = build_apply_tree(ignore)
    if not nodes:
        console.print("[yellow]Profile is empty; nothing to clean.[/yellow]")
        return
    info = last_sync_info([n.key for n in nodes])
    result = interactive_select(nodes, "Clean dotfiles", info=info)
    if result is None:
        if not (sys.stdin.isatty() and sys.stdout.isatty()):
            console.print("[red]Clean profile requires an interactive terminal.[/red]")
        else:
            console.print("[yellow]Cancelled.[/yellow]")
        return
    keys = effective_selection(result)
    if not keys:
        console.print("[yellow]Nothing selected; aborting.[/yellow]")
        return

    console.print("[bold red]Will delete from profiles/:[/bold red]")
    for k in keys:
        console.print(f"  [red]{k}[/red]  [dim]({info.get(k, '')})[/dim]")
    if not Confirm.ask("Delete these from the profile?", default=False):
        console.print("[yellow]Cancelled.[/yellow]")
        return

    if not _git("pull", "--rebase"):
        return
    for key in keys:
        _remove(PROFILES_DIR / key)
        for h in HOSTS_DIR.glob(f"*/{key}"):
            _remove(h)
        console.print(f"  removed [cyan]{key}[/cyan]")

    rel = PROFILES_DIR.relative_to(REPO_ROOT)
    if not _git("add", "-f", "--", str(rel)):
        return
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT)
    if staged.returncode == 0:
        console.print("[yellow]No changes to commit.[/yellow]")
        return
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Clean profile from {hostname} at {now} by {getuser()}: {', '.join(keys)}"
    if not _git("commit", "-m", msg) or not _git("push"):
        return
    console.print(f"[green]Cleaned:[/green] {msg}")


def run_menu(args: argparse.Namespace) -> None:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("Usage: tui [-s | -a [NAME...] | -c | -P]")
        sys.exit(2)
    options = [
        ("sync", "Save dotfiles"),
        ("apply", "Apply dotfiles"),
        ("clean-profile", "Clean dotfiles"),
        ("clean", "Clean dotfile backups"),
        ("block", "Edit block list"),
        ("quit", "Quit"),
    ]
    while True:
        choice = menu_select("dotfiles TUI", options)
        if choice in (None, "quit"):
            return
        if choice == "sync":
            cmd_sync(args)
        elif choice == "apply":
            cmd_apply(args)
        elif choice == "clean-profile":
            cmd_clean_profile(args)
        elif choice == "clean":
            cmd_clean_backups(args)
        elif choice == "block":
            cmd_block(args)
        console.print()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tui", description="dotfiles TUI")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("-s", "--sync", action="store_true", help="copy live configs into profiles/ and push")
    group.add_argument("-a", "--apply", nargs="*", default=None, metavar="NAME", help="apply configs from profiles/ to ~ (optional home-relative names for non-interactive)")
    group.add_argument("-c", "--clean-backups", action="store_true", help="list and delete *.bak-* in ~ and ~/.config")
    group.add_argument("-P", "--clean-profile", action="store_true", help="delete folders from profiles/ and push")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    if args.sync:
        cmd_sync(args)
    elif args.apply is not None:
        cmd_apply(args)
    elif args.clean_backups:
        cmd_clean_backups(args)
    elif args.clean_profile:
        cmd_clean_profile(args)
    else:
        run_menu(args)


if __name__ == "__main__":
    main()
