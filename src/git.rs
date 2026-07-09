//! Git plumbing: the `git(...)` wrapper and `last_sync_info` (a single `git log`
//! traversal mapping each profile key to a human-readable "last synced" line).
//! Mirrors the Python `_git` / `last_sync_info` / `_format_sync`.
//!
//! PHASE 2C owns this file (with `copy.rs`). Signatures below are frozen —
//! implement the bodies and add `#[cfg(test)]` tests; do not change `model.rs`
//! or `Cargo.toml`.

use std::collections::HashMap;

use crate::model::Paths;

/// Run `git <args>` in the repo root. On non-zero exit, print a one-line error
/// (git's own stderr is already visible) and return `false`; else `true`.
/// Never panics.
pub fn git(paths: &Paths, args: &[&str]) -> bool {
    let status = std::process::Command::new("git")
        .args(args)
        .current_dir(&paths.repo_root)
        .status();
    let ok = matches!(status, Ok(s) if s.success());
    if !ok {
        println!("git {} failed — resolve and retry.", args[0]);
    }
    ok
}

/// Best-effort quiet refresh so the latest committed profiles are available to
/// apply: `git pull --rebase` in the repo root, capturing output. Returns `None`
/// (no message, stay silent) when the pull succeeds, when the tree is already up to
/// date, or when there is no upstream tracking branch to pull from. Returns
/// `Some(msg)` — a one-line reason to warn about — only when a pull was attempted
/// (an upstream exists) and it failed. Never prints; the caller decides how to warn.
pub fn refresh_from_remote(paths: &Paths) -> Option<String> {
    // No upstream tracking branch (fresh repo / no remote) → nothing to pull.
    let upstream = std::process::Command::new("git")
        .args(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        .current_dir(&paths.repo_root)
        .output();
    if !matches!(upstream, Ok(o) if o.status.success()) {
        return None;
    }

    let out = std::process::Command::new("git")
        .args(["pull", "--rebase"])
        .current_dir(&paths.repo_root)
        .output();
    match out {
        Ok(o) if o.status.success() => None,
        Ok(o) => Some(summarize_pull_failure(&String::from_utf8_lossy(&o.stderr))),
        Err(e) => Some(format!("could not run git: {e}")),
    }
}

/// Pick a single-line reason from `git pull` stderr for the warning. Uses the last
/// non-empty line (git's most specific message), falling back to a generic string.
fn summarize_pull_failure(stderr: &str) -> String {
    stderr
        .lines()
        .rev()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "git pull --rebase failed".to_string())
}

/// Map each `profiles/` key to a "last synced" line via a single
/// `git log --format=%x00%cI%x1f%s --name-only -- profiles` traversal (newest
/// first; the first commit touching `profiles/<key>` or `profiles/<key>/…` wins).
/// Unmatched keys → `"untracked / never synced"`.
pub fn last_sync_info(paths: &Paths, keys: &[String]) -> HashMap<String, String> {
    let rel = paths
        .profiles_dir
        .strip_prefix(&paths.repo_root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| "profiles".to_string());

    let output = std::process::Command::new("git")
        .args(["log", "--format=%x00%cI%x1f%s", "--name-only", "--", &rel])
        .current_dir(&paths.repo_root)
        .output();

    let out = match output {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(_) => String::new(),
    };

    parse_log(&rel, &out, keys)
}

/// Pure parsing of the `git log --name-only` output described above. Split out
/// from `last_sync_info` so it can be tested without invoking git.
fn parse_log(rel: &str, out: &str, keys: &[String]) -> HashMap<String, String> {
    let mut info: HashMap<String, String> = HashMap::new();
    let mut pending: std::collections::HashSet<&str> =
        keys.iter().map(|k| k.as_str()).collect();
    let mut cur: Option<(String, String)> = None;

    for line in out.split('\n') {
        if let Some(rest) = line.strip_prefix('\x00') {
            let (date_iso, subject) = match rest.split_once('\x1f') {
                Some((d, s)) => (d.to_string(), s.to_string()),
                None => (rest.to_string(), String::new()),
            };
            cur = Some((date_iso, subject));
        } else if !line.is_empty() && !pending.is_empty() {
            let Some((date_iso, subject)) = cur.as_ref() else {
                continue;
            };
            let matched: Vec<&str> = pending
                .iter()
                .copied()
                .filter(|k| {
                    line == format!("{rel}/{k}") || line.starts_with(&format!("{rel}/{k}/"))
                })
                .collect();
            for k in matched {
                info.insert(k.to_string(), format_sync(date_iso, subject));
                pending.remove(k);
            }
        }
    }

    for k in pending {
        info.insert(k.to_string(), "untracked / never synced".to_string());
    }

    info
}

