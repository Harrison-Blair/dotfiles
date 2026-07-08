//! Selection-tree discovery and the selection-resolution logic (whole-`.config`
//! vs. individual subdirs). Mirrors the Python tree/selection helpers.
//!
//! PHASE 2B owns this file. Signatures below are frozen — implement the bodies and
//! add `#[cfg(test)]` tests; do not change `model.rs` or `Cargo.toml`.

use std::collections::HashSet;

use crate::config;
use crate::model::{Node, Paths};

/// Build the selection tree under `root`: sorted top-level dotfolders (skipping
/// names in `ignore`), with `.config` expanded into an aggregate parent row
/// followed by its sorted non-dot subdirs (also skipping `ignore`d names).
/// Non-existent `root` → empty.
pub fn build_tree(root: &std::path::Path, ignore: &HashSet<String>) -> Vec<Node> {
    let mut nodes = Vec::new();
    if !root.is_dir() {
        return nodes;
    }
    let mut top_names: Vec<String> = match std::fs::read_dir(root) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .filter(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                e.path().is_dir() && name.starts_with('.') && !ignore.contains(&name)
            })
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect(),
        Err(_) => return nodes,
    };
    top_names.sort();

    for name in top_names {
        let src = root.join(&name);
        if name == ".config" {
            nodes.push(Node::config_parent(src.clone()));
            let mut children: Vec<String> = match std::fs::read_dir(&src) {
                Ok(entries) => entries
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        let cname = e.file_name().to_string_lossy().to_string();
                        e.path().is_dir() && !cname.starts_with('.') && !ignore.contains(&cname)
                    })
                    .map(|e| e.file_name().to_string_lossy().to_string())
                    .collect(),
                Err(_) => Vec::new(),
            };
            children.sort();
            for cname in children {
                let csrc = src.join(&cname);
                nodes.push(Node::config_child(cname, csrc));
            }
        } else {
            nodes.push(Node::top(name.clone(), name, src));
        }
    }
    nodes
}

/// `build_tree` rooted at `~`.
pub fn build_sync_tree(paths: &Paths, ignore: &HashSet<String>) -> Vec<Node> {
    build_tree(&paths.home, ignore)
}

/// `build_tree` rooted at `profiles/`.
pub fn build_apply_tree(paths: &Paths, ignore: &HashSet<String>) -> Vec<Node> {
    build_tree(&paths.profiles_dir, ignore)
}

fn remove_path(p: &std::path::Path) {
    match std::fs::symlink_metadata(p) {
        Ok(meta) if meta.is_dir() => {
            let _ = std::fs::remove_dir_all(p);
        }
        Ok(_) => {
            let _ = std::fs::remove_file(p);
        }
        Err(_) => {}
    }
}

/// Delete folders under `profiles/` whose *name* is in `ignore` (top-level
/// dotfolders + `.config/*` subdirs), mirroring the name matching in `build_tree`.
/// Returns the pruned home-relative keys.
pub fn prune_ignored(paths: &Paths, ignore: &HashSet<String>) -> Vec<String> {
    let mut pruned = Vec::new();
    if !paths.profiles_dir.is_dir() {
        return pruned;
    }
    if let Ok(entries) = std::fs::read_dir(&paths.profiles_dir) {
        for e in entries.filter_map(|e| e.ok()) {
            let name = e.file_name().to_string_lossy().to_string();
            let p = e.path();
            if p.is_dir() && name.starts_with('.') && ignore.contains(&name) {
                remove_path(&p);
                pruned.push(name);
            }
        }
    }
    let config = paths.profiles_dir.join(".config");
    if config.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&config) {
            for e in entries.filter_map(|e| e.ok()) {
                let name = e.file_name().to_string_lossy().to_string();
                let p = e.path();
                if p.is_dir() && ignore.contains(&name) {
                    remove_path(&p);
                    pruned.push(format!(".config/{name}"));
                }
            }
        }
    }
    pruned
}

/// True if the aggregate `.config` row is checked (act on the whole folder).
pub fn config_whole(nodes: &[Node]) -> bool {
    nodes
        .iter()
        .any(|n| n.is_parent && n.key == ".config" && n.checked)
}

/// Resolve the checked rows into home-relative keys. When `.config` is whole,
/// its children are implied (not listed individually); otherwise checked children
/// are listed. Top-level checked rows are always listed.
pub fn effective_selection(nodes: &[Node]) -> Vec<String> {
    let whole = config_whole(nodes);
    let mut keys = Vec::new();
    for n in nodes {
        if n.parent_key.as_deref() == Some(".config") {
            if !whole && n.checked {
                keys.push(n.key.clone());
            }
        } else if n.checked {
            keys.push(n.key.clone());
        }
    }
    keys
}

