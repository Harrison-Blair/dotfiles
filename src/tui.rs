//! The hand-drawn interactive UI: a crossterm raw-mode key loop over a transient,
//! redraw-on-keypress render. Mirrors the Python Rich-`Live` + raw-key selection.
//!
//! PHASE 3 owns this file. Signatures below are frozen so `commands.rs`/`main.rs`
//! can call them.
//!
//! Keys: ↑/↓ + j/k move (wrap), space toggle, `a` toggle-all, enter confirm,
//! q/Q/Esc cancel; digits jump in the menu. Non-TTY → return None (caller prints
//! the "requires an interactive terminal" message). crossterm delivers a bare Esc
//! KeyEvent directly, so no escape-timeout hack is needed.

use std::collections::HashMap;
use std::io::{stdin, stdout, IsTerminal, Stdout, Write};

use crossterm::cursor::{MoveToColumn, MoveUp};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, size, Clear, ClearType};
use crossterm::queue;

use crate::model::Node;
use crate::tree::{config_whole, effective_selection};

/// A recognized keypress; anything else is ignored by the read loop.
enum Key {
    Up,
    Down,
    Space,
    Enter,
    Quit,
    All,
    Digit(u32),
}

/// Transient in-place raw-mode redraw surface, mirroring Rich `Live(transient=True)`.
struct Screen {
    out: Stdout,
    drawn: u16,
}

impl Screen {
    fn new() -> std::io::Result<Self> {
        enable_raw_mode()?;
        Ok(Screen {
            out: stdout(),
            drawn: 0,
        })
    }

    fn draw(&mut self, block: &str) -> std::io::Result<()> {
        let lines: Vec<&str> = block.split('\n').collect();
        if self.drawn > 0 {
            queue!(self.out, MoveUp(self.drawn), MoveToColumn(0))?;
        } else {
            queue!(self.out, MoveToColumn(0))?;
        }
        queue!(self.out, Clear(ClearType::FromCursorDown))?;
        write!(self.out, "{}", lines.join("\r\n"))?;
        self.out.flush()?;
        self.drawn = lines.len().saturating_sub(1) as u16;
        Ok(())
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        if self.drawn > 0 {
            let _ = queue!(self.out, MoveUp(self.drawn), MoveToColumn(0));
        } else {
            let _ = queue!(self.out, MoveToColumn(0));
        }
        let _ = queue!(self.out, Clear(ClearType::FromCursorDown));
        let _ = self.out.flush();
        let _ = disable_raw_mode();
    }
}

/// Block until a recognized key is pressed; unrecognized keys/events are skipped.
fn read_key() -> Key {
    loop {
        let Ok(Event::Key(ke)) = event::read() else {
            continue;
        };
        if ke.kind == KeyEventKind::Release {
            continue;
        }
        if ke.modifiers.contains(KeyModifiers::CONTROL) && ke.code == KeyCode::Char('c') {
            return Key::Quit;
        }
        match ke.code {
            KeyCode::Up => return Key::Up,
            KeyCode::Down => return Key::Down,
            KeyCode::Char('k') => return Key::Up,
            KeyCode::Char('j') => return Key::Down,
            KeyCode::Char(' ') => return Key::Space,
            KeyCode::Enter => return Key::Enter,
            KeyCode::Esc => return Key::Quit,
            KeyCode::Char('q') | KeyCode::Char('Q') => return Key::Quit,
            KeyCode::Char('a') | KeyCode::Char('A') => return Key::All,
            KeyCode::Char(c) if c.is_ascii_digit() => return Key::Digit(c.to_digit(10).unwrap()),
            _ => continue,
        }
    }
}

/// Center `s` in a `width`-wide field, matching Python's `f"{s:^width}"`.
fn center(s: &str, width: usize) -> String {
    let len = s.chars().count();
    if len >= width {
        return s.to_string();
    }
    let pad = width - len;
    let left = pad / 2;
    let right = pad - left;
    format!("{}{}{}", " ".repeat(left), s, " ".repeat(right))
}

