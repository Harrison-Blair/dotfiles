//! Filesystem copy helpers with symlink preservation, the includes whitelist, and
//! host-override relocation/overlay. Mirrors the Python copy helpers + `apply_key`.
//!
//! PHASE 2C owns this file (with `git.rs`). Signatures below are frozen — implement
//! the bodies and add `#[cfg(test)]` tests; do not change `model.rs` or `Cargo.toml`.
//!
//! Rust std has no recursive copy: hand-roll a walker that recreates symlinks via
//! `std::os::unix::fs::symlink` and copies file bytes + mode (preserving symlinks
//! as symlinks, like `shutil.copytree(symlinks=True)` / `copy2(follow_symlinks=False)`).

use std::collections::HashMap;
use std::collections::HashSet;
use std::path::Path;

use crate::model::Paths;
use crate::ui;

/// Remove a path: recursively if it's a real directory, else unlink (also handles
/// dangling symlinks). No-op if it doesn't exist. Mirrors Python `_remove`.
pub fn remove(path: &Path) -> anyhow::Result<()> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };
    if meta.is_dir() && !meta.file_type().is_symlink() {
        std::fs::remove_dir_all(path)?;
    } else {
        std::fs::remove_file(path)?;
    }
    Ok(())
}

/// Recursively copy `src` into `dst`, preserving symlinks, skipping any entry
/// whose name is in `ignore`.
fn copy_tree(src: &Path, dst: &Path, ignore: Option<&HashSet<String>>) -> anyhow::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy().into_owned();
        if let Some(ig) = ignore {
            if ig.contains(&name_str) {
                continue;
            }
        }
        let s = entry.path();
        let d = dst.join(&name);
        copy_entry(&s, &d, ignore)?;
    }
    Ok(())
}

/// Copy a single directory entry (file, dir, or symlink) from `s` to `d`,
/// recursing into directories and preserving symlinks.
fn copy_entry(s: &Path, d: &Path, ignore: Option<&HashSet<String>>) -> anyhow::Result<()> {
    let meta = std::fs::symlink_metadata(s)?;
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(s)?;
        std::os::unix::fs::symlink(target, d)?;
    } else if meta.is_dir() {
        copy_tree(s, d, ignore)?;
    } else {
        std::fs::copy(s, d)?;
    }
    Ok(())
}

/// Copy `src` → `dst`, replacing `dst` first.
///   - `includes = None`: copy the whole tree (symlinks preserved). During this
///     wholesale copy, prune any entry whose *name* is in `ignore`.
///   - `includes = Some(list)`: copy *only* the whitelisted entries (files or
///     dirs) that exist under `src`.
pub fn copy_folder(
    src: &Path,
    dst: &Path,
    includes: Option<&[String]>,
    ignore: Option<&std::collections::HashSet<String>>,
) -> anyhow::Result<()> {
    remove(dst)?;
    match includes {
        None => {
            if let Some(parent) = dst.parent() {
                std::fs::create_dir_all(parent)?;
            }
            copy_tree(src, dst, ignore)?;
        }
        Some(list) => {
            std::fs::create_dir_all(dst)?;
            for entry in list {
                let s = src.join(entry);
                let meta = std::fs::symlink_metadata(&s);
                if meta.is_err() {
                    continue;
                }
                let t = dst.join(entry);
                if let Some(parent) = t.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                copy_entry(&s, &t, None)?;
            }
        }
    }
    Ok(())
}

/// Copy a single entry (dir tree or file), preserving symlinks. Mirrors `_copy_any`.
pub fn copy_any(src: &Path, dst: &Path) -> anyhow::Result<()> {
    let meta = std::fs::symlink_metadata(src)?;
    if meta.is_dir() && !meta.file_type().is_symlink() {
        copy_tree(src, dst, None)?;
    } else {
        if let Some(parent) = dst.parent() {
            std::fs::create_dir_all(parent)?;
        }
        copy_entry(src, dst, None)?;
    }
    Ok(())
}

/// Recursively merge-copy `src` into `dst`, creating dirs as needed, overwriting
/// files, and recreating symlinks. Mirrors `shutil.copytree(..., dirs_exist_ok=True)`.
fn merge_copy_tree(src: &Path, dst: &Path) -> anyhow::Result<()> {
    std::fs::create_dir_all(dst)?;
    for entry in std::fs::read_dir(src)? {
        let entry = entry?;
        let name = entry.file_name();
        let s = entry.path();
        let d = dst.join(&name);
        let meta = std::fs::symlink_metadata(&s)?;
        if meta.file_type().is_symlink() {
            let _ = remove(&d);
            let target = std::fs::read_link(&s)?;
            std::os::unix::fs::symlink(target, &d)?;
        } else if meta.is_dir() {
            merge_copy_tree(&s, &d)?;
        } else {
            std::fs::copy(&s, &d)?;
        }
    }
    Ok(())
}

/// Move this host's declared override paths out of the shared `profiles/<key>` copy
/// into `profiles/hosts/<hostname>/<key>/…`. Mirrors `relocate_overrides`.
pub fn relocate_overrides(
    paths: &Paths,
    key: &str,
    hostname: &str,
    overrides: &HashMap<String, Vec<String>>,
) {
    let Some(rels) = overrides.get(key) else {
        return;
    };
    for rel in rels {
        let shared = paths.profiles_dir.join(key).join(rel);
        if std::fs::symlink_metadata(&shared).is_err() {
            continue;
        }
        let hdst = paths.hosts_dir.join(hostname).join(key).join(rel);
        let _ = remove(&hdst);
        if let Some(parent) = hdst.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if std::fs::rename(&shared, &hdst).is_ok() {
            println!("  host {}", ui::magenta(&format!("{key}/{rel} -> hosts/{hostname}")));
        }
    }
}