/// Format one commit's `(committer-date-iso, subject)` into a display line.
/// `Sync from <host> … by <user>` → `last sync <YYYY-MM-DD HH:MM> from <host> by
/// <user>`; anything else → `last commit <when>`. (`when` = first 16 chars of the
/// ISO date with `T`→space.)
pub fn format_sync(date_iso: &str, subject: &str) -> String {
    let when = date_iso.get(..16).unwrap_or(date_iso).replace('T', " ");
    match match_sync_subject(subject) {
        Some((host, user)) => format!("last sync {when} from {host} by {user}"),
        None => format!("last commit {when}"),
    }
}

/// Hand-rolled equivalent of `re.search(r"Sync from (\S+) .* by (\S+)", subject)`.
/// Requires a "Sync from " prefix occurrence, a following non-space host token,
/// then (later in the string) the LAST " by " occurrence followed by a non-space
/// user token — matching the greedy `.*` semantics of the Python regex.
fn match_sync_subject(subject: &str) -> Option<(String, String)> {
    let start = subject.find("Sync from ")?;
    let after_prefix = &subject[start + "Sync from ".len()..];
    let host_end = after_prefix.find(char::is_whitespace)?;
    if host_end == 0 {
        return None;
    }
    let host = &after_prefix[..host_end];

    // There must be at least one char matched by `.` between host and " by ".
    let rest_after_host = &after_prefix[host_end..];

    // Greedy `.*` means we want the LAST " by " occurrence in rest_after_host.
    let by_pos = rest_after_host.rfind(" by ")?;
    let after_by = &rest_after_host[by_pos + " by ".len()..];
    let user_end = after_by
        .find(char::is_whitespace)
        .unwrap_or(after_by.len());
    if user_end == 0 {
        return None;
    }
    let user = &after_by[..user_end];

    Some((host.to_string(), user.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    #[test]
    fn summarize_pull_failure_picks_last_nonempty_line() {
        let stderr = "First line\nerror: cannot pull with rebase\n\n";
        assert_eq!(summarize_pull_failure(stderr), "error: cannot pull with rebase");
        assert_eq!(summarize_pull_failure("   \n\n"), "git pull --rebase failed");
    }

    // --- integration tests exercising the real `git pull --rebase` behavior ---

    /// Run git in `dir`, isolated from the user's global/system config so commits
    /// use the explicit identity below and nothing external interferes.
    fn git_in(dir: &Path, args: &[&str]) -> std::process::Output {
        Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env("GIT_TERMINAL_PROMPT", "0")
            .output()
            .expect("git available")
    }

    fn commit_all(dir: &Path, msg: &str) {
        git_in(dir, &["add", "-A"]);
        git_in(
            dir,
            &["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-m", msg],
        );
    }

    fn paths_at(root: &Path) -> Paths {
        Paths {
            home: root.to_path_buf(),
            config_dir: root.join(".config"),
            claude_dir: root.join(".claude"),
            repo_root: root.to_path_buf(),
            profiles_dir: root.join("profiles"),
            hosts_dir: root.join("profiles/hosts"),
            data_dir: root.join("config"),
            cache_dir: root.join("config/cache"),
        }
    }

    /// Build a bare remote with one commit, clone it to `local` (remote-tracking set
    /// up), then advance the remote by one commit via a second clone. Returns the
    /// `local` path — one commit behind its upstream.
    fn upstream_ahead(tag: &str) -> (PathBuf, PathBuf) {
        let tmp = std::env::temp_dir().join(format!("gittest-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        let remote = tmp.join("remote.git");
        git_in(&tmp, &["init", "--bare", "-b", "main", remote.to_str().unwrap()]);

        let seed = tmp.join("seed");
        git_in(&tmp, &["clone", remote.to_str().unwrap(), seed.to_str().unwrap()]);
        std::fs::write(seed.join("f.txt"), b"v1").unwrap();
        commit_all(&seed, "init");
        git_in(&seed, &["push", "-u", "origin", "main"]);

        let local = tmp.join("local");
        git_in(&tmp, &["clone", remote.to_str().unwrap(), local.to_str().unwrap()]);

        // Advance the remote from a throwaway clone.
        let other = tmp.join("other");
        git_in(&tmp, &["clone", remote.to_str().unwrap(), other.to_str().unwrap()]);
        std::fs::write(other.join("f.txt"), b"v2").unwrap();
        commit_all(&other, "update");
        git_in(&other, &["push", "origin", "main"]);

        (tmp, local)
    }

    #[test]
    fn refresh_no_upstream_is_silent() {
        let tmp = std::env::temp_dir().join(format!("gittest-noups-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        git_in(&tmp, &["init", "-b", "main", "."]);
        std::fs::write(tmp.join("f.txt"), b"v1").unwrap();
        commit_all(&tmp, "init");

        // A committed repo with no configured upstream must stay silent.
        assert_eq!(refresh_from_remote(&paths_at(&tmp)), None);
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn refresh_success_pulls_and_is_silent() {
        let (tmp, local) = upstream_ahead("ok");
        assert_eq!(refresh_from_remote(&paths_at(&local)), None);
        // The remote's newer commit is now present locally.
        assert_eq!(std::fs::read(local.join("f.txt")).unwrap(), b"v2");
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn refresh_failure_returns_message() {
        let (tmp, local) = upstream_ahead("fail");
        // Dirty the tracked file so `pull --rebase` (which must replay onto the
        // advanced upstream) refuses with a non-zero exit.
        std::fs::write(local.join("f.txt"), b"local-dirty").unwrap();
        let msg = refresh_from_remote(&paths_at(&local));
        assert!(msg.is_some(), "expected a warning message on failed pull");
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn format_sync_matches_sync_subject() {
        let s = format_sync(
            "2026-07-07T03:48:29+00:00",
            "Sync from iceberg at 2026-07-07 03:48:29 by penguin",
        );
        assert_eq!(s, "last sync 2026-07-07 03:48 from iceberg by penguin");
    }

    #[test]
    fn format_sync_non_matching_subject() {
        let s = format_sync("2026-07-07T03:48:29+00:00", "Build tui binary [skip ci]");
        assert_eq!(s, "last commit 2026-07-07 03:48");
    }

    #[test]
    fn format_sync_short_date() {
        let s = format_sync("2026-07-07", "Build tui binary");
        assert_eq!(s, "last commit 2026-07-07");
    }

    #[test]
    fn format_sync_t_replaced() {
        let s = format_sync("2026-06-07T19:32:00+00:00", "some other message");
        assert_eq!(s, "last commit 2026-06-07 19:32");
    }

    #[test]
    fn parse_log_first_commit_wins_and_untracked_fallback() {
        // Two commits touching ".claude"; newest first. The first (newest) wins.
        let out = concat!(
            "\x002026-07-07T03:48:29+00:00\x1fSync from iceberg at 2026-07-07 03:48:29 by penguin\n",
            "\n",
            "profiles/.claude\n",
            "profiles/.config/hypr/hyprland.conf\n",
            "\n",
            "\x002026-06-01T00:00:00+00:00\x1fSync from toboggan at 2026-06-01 00:00:00 by penguin\n",
            "\n",
            "profiles/.claude\n",
        );
        let keys = vec![
            ".claude".to_string(),
            ".config/hypr".to_string(),
            ".config/quickshell".to_string(),
        ];
        let info = parse_log("profiles", out, &keys);
        assert_eq!(
            info.get(".claude").unwrap(),
            "last sync 2026-07-07 03:48 from iceberg by penguin"
        );
        assert_eq!(
            info.get(".config/hypr").unwrap(),
            "last sync 2026-07-07 03:48 from iceberg by penguin"
        );
        assert_eq!(
            info.get(".config/quickshell").unwrap(),
            "untracked / never synced"
        );
    }
}
