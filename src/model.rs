//! Shared types: the `Node` selection-tree element and `Paths`, the runtime path
//! model. This module is the frozen interface boundary the other modules build on.

use std::path::{Path, PathBuf};

/// Cache schema version. Bump when the on-disk cache shape changes; a mismatch
/// makes `load_cache` return empty (mirrors the Python `CACHE_VERSION` gate).
pub const CACHE_VERSION: u32 = 1;

/// A single row in a selection tree. Keyed by a *home-relative* path
/// (`.config/hypr`, `.claude`, `.config`). Mirrors the Python `Node` dataclass.
#[derive(Debug, Clone)]
pub struct Node {
    /// Home-relative path, e.g. ".config/hypr", ".claude", ".config".
    pub key: String,
    /// Display text (basename).
    pub label: String,
    /// 0 = top-level, 1 = child under `.config`.
    pub depth: usize,
    /// Absolute source path. Stored to mirror the Python `Node` dataclass; the
    /// commands recompute paths from keys, so nothing reads it back.
    #[allow(dead_code)]
    pub source: PathBuf,
    /// True only for the aggregate ".config" row.
    pub is_parent: bool,
    /// ".config" for children, else None.
    pub parent_key: Option<String>,
    /// Whether the row is checked.
    pub checked: bool,
}

impl Node {
    /// Top-level node (depth 0).
    pub fn top(key: impl Into<String>, label: impl Into<String>, source: PathBuf) -> Self {
        Node {
            key: key.into(),
            label: label.into(),
            depth: 0,
            source,
            is_parent: false,
            parent_key: None,
            checked: false,
        }
    }

    /// The aggregate ".config" parent row.
    pub fn config_parent(source: PathBuf) -> Self {
        Node {
            key: ".config".to_string(),
            label: ".config".to_string(),
            depth: 0,
            source,
            is_parent: true,
            parent_key: None,
            checked: false,
        }
    }

    /// A ".config/<name>" child row (depth 1).
    pub fn config_child(label: impl Into<String>, source: PathBuf) -> Self {
        let label = label.into();
        Node {
            key: format!(".config/{label}"),
            label,
            depth: 1,
            source,
            is_parent: false,
            parent_key: Some(".config".to_string()),
            checked: false,
        }
    }
}

/// The runtime path model. Everything is derived from the user's home directory
/// and the repo root (the directory of the running binary, or the repo detected
/// from an ancestor during `cargo run`). Mirrors the Python module globals.
#[derive(Debug, Clone)]
pub struct Paths {
    /// The user's home directory (`~`).
    pub home: PathBuf,
    /// `~/.config`.
    pub config_dir: PathBuf,
    /// `~/.claude`. Mirrors the Python `CLAUDE_DIR` module global (defined but
    /// unused); kept for parity with the path model.
    #[allow(dead_code)]
    pub claude_dir: PathBuf,
    /// Repo root (holds `config/` and `profiles/`).
    pub repo_root: PathBuf,
    /// `<repo>/profiles`.
    pub profiles_dir: PathBuf,
    /// `<repo>/profiles/hosts`.
    pub hosts_dir: PathBuf,
    /// `<repo>/config`.
    pub data_dir: PathBuf,
    /// `<repo>/config/cache`.
    pub cache_dir: PathBuf,
}

impl Paths {
    /// Resolve the path model from the environment.
    pub fn resolve() -> Self {
        let home = home_dir();
        let repo_root = find_repo_root();
        Paths::from_roots(home, repo_root)
    }

    fn from_roots(home: PathBuf, repo_root: PathBuf) -> Self {
        let config_dir = home.join(".config");
        let claude_dir = home.join(".claude");
        let profiles_dir = repo_root.join("profiles");
        let hosts_dir = profiles_dir.join("hosts");
        let data_dir = repo_root.join("config");
        let cache_dir = data_dir.join("cache");
        Paths {
            home,
            config_dir,
            claude_dir,
            repo_root,
            profiles_dir,
            hosts_dir,
            data_dir,
            cache_dir,
        }
    }

    /// `<repo>/config/<name>.toml`.
    pub fn data_file(&self, name: &str) -> PathBuf {
        self.data_dir.join(name)
    }

    /// `<repo>/config/cache/<user>.json`.
    pub fn cache_path(&self) -> PathBuf {
        self.cache_dir.join(format!("{}.json", username()))
    }
}

/// The system hostname (mirrors `socket.gethostname()`).
pub fn hostname() -> String {
    whoami::fallible::hostname().unwrap_or_else(|_| "localhost".to_string())
}

/// The current username (mirrors `getpass.getuser()`).
pub fn username() -> String {
    whoami::fallible::username().unwrap_or_else(|_| "unknown".to_string())
}

fn home_dir() -> PathBuf {
    #[allow(deprecated)]
    std::env::home_dir().expect("could not determine home directory")
}

/// A directory is the repo root if it holds both `config/` and `profiles/`.
fn is_repo_root(dir: &Path) -> bool {
    dir.join("config").is_dir() && dir.join("profiles").is_dir()
}

/// Resolve the repo root. The committed binary lives at the repo root, so its own
/// directory is the root. For `cargo run` (binary under `target/…`), search
/// ancestors of the exe dir and then of the CWD for the `config/` + `profiles/`
/// marker. Falls back to the exe's directory.
fn find_repo_root() -> PathBuf {
    let exe = std::env::current_exe().ok();
    let exe_dir = exe
        .as_ref()
        .and_then(|p| p.canonicalize().ok())
        .and_then(|p| p.parent().map(Path::to_path_buf));

    if let Some(dir) = &exe_dir {
        if let Some(found) = search_ancestors(dir) {
            return found;
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        if let Some(found) = search_ancestors(&cwd) {
            return found;
        }
    }
    exe_dir.unwrap_or_else(|| PathBuf::from("."))
}

fn search_ancestors(start: &Path) -> Option<PathBuf> {
    start.ancestors().find(|d| is_repo_root(d)).map(Path::to_path_buf)
}