/// Apply one profile key into `~`: back up any existing target to
/// `<name>.bak-<ts>`, copy the shared `profiles/<key>`, overlay
/// `profiles/hosts/<hostname>/<key>` on top, then for declared override paths with
/// no host copy, keep the local copy from the just-made backup (warning when
/// neither exists). Mirrors `apply_key`.
pub fn apply_key(
    paths: &Paths,
    key: &str,
    ts: &str,
    overrides: &HashMap<String, Vec<String>>,
    hostname: &str,
) {
    let src = paths.profiles_dir.join(key);
    if !src.exists() {
        println!("{}", ui::red(&format!("Missing {}, skipping.", src.display())));
        return;
    }

    let dst = paths.home.join(key);
    let mut bak: Option<std::path::PathBuf> = None;
    if dst.exists() || std::fs::symlink_metadata(&dst).is_ok() {
        let name = dst
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let b = dst.with_file_name(format!("{name}.bak-{ts}"));
        if std::fs::rename(&dst, &b).is_ok() {
            println!(
                "  backup {}",
                ui::dim(&format!("{key} -> {}", b.file_name().unwrap().to_string_lossy()))
            );
            bak = Some(b);
        }
    }

    if let Some(parent) = dst.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if copy_any(&src, &dst).is_err() {
        return;
    }

    let overlay = paths.hosts_dir.join(hostname).join(key);
    if overlay.is_dir() {
        let _ = merge_copy_tree(&overlay, &dst);
    }

    if let Some(rels) = overrides.get(key) {
        for rel in rels {
            let t = dst.join(rel);
            if std::fs::symlink_metadata(&t).is_ok() {
                continue;
            }
            let b = bak.as_ref().map(|b| b.join(rel));
            let has_local = b
                .as_ref()
                .map(|b| std::fs::symlink_metadata(b).is_ok())
                .unwrap_or(false);
            if has_local {
                let b = b.unwrap();
                if copy_any(&b, &t).is_ok() {
                    println!(
                        "  kept local {} (no override for {hostname})",
                        ui::yellow(&format!("{key}/{rel}"))
                    );
                }
            } else {
                println!(
                    "{}",
                    ui::yellow(&format!(
                        "  warning: {key}/{rel} has no override for {hostname} and no local copy — configure it and sync"
                    ))
                );
            }
        }
    }

    println!("  applied {}", ui::cyan(key));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn copy_folder_preserves_symlinks_and_subdirs() {
        let tmp = std::env::temp_dir().join(format!("copytest-{}", std::process::id()));
        let src = tmp.join("src");
        let dst = tmp.join("dst");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(src.join("sub")).unwrap();
        fs::write(src.join("file.txt"), b"hello").unwrap();
        fs::write(src.join("sub").join("inner.txt"), b"inner").unwrap();
        std::os::unix::fs::symlink("file.txt", src.join("link")).unwrap();

        copy_folder(&src, &dst, None, None).unwrap();

        assert_eq!(fs::read(dst.join("file.txt")).unwrap(), b"hello");
        assert_eq!(fs::read(dst.join("sub").join("inner.txt")).unwrap(), b"inner");
        let link_meta = fs::symlink_metadata(dst.join("link")).unwrap();
        assert!(link_meta.file_type().is_symlink());
        assert_eq!(fs::read_link(dst.join("link")).unwrap(), Path::new("file.txt"));

        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn copy_folder_includes_whitelist() {
        let tmp = std::env::temp_dir().join(format!("copytest-inc-{}", std::process::id()));
        let src = tmp.join("src");
        let dst = tmp.join("dst");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("a.txt"), b"a").unwrap();
        fs::write(src.join("b.txt"), b"b").unwrap();

        let includes = vec!["a.txt".to_string()];
        copy_folder(&src, &dst, Some(&includes), None).unwrap();

        assert!(dst.join("a.txt").exists());
        assert!(!dst.join("b.txt").exists());

        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn copy_folder_ignore_skips_named_entry() {
        let tmp = std::env::temp_dir().join(format!("copytest-ign-{}", std::process::id()));
        let src = tmp.join("src");
        let dst = tmp.join("dst");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&src).unwrap();
        fs::write(src.join("keep.txt"), b"keep").unwrap();
        fs::write(src.join("skip.txt"), b"skip").unwrap();

        let mut ignore = HashSet::new();
        ignore.insert("skip.txt".to_string());
        copy_folder(&src, &dst, None, Some(&ignore)).unwrap();

        assert!(dst.join("keep.txt").exists());
        assert!(!dst.join("skip.txt").exists());

        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn remove_symlink_to_dir_does_not_delete_target() {
        let tmp = std::env::temp_dir().join(format!("copytest-rm-{}", std::process::id()));
        let target = tmp.join("target");
        let link = tmp.join("link");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&target).unwrap();
        fs::write(target.join("f.txt"), b"data").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        remove(&link).unwrap();

        assert!(fs::symlink_metadata(&link).is_err());
        assert!(target.join("f.txt").exists());

        fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn remove_real_dir_deletes_contents() {
        let tmp = std::env::temp_dir().join(format!("copytest-rmdir-{}", std::process::id()));
        let dir = tmp.join("dir");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("f.txt"), b"data").unwrap();

        remove(&dir).unwrap();

        assert!(!dir.exists());

        fs::remove_dir_all(&tmp).unwrap();
    }
}
