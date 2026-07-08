//! dotfiles TUI — sync config folders between `~` and versioned `profiles/`.
//! Rust port of the original `src/tui.py`. See `README.md` / `CLAUDE.md`.

mod commands;
mod config;
mod copy;
mod git;
mod model;
mod tree;
mod tui;
mod ui;

use clap::Parser;

use model::Paths;

/// dotfiles TUI. With no flag, launches the interactive menu.
#[derive(Parser, Debug)]
#[command(name = "tui", about = "dotfiles TUI", disable_help_flag = false)]
struct Cli {
    #[command(flatten)]
    mode: ModeArgs,
}

/// The four mutually-exclusive command flags (argparse mutually-exclusive group).
#[derive(clap::Args, Debug)]
#[group(required = false, multiple = false)]
struct ModeArgs {
    /// copy live configs into profiles/ and push
    #[arg(short = 's', long = "sync")]
    sync: bool,

    /// apply configs from profiles/ to ~ (optional home-relative names for non-interactive)
    #[arg(short = 'a', long = "apply", num_args = 0.., value_name = "NAME")]
    apply: Option<Vec<String>>,

    /// list and delete *.bak-* in ~ and ~/.config
    #[arg(short = 'c', long = "clean-backups")]
    clean_backups: bool,

    /// delete folders from profiles/ and push
    #[arg(short = 'P', long = "clean-profile")]
    clean_profile: bool,
}

fn main() {
    let cli = Cli::parse();
    let paths = Paths::resolve();
    let m = cli.mode;

    if m.sync {
        commands::cmd_sync(&paths);
    } else if let Some(names) = m.apply.as_deref() {
        // Flag present: empty slice → interactive, non-empty → non-interactive.
        let names = if names.is_empty() { None } else { Some(names) };
        commands::cmd_apply(&paths, names);
    } else if m.clean_backups {
        commands::cmd_clean_backups(&paths);
    } else if m.clean_profile {
        commands::cmd_clean_profile(&paths);
    } else {
        commands::run_menu(&paths);
    }
}
