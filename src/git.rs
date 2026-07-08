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
