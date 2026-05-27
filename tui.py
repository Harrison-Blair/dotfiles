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

    target_dir = PROFILES_DIR / hostname
    target_dir.mkdir(parents=True, exist_ok=True)
    for name in chosen:
        src = CONFIG_DIR / name
        if not src.exists():
            console.print(f"[red]Missing {src}, skipping.[/red]")
            continue
        replace_tree(src, target_dir / name)
        console.print(f"  copied [cyan]{name}[/cyan]")

    rel = target_dir.relative_to(REPO_ROOT)
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


def cmd_apply(_: argparse.Namespace) -> None:
    if not PROFILES_DIR.exists():
        console.print(f"[red]No profiles dir at {PROFILES_DIR}[/red]")
        return
    profiles = sorted(p.name for p in PROFILES_DIR.iterdir() if p.is_dir())
    if not profiles:
        console.print("[red]No profiles found.[/red]")
        return

    console.print("[bold]Profiles:[/bold]")
    for i, name in enumerate(profiles, 1):
        console.print(f"  {i:>2}. {name}")
    pick = Prompt.ask(
        "Pick a profile",
        choices=[str(i) for i in range(1, len(profiles) + 1)],
        default="1",
    )
    profile_dir = PROFILES_DIR / profiles[int(pick) - 1]

    available = sorted(p.name for p in profile_dir.iterdir() if p.is_dir())
    profile_defaults = [n for n in available if n in DEFAULTS]
    chosen = select_configs(available, profile_defaults)
    if not chosen:
        console.print("[yellow]Nothing selected.[/yellow]")
        return

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    for name in chosen:
        src = profile_dir / name
        dst = CONFIG_DIR / name
        if dst.exists() or dst.is_symlink():
            bak = dst.with_name(f"{name}.bak-{ts}")
            dst.rename(bak)
            console.print(f"  backup [dim]{name} -> {bak.name}[/dim]")
        shutil.copytree(src, dst, symlinks=True)
        console.print(f"  applied [cyan]{name}[/cyan]")


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
    sub.add_parser("sync", help="copy live configs into profiles/<hostname>/ and push")
    sub.add_parser("apply", help="apply a profile from profiles/ to ~/.config")
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