/// The set of blocked folder *names* implied by the checked rows (used by the
/// block-list editor). `.config` whole → the name ".config"; otherwise checked
/// children contribute their label; checked top-level rows contribute their label.
pub fn blocked_names(nodes: &[Node]) -> HashSet<String> {
    let whole = config_whole(nodes);
    let mut names = HashSet::new();
    for n in nodes {
        if n.is_parent && n.key == ".config" {
            if n.checked {
                names.insert(".config".to_string());
            }
        } else if n.parent_key.as_deref() == Some(".config") {
            if !whole && n.checked {
                names.insert(n.label.clone());
            }
        } else if n.checked {
            names.insert(n.label.clone());
        }
    }
    names
}

/// Pre-check nodes whose key is in the cached selection for `mode`
/// (via [`config::load_cache`]).
pub fn preselect(paths: &Paths, nodes: &mut [Node], mode: &str) {
    let cache = config::load_cache(paths);
    let saved: HashSet<&String> = cache.get(mode).map_or_else(HashSet::new, |v| v.iter().collect());
    for n in nodes.iter_mut() {
        if saved.contains(&n.key) {
            n.checked = true;
        }
    }
}

/// Pre-check nodes whose label is in `ignore` (block-list editor starting state).
pub fn preselect_blocked(nodes: &mut [Node], ignore: &HashSet<String>) {
    for n in nodes.iter_mut() {
        if ignore.contains(&n.label) {
            n.checked = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn unique_tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "tree_rs_test_{name}_{:?}",
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn build_tree_orders_and_filters() {
        let root = unique_tmp("build_tree");
        fs::create_dir_all(root.join(".config/a")).unwrap();
        fs::create_dir_all(root.join(".config/b")).unwrap();
        fs::create_dir_all(root.join(".foo")).unwrap();
        fs::create_dir_all(root.join("not_dotted")).unwrap();
        fs::create_dir_all(root.join(".ignored")).unwrap();

        let mut ignore = HashSet::new();
        ignore.insert(".ignored".to_string());

        let nodes = build_tree(&root, &ignore);

        // Order: ".config" sorts before ".foo" alphabetically.
        let keys: Vec<&str> = nodes.iter().map(|n| n.key.as_str()).collect();
        assert_eq!(keys, vec![".config", ".config/a", ".config/b", ".foo"]);

        assert!(nodes[0].is_parent);
        assert_eq!(nodes[0].depth, 0);
        assert_eq!(nodes[0].parent_key, None);

        assert!(!nodes[1].is_parent);
        assert_eq!(nodes[1].depth, 1);
        assert_eq!(nodes[1].parent_key, Some(".config".to_string()));
        assert_eq!(nodes[1].label, "a");

        assert_eq!(nodes[3].depth, 0);
        assert!(!nodes[3].is_parent);
        assert_eq!(nodes[3].label, ".foo");

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn build_tree_missing_root_is_empty() {
        let root = std::env::temp_dir().join("tree_rs_test_does_not_exist_xyz");
        let nodes = build_tree(&root, &HashSet::new());
        assert!(nodes.is_empty());
    }

    fn sample_nodes() -> Vec<Node> {
        vec![
            Node::top("bar", "bar", PathBuf::from("/x/bar")),
            Node::config_parent(PathBuf::from("/x/.config")),
            Node::config_child("a", PathBuf::from("/x/.config/a")),
            Node::config_child("b", PathBuf::from("/x/.config/b")),
        ]
    }

    #[test]
    fn selection_whole_config_checked() {
        let mut nodes = sample_nodes();
        nodes[1].checked = true; // .config parent checked

        assert!(config_whole(&nodes));
        let sel = effective_selection(&nodes);
        assert!(sel.contains(&".config".to_string()));
        assert!(!sel.contains(&".config/a".to_string()));
        assert!(!sel.contains(&".config/b".to_string()));

        let blocked = blocked_names(&nodes);
        assert_eq!(blocked, HashSet::from([".config".to_string()]));
    }

    #[test]
    fn selection_individual_child_checked() {
        let mut nodes = sample_nodes();
        nodes[2].checked = true; // .config/a checked, parent not

        assert!(!config_whole(&nodes));
        let sel = effective_selection(&nodes);
        assert_eq!(sel, vec![".config/a".to_string()]);

        let blocked = blocked_names(&nodes);
        assert_eq!(blocked, HashSet::from(["a".to_string()]));
    }

    #[test]
    fn selection_top_level_checked() {
        let mut nodes = sample_nodes();
        nodes[0].checked = true; // top-level "bar"

        let sel = effective_selection(&nodes);
        assert_eq!(sel, vec!["bar".to_string()]);

        let blocked = blocked_names(&nodes);
        assert_eq!(blocked, HashSet::from(["bar".to_string()]));
    }

    #[test]
    fn preselect_blocked_checks_matching_labels() {
        let mut nodes = sample_nodes();
        let mut ignore = HashSet::new();
        ignore.insert("a".to_string());
        ignore.insert("bar".to_string());

        preselect_blocked(&mut nodes, &ignore);

        assert!(nodes[0].checked); // bar
        assert!(!nodes[1].checked); // .config parent, not ignored
        assert!(nodes[2].checked); // a
        assert!(!nodes[3].checked); // b
    }
}
