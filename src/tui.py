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
DATA_DIR = REPO_ROOT / "config"
CACHE_DIR = DATA_DIR / "cache"

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


def load_includes() -> dict[str, list[str]]:
    try:
        with (DATA_DIR / "includes.toml").open("rb") as f:
            data = tomllib.load(f)
    except (FileNotFoundError, tomllib.TOMLDecodeError):
        return {}
    return data.get("includes", {})


def cache_path() -> Path:
    return CACHE_DIR / f"{getuser()}.json"


def load_cache() -> dict:
    try:
        with cache_path().open() as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def preselect(nodes: list[Node], mode: str) -> None:
    saved = set(load_cache().get(mode, {}).get("selected", []))
    for n in nodes:
        if n.key in saved:
            n.checked = True


def save_cache(mode: str, keys: list[str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache = load_cache()
    cache["version"] = 1
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


def last_sync_info(key: str) -> str:
    """Human-readable 'last synced' line for a profiles/ folder, from git history."""
    rel = (PROFILES_DIR / key).relative_to(REPO_ROOT)
    out = subprocess.run(
        ["git", "log", "-1", "--format=%cI%x00%s", "--", str(rel)],
        cwd=REPO_ROOT, capture_output=True, text=True,
    ).stdout.strip()
    if not out:
        return "untracked / never synced"
    date_iso, _, subject = out.partition("\x00")
    when = date_iso[:16].replace("T", " ")  # 2026-06-07 19:32
    m = re.search(r"Sync from (\S+) .* by (\S+)", subject)
    if m:
        host, user = m.group(1), m.group(2)
        return f"last sync {when} from {host} by {user}"
    return f"last commit {when}"


# --- interactive selection (Rich Live + raw key input) ----------------------


def _read_key(fd: int) -> str:
    ch = os.read(fd, 1)
    if ch == b"\x1b":
        rest = b""
        if select.select([fd], [], [], 0.01)[0]:
            rest = os.read(fd, 2)
        if rest == b"[A":
            return "up"
        if rest == b"[B":
            return "down"
        if rest in (b"[C", b"[D"):
            return ""
        return "quit"  # bare ESC cancels
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


def _render_checklist(
    nodes: list[Node], cursor: int, title: str, info: dict[str, str] | None = None
) -> Text:
    whole = _config_whole(nodes)
    text = Text()
    text.append(title + "\n", style="bold")
    text.append("-" * 45 + "\n\n", style="dim")
    for i, n in enumerate(nodes):
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
    text.append(
        "\n↑/↓ move · space toggle · enter confirm · q cancel",
        style="dim",
    )
    return text


def _toggle(nodes: list[Node], idx: int) -> None:
    n = nodes[idx]
    if n.parent_key == ".config" and _config_whole(nodes):
        return  # children are implied while the parent is checked
    n.checked = not n.checked


def interactive_select(
    nodes: list[Node], title: str, info: dict[str, str] | None = None
) -> list[Node] | None:
    if not nodes:
        return []
    state = {"cursor": 0}

    def on_key(key: str) -> str | None:
        if key == "up":
            state["cursor"] = (state["cursor"] - 1) % len(nodes)
        elif key == "down":
            state["cursor"] = (state["cursor"] + 1) % len(nodes)
        elif key == "space":
            _toggle(nodes, state["cursor"])
        elif key == "enter":
            return "confirm"
        elif key == "quit":
            return "cancel"
        return None

    confirmed = _key_loop(
        lambda: _render_checklist(nodes, state["cursor"], title, info), on_key
    )
    return nodes if confirmed else None


def menu_select(title: str, options: list[tuple[str, str]]) -> str | None:
    state = {"cursor": 0}

    def render() -> Text:
        text = Text()
        text.append(title + "\n", style="bold")
        text.append("-" * 45 + "\n\n", style="dim")
        for i, (_, label) in enumerate(options):
            pointer = ">" if i == state["cursor"] else " "
            style = "reverse" if i == state["cursor"] else ""
            text.append(f"{pointer} {label}\n", style=style)
        text.append(
            "\n↑/↓ move · enter select · q quit", style="dim"
        )
        return text

    def on_key(key: str) -> str | None:
        if key == "up":
            state["cursor"] = (state["cursor"] - 1) % len(options)
        elif key == "down":
            state["cursor"] = (state["cursor"] + 1) % len(options)
        elif key == "enter":
            return "confirm"
        elif key == "quit":
            return "cancel"
        return None

    confirmed = _key_loop(render, on_key)
    return options[state["cursor"]][0] if confirmed else None


# --- copy helpers -----------------------------------------------------------


def copy_folder(src: Path, dst: Path, includes_list: list[str] | None) -> None:
    _remove(dst)
    if includes_list is None:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst, symlinks=True)
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


def apply_key(key: str, ts: str) -> None:
    src = PROFILES_DIR / key
    if not src.exists():
        console.print(f"[red]Missing {src}, skipping.[/red]")
        return
    dst = HOME / key
    if dst.exists() or dst.is_symlink():
        bak = dst.with_name(f"{dst.name}.bak-{ts}")
        dst.rename(bak)
        console.print(f"  backup [dim]{key} -> {bak.name}[/dim]")
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)
    console.print(f"  applied [cyan]{key}[/cyan]")


