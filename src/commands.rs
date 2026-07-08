//! The five commands (sync / apply / block / clean-backups / clean-profile) and
//! the interactive menu loop. Mirrors the Python `cmd_*` / `run_menu`.

use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};

use crate::model::{hostname, username, Paths};
use crate::{config, copy, git, tree, tui, ui};

// --- small helpers ----------------------------------------------------------

/// stdin *and* stdout are TTYs (mirrors `sys.stdin.isatty() and sys.stdout.isatty()`).
fn is_interactive() -> bool {
    std::io::stdin().is_terminal() && std::io::stdout().is_terminal()
}

/// `%Y-%m-%d %H:%M:%S` — commit-message timestamp.
fn now_stamp() -> String {
    chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string()
}

/// `%Y%m%d-%H%M%S` — backup-suffix timestamp.
fn backup_ts() -> String {
    chrono::Local::now().format("%Y%m%d-%H%M%S").to_string()
}

/// Repo-relative, forward-slash path string (e.g. "profiles", "config/ignore.toml").
fn rel_to_repo(paths: &Paths, p: &Path) -> String {
    p.strip_prefix(&paths.repo_root)
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/")
}

/// True when nothing is staged (`git diff --cached --quiet` exits 0).
fn nothing_staged(paths: &Paths) -> bool {
    std::process::Command::new("git")
        .args(["diff", "--cached", "--quiet"])
        .current_dir(&paths.repo_root)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Print the "Cancelled." / "requires an interactive terminal" message that every
/// command shares when `interactive_select` returns None.
fn report_cancelled(what: &str) {
    if !is_interactive() {
        println!("{}", ui::red(&format!("{what} requires an interactive terminal.")));
    } else {
        println!("{}", ui::yellow("Cancelled."));
    }
}

/// A y/n confirmation, default No (mirrors `rich.Confirm.ask(default=False)`).
fn confirm(question: &str) -> bool {
    loop {
        print!("{question} [y/n] (n): ");
        std::io::stdout().flush().ok();
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line).unwrap_or(0) == 0 {
            return false; // EOF
        }
        match line.trim().to_lowercase().as_str() {
            "y" | "yes" => return true,
            "n" | "no" | "" => return false,
            _ => continue,
        }
    }
}

/// Sorted `*.bak-*` entries in `~/.config` then `~` (mirrors `_all_backups`).
fn all_backups(paths: &Paths) -> Vec<PathBuf> {
    fn glob_bak(dir: &Path) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = match std::fs::read_dir(dir) {
            Ok(entries) => entries
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().contains(".bak-"))
                .map(|e| e.path())
                .collect(),
            Err(_) => Vec::new(),
        };
        out.sort();
        out
    }
    let mut backups = glob_bak(&paths.config_dir);
    backups.extend(glob_bak(&paths.home));
    backups
}

// --- commands ---------------------------------------------------------------

/// `-s/--sync`: pick folders, copy `~/<key>` → `profiles/<key>` (includes
/// whitelist + host relocation + prune ignored), then pull-rebase / commit / push.
pub fn cmd_sync(paths: &Paths) {
    let host = hostname();
    let ignore = config::load_ignore(paths);
    let includes = config::load_includes(paths);
    let overrides = config::load_overrides(paths);
    let mut nodes = tree::build_sync_tree(paths, &ignore);
    if nodes.is_empty() {
        println!("{}", ui::yellow("Nothing to sync."));
        return;
    }
    tree::preselect(paths, &mut nodes, "sync");
    let Some(result) = tui::interactive_select(nodes, "Save dotfiles", None, None) else {
        report_cancelled("Sync");
        return;
    };
    let keys = tree::effective_selection(&result);
    if keys.is_empty() {
        println!("{}", ui::yellow("Nothing selected; aborting."));
        return;
    }
    let _ = config::save_cache(paths, "sync", &keys);

    if !git::git(paths, &["pull", "--rebase"]) {
        return;
    }

    let _ = std::fs::create_dir_all(&paths.profiles_dir);
    for key in &keys {
        let src = paths.home.join(key);
        if !src.exists() {
            println!("{}", ui::red(&format!("Missing {}, skipping.", src.display())));
            continue;
        }
        let dst = paths.profiles_dir.join(key);
        let inc = includes.get(key).map(Vec::as_slice);
        if copy::copy_folder(&src, &dst, inc, Some(&ignore)).is_err() {
            continue;
        }
        copy::relocate_overrides(paths, key, &host, &overrides);
        println!("  copied {}", ui::cyan(key));
    }

    for key in tree::prune_ignored(paths, &ignore) {
        println!("  pruned ignored {}", ui::yellow(&key));
    }

    let rel = rel_to_repo(paths, &paths.profiles_dir);
    if !git::git(paths, &["add", "-f", "--", &rel]) {
        return;
    }
    if nothing_staged(paths) {
        println!("{}", ui::yellow("No changes to commit."));
        return;
    }

    let msg = format!("Sync from {host} at {} by {}", now_stamp(), username());
    if !git::git(paths, &["commit", "-m", &msg]) || !git::git(paths, &["push"]) {
        return;
    }
    println!("{} {msg}", ui::green("Synced:"));
}

