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

DEFAULTS = ["waybar", "hypr", "kitty", "rofi"]
CONFIG_DIR = Path.home() / ".config"
REPO_ROOT = (
    Path(sys.executable).resolve().parent
    if getattr(sys, "frozen", False)
    else Path(__file__).resolve().parent
)
PROFILES_DIR = REPO_ROOT / "profiles"

console = Console()


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
    seen: set[str] = set()
    return [c for c in chosen if not (c in seen or seen.add(c))]


def list_config_subdirs() -> list[str]:
    names = [p.name for p in CONFIG_DIR.iterdir() if p.is_dir() and not p.name.startswith(".")]
    head = [n for n in DEFAULTS if n in names]
    tail = sorted(n for n in names if n not in DEFAULTS)
    return head + tail


def replace_tree(src: Path, dst: Path) -> None:
    if dst.exists() or dst.is_symlink():
        if dst.is_dir() and not dst.is_symlink():
            shutil.rmtree(dst)
        else:
            dst.unlink()
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
        src = CONFIG_DIR / name
        if not src.exists():
            console.print(f"[red]Missing {src}, skipping.[/red]")
            continue
        replace_tree(src, PROFILES_DIR / name)
        console.print(f"  copied [cyan]{name}[/cyan]")

    rel = PROFILES_DIR.relative_to(REPO_ROOT)
    subprocess.run(["git", "add", "-f", "--", str(rel)], cwd=REPO_ROOT, check=True)
    staged = subprocess.run(
        ["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT
    )
    if staged.returncode == 0:
        console.print("[yellow]No changes to commit.[/yellow]")
        return

    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    msg = f"Sync from {hostname} at {now} by {getuser()}"
    subprocess.run(["git", "commit", "-m", msg], cwd=REPO_ROOT, check=True)
    subprocess.run(["git", "push"], cwd=REPO_ROOT, check=True)
    console.print(f"[green]Synced:[/green] {msg}")


def apply_one(src: Path, name: str, ts: str) -> None:
    dst = CONFIG_DIR / name
    if dst.exists() or dst.is_symlink():
        bak = dst.with_name(f"{name}.bak-{ts}")
        dst.rename(bak)
        console.print(f"  backup [dim]{name} -> {bak.name}[/dim]")
    if src.is_dir() and not src.is_symlink():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)
    console.print(f"  applied [cyan]{name}[/cyan]")


def cmd_apply(args: argparse.Namespace) -> None:
    available = (
        sorted(p.name for p in PROFILES_DIR.iterdir() if p.is_dir())
        if PROFILES_DIR.exists()
        else []
    )
    backups = sorted(CONFIG_DIR.glob("*.bak-*"))

    if args.names:
        missing = [n for n in args.names if n not in available]
        if missing:
            console.print(f"[red]Not found in profiles/: {', '.join(missing)}[/red]")
            return
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        for name in args.names:
            apply_one(PROFILES_DIR / name, name, ts)
        return

    if not available and not backups:
        console.print("[red]No configs or backups found.[/red]")
        return

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")

    if available:
        defaults = [n for n in available if n in DEFAULTS]
        chosen = select_configs(available, defaults)
        if chosen:
            for name in chosen:
                apply_one(PROFILES_DIR / name, name, ts)
            return

    if backups:
        console.print("[bold]Backups:[/bold]")
        for i, b in enumerate(backups, 1):
            console.print(f"  {i:>2}. {b.name}")
        pick = Prompt.ask(
            "Pick backup",
            choices=[str(i) for i in range(1, len(backups) + 1)],
            default="1",
        )
        path = backups[int(pick) - 1]
        original = path.name.split(".bak-", 1)[0]
        apply_one(path, original, ts)
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
        if b.is_dir() and not b.is_symlink():
            shutil.rmtree(b)
        else:
            b.unlink()
    console.print(f"[green]Deleted {len(backups)} backup(s).[/green]")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="tui", description="dotfiles TUI")
    parser.add_argument("-v", "--verbose", action="store_true", help="enable verbose output")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("sync", help="copy live configs into profiles/ and push")
    apply_parser = sub.add_parser("apply", help="apply configs from profiles/ to ~/.config")
    apply_parser.add_argument(
        "names",
        nargs="*",
        help="config names to apply non-interactively (e.g. waybar hypr)",
    )
    sub.add_parser("clean-backups", help="list and delete *.bak-* in ~/.config")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> None:
    args = parse_args(argv)
    handlers = {
        "sync": cmd_sync,
        "apply": cmd_apply,
        "clean-backups": cmd_clean_backups,
    }
    handlers[args.command](args)


if __name__ == "__main__":
    main()