# --- commands ---------------------------------------------------------------


def cmd_sync(_: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    ignore = load_ignore()
    includes = load_includes()
    nodes = build_sync_tree(ignore)
    if not nodes:
        console.print("[yellow]Nothing to sync.[/yellow]")
        return
    preselect(nodes, "sync")
    result = interactive_select(nodes, "Sync → profiles/")
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

    subprocess.run(["git", "pull", "--rebase"], cwd=REPO_ROOT, check=True)

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    for key in keys:
        src = HOME / key
        if not src.exists():
            console.print(f"[red]Missing {src}, skipping.[/red]")
            continue
        copy_folder(src, PROFILES_DIR / key, includes.get(key))
        console.print(f"  copied [cyan]{key}[/cyan]")

    rel = PROFILES_DIR.relative_to(REPO_ROOT)
    subprocess.run(["git", "add", "-f", "--", str(rel)], cwd=REPO_ROOT, check=True)
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT)
    if staged.returncode == 0:
        console.print("[yellow]No changes to commit.[/yellow]")
        return

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Sync from {hostname} at {now} by {getuser()}"
    subprocess.run(["git", "commit", "-m", msg], cwd=REPO_ROOT, check=True)
    subprocess.run(["git", "push"], cwd=REPO_ROOT, check=True)
    console.print(f"[green]Synced:[/green] {msg}")


def _all_backups() -> list[Path]:
    return sorted(CONFIG_DIR.glob("*.bak-*")) + sorted(HOME.glob("*.bak-*"))


def cmd_apply(args: argparse.Namespace) -> None:
    ignore = load_ignore()
    nodes = build_apply_tree(ignore)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")

    if args.apply:
        available = {n.key for n in nodes} | {".config"}
        missing = [n for n in args.apply if n not in available]
        if missing:
            console.print(f"[red]Not found in profiles/: {', '.join(missing)}[/red]")
            return
        for key in args.apply:
            apply_key(key, ts)
        return

    backups = _all_backups()
    if not nodes and not backups:
        console.print("[red]No configs or backups found.[/red]")
        return

    if nodes:
        preselect(nodes, "apply")
        result = interactive_select(nodes, "Apply ← profiles/")
        if result is None and not (sys.stdin.isatty() and sys.stdout.isatty()):
            console.print("[red]Apply requires an interactive terminal.[/red]")
            return
        if result is not None:
            keys = effective_selection(result)
            if keys:
                save_cache("apply", keys)
                for key in keys:
                    apply_key(key, ts)
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
    info = {n.key: last_sync_info(n.key) for n in nodes}
    result = interactive_select(nodes, "Clean profile (delete from profiles/)", info=info)
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

    subprocess.run(["git", "pull", "--rebase"], cwd=REPO_ROOT, check=True)
    for key in keys:
        _remove(PROFILES_DIR / key)
        console.print(f"  removed [cyan]{key}[/cyan]")

    rel = PROFILES_DIR.relative_to(REPO_ROOT)
    subprocess.run(["git", "add", "-f", "--", str(rel)], cwd=REPO_ROOT, check=True)
    staged = subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT)
    if staged.returncode == 0:
        console.print("[yellow]No changes to commit.[/yellow]")
        return
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Clean profile from {hostname} at {now} by {getuser()}: {', '.join(keys)}"
    subprocess.run(["git", "commit", "-m", msg], cwd=REPO_ROOT, check=True)
    subprocess.run(["git", "push"], cwd=REPO_ROOT, check=True)
    console.print(f"[green]Cleaned:[/green] {msg}")


def run_menu(args: argparse.Namespace) -> None:
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        console.print("Usage: tui [-s | -a [NAME...] | -c | -P]")
        sys.exit(2)
    options = [
        ("sync", "Sync to cloud"),
        ("apply", "Apply from profiles"),
        ("clean-profile", "Clean profile"),
        ("clean", "Clean backups"),
        ("quit", "Quit"),
    ]
    choice = menu_select("dotfiles TUI", options)
    if choice == "sync":
        cmd_sync(args)
    elif choice == "apply":
        cmd_apply(args)
    elif choice == "clean-profile":
        cmd_clean_profile(args)
    elif choice == "clean":
        cmd_clean_backups(args)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tui", description="dotfiles TUI")
    parser.add_argument("-v", "--verbose", action="store_true", help="enable verbose output")
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