/// The "Edit block list" action: edit `ignore.toml`, then pull-rebase / commit / push.
pub fn cmd_block(paths: &Paths) {
    let host = hostname();
    let ignore = config::load_ignore(paths);
    // Empty ignore set: show every folder so any can be (un)blocked.
    let mut nodes = tree::build_sync_tree(paths, &Default::default());
    if nodes.is_empty() {
        println!("{}", ui::yellow("No folders to block."));
        return;
    }
    tree::preselect_blocked(&mut nodes, &ignore);
    let Some(result) = tui::interactive_select(
        nodes,
        "Edit block list",
        None,
        Some("Checked folders are hidden from the sync list."),
    ) else {
        report_cancelled("Editing the block list");
        return;
    };
    let selected = tree::blocked_names(&result);

    if !git::git(paths, &["pull", "--rebase"]) {
        return;
    }
    let _ = config::save_ignore(paths, &selected, &result, &ignore);

    let rel = rel_to_repo(paths, &paths.data_file("ignore.toml"));
    if !git::git(paths, &["add", "--", &rel]) {
        return;
    }
    if nothing_staged(paths) {
        println!("{}", ui::yellow("No changes to the block list."));
        return;
    }

    let msg = format!("Update block list from {host} at {} by {}", now_stamp(), username());
    if !git::git(paths, &["commit", "-m", &msg]) || !git::git(paths, &["push"]) {
        return;
    }
    println!("{}", ui::green("Block list updated."));
}

/// `-c/--clean-backups`: list and delete `*.bak-*` in `~` and `~/.config`.
pub fn cmd_clean_backups(paths: &Paths) {
    let backups = all_backups(paths);
    if backups.is_empty() {
        println!("{}", ui::green("No backups found."));
        return;
    }
    println!("{}", ui::bold(&format!("Found {} backup(s):", backups.len())));
    for b in &backups {
        let is_symlink = std::fs::symlink_metadata(b).map(|m| m.file_type().is_symlink()).unwrap_or(false);
        let kind = if b.is_dir() && !is_symlink { "dir " } else { "file" };
        println!("  [{kind}] {}", b.display());
    }
    if !confirm("Delete all of these?") {
        println!("{}", ui::yellow("Cancelled."));
        return;
    }
    for b in &backups {
        let _ = copy::remove(b);
    }
    println!("{}", ui::green(&format!("Deleted {} backup(s).", backups.len())));
}

/// `-a/--apply [NAME...]`: `Some(names)` (non-empty) applies non-interactively;
/// `None` picks interactively from `profiles/`, falling back to a `*.bak-*` restore
/// picker when nothing is selectable.
pub fn cmd_apply(paths: &Paths, names: Option<&[String]>) {
    let host = hostname();
    let ignore = config::load_ignore(paths);
    let overrides = config::load_overrides(paths);
    let mut nodes = tree::build_apply_tree(paths, &ignore);
    let ts = backup_ts();

    if let Some(names) = names {
        let available: std::collections::HashSet<&str> = nodes.iter().map(|n| n.key.as_str()).collect();
        let missing: Vec<&String> = names.iter().filter(|n| !available.contains(n.as_str())).collect();
        if !missing.is_empty() {
            let list = missing.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ");
            println!("{}", ui::red(&format!("Not found in profiles/: {list}")));
            return;
        }
        for key in names {
            copy::apply_key(paths, key, &ts, &overrides, &host);
        }
        return;
    }

    let backups = all_backups(paths);
    if nodes.is_empty() && backups.is_empty() {
        println!("{}", ui::red("No configs or backups found."));
        return;
    }

    if !nodes.is_empty() {
        tree::preselect(paths, &mut nodes, "apply");
        let info = git::last_sync_info(paths, &nodes.iter().map(|n| n.key.clone()).collect::<Vec<_>>());
        let Some(result) = tui::interactive_select(nodes, "Apply dotfiles", Some(&info), None) else {
            report_cancelled("Apply");
            return;
        };
        let keys = tree::effective_selection(&result);
        if keys.is_empty() {
            println!("{}", ui::yellow("Nothing selected; aborting."));
            return;
        }
        let _ = config::save_cache(paths, "apply", &keys);
        for key in &keys {
            copy::apply_key(paths, key, &ts, &overrides, &host);
        }
        return;
    }

    if !backups.is_empty() {
        println!("{}", ui::bold("Backups:"));
        for (i, b) in backups.iter().enumerate() {
            println!("  {:>2}. {}", i + 1, b.file_name().unwrap_or_default().to_string_lossy());
        }
        let pick = pick_backup(backups.len());
        let path = &backups[pick];
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let orig_name = name.split(".bak-").next().unwrap_or(&name).to_string();
        let orig = path.with_file_name(&orig_name);
        if orig.exists() || std::fs::symlink_metadata(&orig).is_ok() {
            let backed = orig.with_file_name(format!("{orig_name}.bak-{ts}"));
            let _ = std::fs::rename(&orig, &backed);
        }
        let _ = copy::copy_any(path, &orig);
        println!("  restored {}", ui::cyan(&orig_name));
        return;
    }

    println!("{}", ui::yellow("Nothing selected."));
}

