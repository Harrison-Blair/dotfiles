//! Config + cache loading: `config/{ignore,includes,hosts}.toml` and the per-user
//! JSON selection cache. Mirrors the Python `load_*` / `save_*` helpers.
//!
//! PHASE 2A owns this file. Signatures below are frozen — implement the bodies and
//! add `#[cfg(test)]` tests; do not change `model.rs` or `Cargo.toml`.

use std::collections::{HashMap, HashSet};

use serde::Deserialize;

use crate::model::{Node, Paths};

/// Folder *names* hidden from selection lists (`[ignore]` in `ignore.toml`).
/// Missing/malformed file → empty set.
pub fn load_ignore(paths: &Paths) -> HashSet<String> {
    #[derive(Deserialize)]
    struct IgnoreFile {
        #[serde(default)]
        ignore: Vec<String>,
    }

    let path = paths.data_file("ignore.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashSet::new();
    };
    let Ok(data) = toml::from_str::<IgnoreFile>(&text) else {
        return HashSet::new();
    };
    data.ignore.into_iter().collect()
}

/// Rewrite `ignore.toml` byte-for-byte like the Python `save_ignore`:
///   - 3 header comment lines, then `ignore = [`, one `  "name",` per *sorted*
///     entry (double-quoted, JSON-style), then `]`, then a trailing newline.
///   - `final = sorted(selected ∪ (old − scannable))` where `scannable` is the set
///     of node labels — entries in `old` not scannable on this machine are kept.
pub fn save_ignore(
    paths: &Paths,
    selected: &HashSet<String>,
    nodes: &[Node],
    old: &HashSet<String>,
) -> anyhow::Result<()> {
    let scannable: HashSet<&str> = nodes.iter().map(|n| n.label.as_str()).collect();
    let mut final_set: HashSet<String> = selected.clone();
    for name in old {
        if !scannable.contains(name.as_str()) {
            final_set.insert(name.clone());
        }
    }
    let mut final_list: Vec<String> = final_set.into_iter().collect();
    final_list.sort();

    let mut lines: Vec<String> = vec![
        "# Folder names hidden from the selection list.".to_string(),
        "# Matched by name (not path) against BOTH top-level ~ dotfolders and ~/.config subdirs.".to_string(),
        "# Edit via the TUI \"Edit block list\" menu, or by hand — read at runtime, no rebuild needed.".to_string(),
        "ignore = [".to_string(),
    ];
    for name in &final_list {
        lines.push(format!("  {},", serde_json::to_string(name)?));
    }
    lines.push("]".to_string());
    lines.push(String::new());

    std::fs::write(paths.data_file("ignore.toml"), lines.join("\n"))?;
    Ok(())
}

/// Per-folder copy whitelists (`[includes]` in `includes.toml`), keyed by
/// home-relative folder path. Missing/malformed → empty map.
pub fn load_includes(paths: &Paths) -> HashMap<String, Vec<String>> {
    #[derive(Deserialize)]
    struct IncludesFile {
        #[serde(default)]
        includes: HashMap<String, Vec<String>>,
    }

    let path = paths.data_file("includes.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let Ok(data) = toml::from_str::<IncludesFile>(&text) else {
        return HashMap::new();
    };
    data.includes
}

/// Per-machine override paths (`[overrides]` in `hosts.toml`), keyed by
/// home-relative folder path. Missing/malformed → empty map.
pub fn load_overrides(paths: &Paths) -> HashMap<String, Vec<String>> {
    #[derive(Deserialize)]
    struct OverridesFile {
        #[serde(default)]
        overrides: HashMap<String, Vec<String>>,
    }

    let path = paths.data_file("hosts.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let Ok(data) = toml::from_str::<OverridesFile>(&text) else {
        return HashMap::new();
    };
    data.overrides
}

/// Load the per-user selection cache as `mode -> selected keys`. Returns an empty
/// map if the file is missing, unreadable, malformed, or its `version` field does
/// not equal [`crate::model::CACHE_VERSION`].
pub fn load_cache(paths: &Paths) -> HashMap<String, Vec<String>> {
    let path = paths.cache_path();
    let Ok(text) = std::fs::read_to_string(&path) else {
        return HashMap::new();
    };
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) else {
        return HashMap::new();
    };
    let Some(obj) = data.as_object() else {
        return HashMap::new();
    };
    let version = obj.get("version").and_then(|v| v.as_u64());
    if version != Some(crate::model::CACHE_VERSION as u64) {
        return HashMap::new();
    }

    let mut result = HashMap::new();
    for (mode, value) in obj {
        if mode == "version" {
            continue;
        }
        let keys: Vec<String> = value
            .get("selected")
            .and_then(|s| s.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        result.insert(mode.clone(), keys);
    }
    result
}