/// A 45-wide boxed title; optional italic description below, then a blank line.
fn box_header(title: &str, description: Option<&str>) -> Vec<String> {
    let mut lines = Vec::new();
    lines.push(ui::dim(&"-".repeat(45)));
    lines.push(format!(
        "{}{}{}",
        ui::dim("---- "),
        ui::bold(&center(title, 35)),
        ui::dim(" ----")
    ));
    lines.push(ui::dim(&"-".repeat(45)));
    if let Some(d) = description {
        lines.push(ui::italic(d));
    }
    lines.push(String::new());
    lines
}

use crate::ui;

/// Sticky scroll: return the new top-of-window index keeping cursor visible.
fn scroll_top(total: usize, cursor: usize, top: usize, height: usize) -> usize {
    if total <= height {
        return 0;
    }
    let mut top = top;
    if cursor < top {
        top = cursor;
    } else if cursor >= top + height {
        top = cursor - height + 1;
    }
    top.min(total - height)
}

/// Rows available for list items: terminal height minus header, footer, and the
/// two lines reserved for the scroll indicators.
fn checklist_height(description: Option<&str>) -> usize {
    let header = if description.is_some() { 5 } else { 4 };
    let rows = size().map(|(_, r)| r as usize).unwrap_or(24);
    std::cmp::max(1, rows.saturating_sub(header + 2 + 2))
}

#[allow(clippy::too_many_arguments)]
fn render_checklist(
    nodes: &[Node],
    cursor: usize,
    top: usize,
    height: usize,
    title: &str,
    info: Option<&HashMap<String, String>>,
    description: Option<&str>,
) -> String {
    let whole = config_whole(nodes);
    let mut lines = box_header(title, description);
    let end = std::cmp::min(top + height, nodes.len());
    if top > 0 {
        lines.push(ui::dim(&format!("   ↑ {top} more")));
    }
    for (i, n) in nodes.iter().enumerate().take(end).skip(top) {
        let implied = n.parent_key.as_deref() == Some(".config") && whole;
        let glyph = if implied {
            "[-]"
        } else if n.checked {
            "[x]"
        } else {
            "[ ]"
        };
        let label = if n.is_parent && n.key == ".config" {
            format!("{}  (whole folder)", n.label)
        } else {
            n.label.clone()
        };
        let pointer = if i == cursor { ">" } else { " " };
        let main = format!("{pointer} {}{glyph} {label}", "  ".repeat(n.depth));
        let mut styled = if i == cursor {
            ui::reverse(&main)
        } else if implied {
            ui::dim(&main)
        } else {
            main
        };
        if let Some(info_map) = info {
            if let Some(v) = info_map.get(&n.key) {
                styled.push_str(&ui::dim(&format!("  — {v}")));
            }
        }
        lines.push(styled);
    }
    if end < nodes.len() {
        lines.push(ui::dim(&format!("   ↓ {} more", nodes.len() - end)));
    }
    lines.push(String::new());
    let count = effective_selection(nodes).len();
    lines.push(ui::dim(&format!(
        "{count} selected · ↑/↓ move · space toggle · a all · enter confirm · q cancel"
    )));
    lines.join("\n")
}

fn render_menu(
    options: &[(String, String)],
    cursor: usize,
    title: &str,
    description: Option<&str>,
) -> String {
    let mut lines = box_header(title, description);
    for (i, (key, label)) in options.iter().enumerate() {
        if key == "quit" {
            lines.push(String::new());
        }
        let pointer = if i == cursor { ">" } else { " " };
        let main = format!("{pointer} {}. {label}", i + 1);
        lines.push(if i == cursor { ui::reverse(&main) } else { main });
    }
    lines.push(String::new());
    lines.push(ui::dim(&format!(
        "↑/↓ move · 1-{} jump · enter select · q quit",
        options.len()
    )));
    lines.join("\n")
}

/// Flip the checked state of `nodes[idx]`, unless it's a `.config` child whose
/// parent is checked whole (children are implied while the parent is checked).
fn toggle(nodes: &mut [Node], idx: usize) {
    if nodes[idx].parent_key.as_deref() == Some(".config") && config_whole(nodes) {
        return;
    }
    nodes[idx].checked = !nodes[idx].checked;
}