/// Numbered "Pick backup" prompt, default 1 (mirrors `rich.Prompt.ask` with
/// `choices`). Returns a 0-based index.
fn pick_backup(count: usize) -> usize {
    let choices = (1..=count).map(|i| i.to_string()).collect::<Vec<_>>();
    loop {
        print!("Pick backup [{}] (1): ", choices.join("/"));
        std::io::stdout().flush().ok();
        let mut line = String::new();
        if std::io::stdin().read_line(&mut line).unwrap_or(0) == 0 {
            return 0; // EOF → default "1"
        }
        let s = line.trim();
        if s.is_empty() {
            return 0;
        }
        if let Ok(n) = s.parse::<usize>() {
            if (1..=count).contains(&n) {
                return n - 1;
            }
        }
    }
}

/// `-P/--clean-profile`: delete selected folders *from* `profiles/` (never
/// pre-checked), confirm, then pull-rebase / commit / push.
pub fn cmd_clean_profile(paths: &Paths) {
    let host = hostname();
    let ignore = config::load_ignore(paths);
    let nodes = tree::build_apply_tree(paths, &ignore);
    if nodes.is_empty() {
        println!("{}", ui::yellow("Profile is empty; nothing to clean."));
        return;
    }
    let info = git::last_sync_info(paths, &nodes.iter().map(|n| n.key.clone()).collect::<Vec<_>>());
    // Note: no preselect — clean-profile starts empty so a stale cache can't delete.
    let Some(result) = tui::interactive_select(nodes, "Clean dotfiles", Some(&info), None) else {
        report_cancelled("Clean profile");
        return;
    };
    let keys = tree::effective_selection(&result);
    if keys.is_empty() {
        println!("{}", ui::yellow("Nothing selected; aborting."));
        return;
    }

    println!("{}", ui::red(&ui::bold("Will delete from profiles/:")));
    for k in &keys {
        let annot = info.get(k).cloned().unwrap_or_default();
        println!("  {}  {}", ui::red(k), ui::dim(&format!("({annot})")));
    }
    if !confirm("Delete these from the profile?") {
        println!("{}", ui::yellow("Cancelled."));
        return;
    }

    if !git::git(paths, &["pull", "--rebase"]) {
        return;
    }
    for key in &keys {
        let _ = copy::remove(&paths.profiles_dir.join(key));
        if let Ok(hosts) = std::fs::read_dir(&paths.hosts_dir) {
            for host_dir in hosts.filter_map(|e| e.ok()) {
                let _ = copy::remove(&host_dir.path().join(key));
            }
        }
        println!("  removed {}", ui::cyan(key));
    }

    let rel = rel_to_repo(paths, &paths.profiles_dir);
    if !git::git(paths, &["add", "-f", "--", &rel]) {
        return;
    }
    if nothing_staged(paths) {
        println!("{}", ui::yellow("No changes to commit."));
        return;
    }
    let msg = format!(
        "Clean profile from {host} at {} by {}: {}",
        now_stamp(),
        username(),
        keys.join(", ")
    );
    if !git::git(paths, &["commit", "-m", &msg]) || !git::git(paths, &["push"]) {
        return;
    }
    println!("{} {msg}", ui::green("Cleaned:"));
}

/// The no-args interactive menu loop. Requires a TTY (else prints the usage line
/// and exits 2).
pub fn run_menu(paths: &Paths) {
    if !is_interactive() {
        println!("Usage: tui [-s | -a [NAME...] | -c | -P]");
        std::process::exit(2);
    }
    let options: Vec<(String, String)> = [
        ("sync", "Save dotfiles"),
        ("apply", "Apply dotfiles"),
        ("clean-profile", "Clean dotfiles"),
        ("clean", "Clean dotfile backups"),
        ("block", "Edit block list"),
        ("quit", "Quit"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();

    loop {
        let choice = tui::menu_select("dotfiles TUI", &options, None);
        match choice.as_deref() {
            None | Some("quit") => return,
            Some("sync") => cmd_sync(paths),
            Some("apply") => cmd_apply(paths, None),
            Some("clean-profile") => cmd_clean_profile(paths),
            Some("clean") => cmd_clean_backups(paths),
            Some("block") => cmd_block(paths),
            _ => {}
        }
        println!();
    }
}