/// Persist `keys` under `mode` in the per-user cache, preserving other modes and
/// stamping the current `version`. Creates `config/cache/` as needed. Written with
/// 2-space indent (gitignored; readability only).
pub fn save_cache(paths: &Paths, mode: &str, keys: &[String]) -> anyhow::Result<()> {
    std::fs::create_dir_all(&paths.cache_dir)?;

    let mut cache = load_cache(paths);
    cache.insert(mode.to_string(), keys.to_vec());

    let mut map = serde_json::Map::new();
    map.insert(
        "version".to_string(),
        serde_json::Value::from(crate::model::CACHE_VERSION),
    );
    for (mode, keys) in cache {
        map.insert(
            mode,
            serde_json::json!({ "selected": keys }),
        );
    }

    let text = serde_json::to_string_pretty(&serde_json::Value::Object(map))?;
    std::fs::write(paths.cache_path(), text)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn test_paths() -> Paths {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let base = std::env::temp_dir().join(format!(
            "config_rs_test_{}_{}",
            std::process::id(),
            n
        ));
        let data_dir = base.join("config");
        let cache_dir = data_dir.join("cache");
        std::fs::create_dir_all(&data_dir).unwrap();

        Paths {
            home: base.clone(),
            config_dir: base.join(".config"),
            claude_dir: base.join(".claude"),
            repo_root: base.clone(),
            profiles_dir: base.join("profiles"),
            hosts_dir: base.join("profiles").join("hosts"),
            data_dir,
            cache_dir,
        }
    }

    fn node(label: &str) -> Node {
        Node::top(label.to_string(), label.to_string(), PathBuf::from(label))
    }

    #[test]
    fn save_ignore_exact_format() {
        let paths = test_paths();
        let selected: HashSet<String> = ["beta", "alpha"].iter().map(|s| s.to_string()).collect();
        let nodes = vec![node("alpha"), node("beta"), node("gamma")];
        let old: HashSet<String> = HashSet::new();

        save_ignore(&paths, &selected, &nodes, &old).unwrap();

        let text = std::fs::read_to_string(paths.data_file("ignore.toml")).unwrap();
        let expected = concat!(
            "# Folder names hidden from the selection list.\n",
            "# Matched by name (not path) against BOTH top-level ~ dotfolders and ~/.config subdirs.\n",
            "# Edit via the TUI \"Edit block list\" menu, or by hand — read at runtime, no rebuild needed.\n",
            "ignore = [\n",
            "  \"alpha\",\n",
            "  \"beta\",\n",
            "]\n",
        );
        assert_eq!(text, expected);
    }

    #[test]
    fn save_ignore_preserves_non_scannable_old_entries() {
        let paths = test_paths();
        let selected: HashSet<String> = ["beta"].iter().map(|s| s.to_string()).collect();
        // "alpha" is scannable (present in nodes) but not selected -> dropped.
        // "zeta" is NOT scannable (absent from nodes) -> preserved from old.
        let nodes = vec![node("alpha"), node("beta")];
        let old: HashSet<String> = ["alpha", "zeta"].iter().map(|s| s.to_string()).collect();

        save_ignore(&paths, &selected, &nodes, &old).unwrap();

        let text = std::fs::read_to_string(paths.data_file("ignore.toml")).unwrap();
        let expected = concat!(
            "# Folder names hidden from the selection list.\n",
            "# Matched by name (not path) against BOTH top-level ~ dotfolders and ~/.config subdirs.\n",
            "# Edit via the TUI \"Edit block list\" menu, or by hand — read at runtime, no rebuild needed.\n",
            "ignore = [\n",
            "  \"beta\",\n",
            "  \"zeta\",\n",
            "]\n",
        );
        assert_eq!(text, expected);
    }

    #[test]
    fn load_cache_version_gate() {
        let paths = test_paths();
        std::fs::create_dir_all(&paths.cache_dir).unwrap();

        // Missing file -> empty.
        assert!(load_cache(&paths).is_empty());

        // Wrong version -> empty.
        std::fs::write(
            paths.cache_path(),
            r#"{"version":2,"sync":{"selected":["a"]}}"#,
        )
        .unwrap();
        assert!(load_cache(&paths).is_empty());

        // Correct version -> parsed.
        std::fs::write(
            paths.cache_path(),
            r#"{"version":1,"sync":{"selected":["a","b"]}}"#,
        )
        .unwrap();
        let cache = load_cache(&paths);
        assert_eq!(cache.get("sync"), Some(&vec!["a".to_string(), "b".to_string()]));
    }

    #[test]
    fn save_cache_round_trip_preserves_other_modes() {
        let paths = test_paths();
        save_cache(&paths, "sync", &["a".to_string(), "b".to_string()]).unwrap();
        save_cache(&paths, "apply", &["c".to_string()]).unwrap();

        let cache = load_cache(&paths);
        assert_eq!(cache.get("sync"), Some(&vec!["a".to_string(), "b".to_string()]));
        assert_eq!(cache.get("apply"), Some(&vec!["c".to_string()]));
    }

    #[test]
    fn load_ignore_includes_overrides_parse_and_fallback() {
        let paths = test_paths();

        std::fs::write(
            paths.data_file("ignore.toml"),
            "ignore = [\"foo\", \"bar\"]\n",
        )
        .unwrap();
        let ignore = load_ignore(&paths);
        assert_eq!(
            ignore,
            ["foo", "bar"].iter().map(|s| s.to_string()).collect()
        );

        std::fs::write(
            paths.data_file("includes.toml"),
            "[includes]\n\".claude\" = [\"agents\", \"commands\"]\n",
        )
        .unwrap();
        let includes = load_includes(&paths);
        assert_eq!(
            includes.get(".claude"),
            Some(&vec!["agents".to_string(), "commands".to_string()])
        );

        std::fs::write(
            paths.data_file("hosts.toml"),
            "[overrides]\n\".config/hypr\" = [\"a.lua\"]\n",
        )
        .unwrap();
        let overrides = load_overrides(&paths);
        assert_eq!(
            overrides.get(".config/hypr"),
            Some(&vec!["a.lua".to_string()])
        );

        // Missing files -> empty.
        let missing = test_paths();
        assert!(load_ignore(&missing).is_empty());
        assert!(load_includes(&missing).is_empty());
        assert!(load_overrides(&missing).is_empty());

        // Malformed file -> empty.
        std::fs::write(paths.data_file("ignore.toml"), "not valid toml [[[").unwrap();
        assert!(load_ignore(&paths).is_empty());
    }
}