fn tty_ready() -> bool {
    stdin().is_terminal() && stdout().is_terminal()
}

/// Interactive checkbox list. `Some(nodes)` with the final checked state on
/// confirm, `None` on cancel (or non-TTY). `info` annotates rows by key;
/// `description` is an optional italic subtitle. An empty `nodes` returns
/// `Some(vec![])` without entering the loop.
pub fn interactive_select(
    mut nodes: Vec<Node>,
    title: &str,
    info: Option<&HashMap<String, String>>,
    description: Option<&str>,
) -> Option<Vec<Node>> {
    if nodes.is_empty() {
        return Some(vec![]);
    }
    if !tty_ready() {
        return None;
    }

    let mut cursor = 0usize;
    let mut top = 0usize;
    let confirmed;
    {
        let mut screen = match Screen::new() {
            Ok(s) => s,
            Err(_) => return None,
        };
        loop {
            let height = checklist_height(description);
            top = scroll_top(nodes.len(), cursor, top, height);
            let block = render_checklist(&nodes, cursor, top, height, title, info, description);
            if screen.draw(&block).is_err() {
                confirmed = false;
                break;
            }
            match read_key() {
                Key::Up => cursor = (cursor + nodes.len() - 1) % nodes.len(),
                Key::Down => cursor = (cursor + 1) % nodes.len(),
                Key::Space => toggle(&mut nodes, cursor),
                Key::All => {
                    let val = nodes.iter().any(|n| !n.checked);
                    for n in &mut nodes {
                        n.checked = val;
                    }
                }
                Key::Enter => {
                    confirmed = true;
                    break;
                }
                Key::Quit => {
                    confirmed = false;
                    break;
                }
                Key::Digit(_) => {}
            }
        }
    }
    if confirmed {
        Some(nodes)
    } else {
        None
    }
}

/// Interactive single-choice menu over `(key, label)` options. Returns the chosen
/// key, or `None` on cancel / non-TTY.
pub fn menu_select(
    title: &str,
    options: &[(String, String)],
    description: Option<&str>,
) -> Option<String> {
    if !tty_ready() {
        return None;
    }

    let mut cursor = 0usize;
    let confirmed;
    {
        let mut screen = match Screen::new() {
            Ok(s) => s,
            Err(_) => return None,
        };
        loop {
            let block = render_menu(options, cursor, title, description);
            if screen.draw(&block).is_err() {
                confirmed = false;
                break;
            }
            match read_key() {
                Key::Up => cursor = (cursor + options.len() - 1) % options.len(),
                Key::Down => cursor = (cursor + 1) % options.len(),
                Key::Digit(d) => {
                    let idx = d as usize - 1;
                    if idx < options.len() {
                        cursor = idx;
                        confirmed = true;
                        break;
                    }
                }
                Key::Enter => {
                    confirmed = true;
                    break;
                }
                Key::Quit => {
                    confirmed = false;
                    break;
                }
                Key::Space | Key::All => {}
            }
        }
    }
    if confirmed {
        Some(options[cursor].0.clone())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scroll_top_fits_within_height() {
        assert_eq!(scroll_top(5, 2, 0, 10), 0);
    }

    #[test]
    fn scroll_top_cursor_above_window_pulls_top_down() {
        assert_eq!(scroll_top(20, 3, 5, 5), 3);
    }

    #[test]
    fn scroll_top_cursor_below_window_pushes_top() {
        // total=20, height=5, cursor=12, top=0 -> cursor >= top+height so top = 12-5+1 = 8
        assert_eq!(scroll_top(20, 12, 0, 5), 8);
    }

    #[test]
    fn scroll_top_clamps_at_end() {
        // top would be pushed past total-height; clamp to total-height.
        assert_eq!(scroll_top(20, 19, 0, 5), 15);
    }

    #[test]
    fn center_even_padding() {
        assert_eq!(center("ab", 6), "  ab  ");
    }

    #[test]
    fn center_odd_padding() {
        assert_eq!(center("ab", 5), " ab  ");
    }

    #[test]
    fn center_no_pad_when_len_ge_width() {
        assert_eq!(center("abcdef", 4), "abcdef");
    }
}
