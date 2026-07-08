//! Terminal styling helpers. Each function wraps text in an ANSI SGR sequence,
//! but only when stdout is a real terminal — piped output is left plain, matching
//! `rich`'s auto-detection (so non-interactive command output has no escape codes).
//!
//! Color/attribute → SGR mapping mirrors the `rich` markup used in the Python:
//! dim=2, bold=1, italic=3, reverse=7; red=31, green=32, yellow=33, magenta=35, cyan=36.

use std::io::IsTerminal;

/// Whether to emit color codes (true only when stdout is a TTY).
fn colored() -> bool {
    std::io::stdout().is_terminal()
}

fn paint(s: &str, sgr: &str) -> String {
    if colored() {
        format!("\x1b[{sgr}m{s}\x1b[0m")
    } else {
        s.to_string()
    }
}

pub fn dim(s: &str) -> String {
    paint(s, "2")
}

pub fn bold(s: &str) -> String {
    paint(s, "1")
}

pub fn italic(s: &str) -> String {
    paint(s, "3")
}

pub fn reverse(s: &str) -> String {
    paint(s, "7")
}

pub fn red(s: &str) -> String {
    paint(s, "31")
}

pub fn green(s: &str) -> String {
    paint(s, "32")
}

pub fn yellow(s: &str) -> String {
    paint(s, "33")
}

pub fn magenta(s: &str) -> String {
    paint(s, "35")
}

pub fn cyan(s: &str) -> String {
    paint(s, "36")
}
