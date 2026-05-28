import argparse
import shutil
import socket
import subprocess
import sys
from datetime import datetime
from getpass import getuser
from pathlib import Path

from rich.console import Console
from rich.prompt import Confirm, Prompt

DEFAULTS = ["waybar", "hypr", "kitty", "rofi", "claude"]
CONFIG_DIR = Path.home() / ".config"
CLAUDE_DIR = Path.home() / ".claude"
CLAUDE_INCLUDES = [
    "agents",
    "commands",
    "teams",
    "plugins",
    "CLAUDE.md",
    "settings.json",
    "statusline-command.sh",
]
REPO_ROOT = (
    Path(sys.executable).resolve().parent
    if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent.parent
)
PROFILES_DIR = REPO_ROOT / "profiles"

console = Console()


def _remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def select_configs(available: list[str], defaults: list[str]) -> list[str]:
    if not available:
        return []
    console.print("\n[bold]Available:[/bold]")
    for i, name in enumerate(available, 1):
        marker = "[green]*[/green]" if name in defaults else " "
        console.print(f"  {marker} {i:>2}. {name}")
    console.print(
        "[dim]Enter comma-separated numbers, 'defaults', 'all', or 'none'.[/dim]"
    )
    raw = Prompt.ask("Selection", default="defaults").strip().lower()
    if raw in {"", "defaults"}:
        return [n for n in available if n in defaults]
    if raw == "all":
        return list(available)
    if raw == "none":
        return []
    chosen: list[str] = []
    for part in raw.split(","):
        part = part.strip()
        if not part.isdigit():
            console.print(f"[red]Ignoring invalid entry: {part!r}[/red]")
            continue
        idx = int(part) - 1
        if 0 <= idx < len(available):
            chosen.append(available[idx])
        else:
            console.print(f"[red]Out of range: {part}[/red]")
    return list(dict.fromkeys(chosen))


def list_config_subdirs() -> list[str]:
    names = [p.name for p in CONFIG_DIR.iterdir() if p.is_dir() and not p.name.startswith(".")]
    if CLAUDE_DIR.is_dir():
        names.append("claude")
    head = [n for n in DEFAULTS if n in names]
    tail = sorted(n for n in names if n not in DEFAULTS)
    return head + tail


def sync_claude(dst: Path) -> None:
    _remove(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for entry in CLAUDE_INCLUDES:
        src = CLAUDE_DIR / entry
        if not src.exists():
            continue
        target = dst / entry
        if src.is_dir() and not src.is_symlink():
            shutil.copytree(src, target, symlinks=True)
        else:
            shutil.copy2(src, target, follow_symlinks=False)


def replace_tree(src: Path, dst: Path) -> None:
    _remove(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst, symlinks=True)


def cmd_sync(_: argparse.Namespace) -> None:
    hostname = socket.gethostname()
    available = list_config_subdirs()
    chosen = select_configs(available, DEFAULTS)
    if not chosen:
        console.print("[yellow]Nothing selected; aborting.[/yellow]")
        return

    subprocess.run(["git", "pull", "--rebase"], cwd=REPO_ROOT, check=True)

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    for name in chosen:
        if name == "claude":
            if not CLAUDE_DIR.exists():
                console.print(f"[red]Missing {CLAUDE_DIR}, skipping.[/red]")
                continue
            sync_claude(PROFILES_DIR / "claude")
            console.print("  copied [cyan]claude[/cyan]")
            continue
        src = CONFIG_DIR / name
        if not src.exists():
            console.print(f"[red]Missing {src}, skipping.[/red]")
            continue
        replace_tree(src, PROFILES_DIR / name)
        console.print(f"  copied [cyan]{name}[/cyan]")

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


def apply_one(src: Path, name: str, ts: str, base: Path = CONFIG_DIR) -> None:
    dst = base / name
    if dst.exists() or dst.is_symlink():
        bak = dst.with_name(f"{name}.bak-{ts}")
        dst.rename(bak)
        console.print(f"  backup [dim]{name} -> {bak.name}[/dim]")
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)
    console.print(f"  applied [cyan]{name}[/cyan]")


def apply_claude(src_dir: Path, ts: str) -> None:
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    for entry in sorted(src_dir.iterdir()):
        apply_one(entry, entry.name, ts, base=CLAUDE_DIR)


def cmd_apply(args: argparse.Namespace) -> None:
    available: list[str] = []
    if PROFILES_DIR.exists():
        available = sorted(p.name for p in PROFILES_DIR.iterdir() if p.is_dir())
    backups = sorted(CONFIG_DIR.glob("*.bak-*"))
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")

    if args.apply:
        missing = [n for n in args.apply if n not in available]
        if missing:
            console.print(f"[red]Not found in profiles/: {', '.join(missing)}[/red]")
            return
        for name in args.apply:
            if name == "claude":
                apply_claude(PROFILES_DIR / "claude", ts)
            else:
                apply_one(PROFILES_DIR / name, name, ts)
        return

    if not available and not backups:
        console.print("[red]No configs or backups found.[/red]")
        return

    if available:
        defaults = [n for n in available if n in DEFAULTS]
        chosen = select_configs(available, defaults)
        if chosen:
            for name in chosen:
                if name == "claude":
                    apply_claude(PROFILES_DIR / "claude", ts)
                else:
                    apply_one(PROFILES_DIR / name, name, ts)
            return

    if backups:
        console.print("[bold]Backups:[/bold]")
        for i, b in enumerate(backups, 1):
            console.print(f"  {i:>2}. {b.name}")
        choices = [str(i) for i in range(1, len(backups) + 1)]
        pick = Prompt.ask("Pick backup", choices=choices, default="1")
        path = backups[int(pick) - 1]
        apply_one(path, path.name.split(".bak-", 1)[0], ts)
        return

    console.print("[yellow]Nothing selected.[/yellow]")


def cmd_clean_backups(_: argparse.Namespace) -> None:
    backups = sorted(CONFIG_DIR.glob("*.bak-*"))
    if not backups:
        console.print("[green]No backups found in ~/.config.[/green]")
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


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tui", description="dotfiles TUI")
    parser.add_argument("-v", "--verbose", action="store_true", help="enable verbose output")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("-s", "--sync", action="store_true", help="copy live configs into profiles/ and push")
    group.add_argument("-a", "--apply", nargs="*", default=None, metavar="NAME", help="apply configs from profiles/ to ~/.config (optional names for non-interactive)")
    group.add_argument("-c", "--clean-backups", action="store_true", help="list and delete *.bak-* in ~/.config")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    if args.sync:
        cmd_sync(args)
    elif args.apply is not None:
        cmd_apply(args)
    elif args.clean_backups:
        cmd_clean_backups(args)


if __name__ == "__main__":
    main()
