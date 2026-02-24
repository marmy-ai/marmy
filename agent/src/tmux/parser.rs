use super::types::{CommandResult, TmuxEvent};

/// Parser state machine for tmux control mode protocol.
///
/// Protocol overview:
/// - Lines starting with `%` outside of response blocks are async notifications.
/// - `%begin <timestamp> <cmd_number>` starts a command response block.
/// - `%end <timestamp> <cmd_number>` ends a successful response block.
/// - `%error <timestamp> <cmd_number>` ends a failed response block.
/// - Lines inside a response block are command output.
pub struct ControlParser {
    state: ParserState,
    response_lines: Vec<String>,
    response_cmd_num: u64,
}

enum ParserState {
    Ready,
    InResponse,
}

pub enum ParsedLine {
    Event(TmuxEvent),
    CommandResponse { cmd_num: u64, result: CommandResult },
    /// Not a complete event yet (partial response block).
    Partial,
}

impl ControlParser {
    pub fn new() -> Self {
        Self {
            state: ParserState::Ready,
            response_lines: Vec::new(),
            response_cmd_num: 0,
        }
    }

    /// Feed a single line from tmux control mode stdout.
    pub fn parse_line(&mut self, line: &str) -> ParsedLine {
        match &self.state {
            ParserState::Ready => {
                if let Some(rest) = line.strip_prefix("%begin ") {
                    if let Some(cmd_num) = parse_block_header(rest) {
                        self.state = ParserState::InResponse;
                        self.response_lines.clear();
                        self.response_cmd_num = cmd_num;
                        return ParsedLine::Partial;
                    }
                }

                if let Some(event) = parse_notification(line) {
                    ParsedLine::Event(event)
                } else {
                    ParsedLine::Partial
                }
            }
            ParserState::InResponse => {
                if let Some(rest) = line.strip_prefix("%end ") {
                    if let Some(cmd_num) = parse_block_header(rest) {
                        if cmd_num == self.response_cmd_num {
                            self.state = ParserState::Ready;
                            let result = CommandResult {
                                success: true,
                                lines: std::mem::take(&mut self.response_lines),
                            };
                            return ParsedLine::CommandResponse {
                                cmd_num,
                                result,
                            };
                        }
                    }
                } else if let Some(rest) = line.strip_prefix("%error ") {
                    if let Some(cmd_num) = parse_block_header(rest) {
                        if cmd_num == self.response_cmd_num {
                            self.state = ParserState::Ready;
                            let result = CommandResult {
                                success: false,
                                lines: std::mem::take(&mut self.response_lines),
                            };
                            return ParsedLine::CommandResponse {
                                cmd_num,
                                result,
                            };
                        }
                    }
                } else {
                    self.response_lines.push(line.to_string());
                }
                ParsedLine::Partial
            }
        }
    }
}

/// Parse the `<timestamp> <cmd_number>` from a %begin/%end/%error line.
fn parse_block_header(s: &str) -> Option<u64> {
    let parts: Vec<&str> = s.split_whitespace().collect();
    if parts.len() >= 2 {
        parts[1].parse().ok()
    } else {
        None
    }
}

/// Parse a `%` notification line into a TmuxEvent.
fn parse_notification(line: &str) -> Option<TmuxEvent> {
    if let Some(rest) = line.strip_prefix("%output ") {
        // Format: %output %<pane_id> <octal-escaped-data>
        let (pane_id, data) = split_first_space(rest)?;
        let data = unescape_tmux_output(data);
        return Some(TmuxEvent::Output {
            pane_id: pane_id.to_string(),
            data,
        });
    }

    if let Some(rest) = line.strip_prefix("%window-add ") {
        return Some(TmuxEvent::WindowAdd {
            window_id: rest.trim().to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%window-close ") {
        return Some(TmuxEvent::WindowClose {
            window_id: rest.trim().to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%window-renamed ") {
        let (window_id, name) = split_first_space(rest)?;
        return Some(TmuxEvent::WindowRenamed {
            window_id: window_id.to_string(),
            name: name.to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%session-changed ") {
        let (session_id, name) = split_first_space(rest)?;
        return Some(TmuxEvent::SessionChanged {
            session_id: session_id.to_string(),
            name: name.to_string(),
        });
    }

    if line.starts_with("%sessions-changed") {
        return Some(TmuxEvent::SessionsChanged);
    }

    if let Some(rest) = line.strip_prefix("%session-renamed ") {
        let (session_id, name) = split_first_space(rest)?;
        return Some(TmuxEvent::SessionRenamed {
            session_id: session_id.to_string(),
            name: name.to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%session-window-changed ") {
        let (session_id, window_id) = split_first_space(rest)?;
        return Some(TmuxEvent::SessionWindowChanged {
            session_id: session_id.to_string(),
            window_id: window_id.to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%layout-change ") {
        let (window_id, layout) = split_first_space(rest)?;
        return Some(TmuxEvent::LayoutChange {
            window_id: window_id.to_string(),
            layout: layout.to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%pane-mode-changed ") {
        return Some(TmuxEvent::PaneModeChanged {
            pane_id: rest.trim().to_string(),
        });
    }

    if let Some(rest) = line.strip_prefix("%exit") {
        return Some(TmuxEvent::Exit {
            reason: rest.trim().to_string(),
        });
    }

    None
}

/// Unescape tmux control mode octal-escaped output.
/// Characters < ASCII 32 and backslash are escaped as \NNN (3-digit octal).
/// e.g. \012 = newline, \134 = backslash.
fn unescape_tmux_output(s: &str) -> Vec<u8> {
    let mut result = Vec::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 3 < bytes.len() {
            // Try to parse 3-digit octal escape
            let d1 = bytes[i + 1].wrapping_sub(b'0');
            let d2 = bytes[i + 2].wrapping_sub(b'0');
            let d3 = bytes[i + 3].wrapping_sub(b'0');

            if d1 < 8 && d2 < 8 && d3 < 8 {
                let val = d1 * 64 + d2 * 8 + d3;
                result.push(val);
                i += 4;
                continue;
            }
        }
        result.push(bytes[i]);
        i += 1;
    }

    result
}

/// Split a string at the first space.
fn split_first_space(s: &str) -> Option<(&str, &str)> {
    let s = s.trim();
    let idx = s.find(' ')?;
    Some((&s[..idx], &s[idx + 1..]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unescape_basic() {
        let input = "hello\\012world";
        let result = unescape_tmux_output(input);
        assert_eq!(result, b"hello\nworld");
    }

    #[test]
    fn test_unescape_backslash() {
        let input = "path\\134file";
        let result = unescape_tmux_output(input);
        assert_eq!(result, b"path\\file");
    }

    #[test]
    fn test_parse_output_notification() {
        let line = "%output %3 hello\\012world";
        let event = parse_notification(line).unwrap();
        match event {
            TmuxEvent::Output { pane_id, data } => {
                assert_eq!(pane_id, "%3");
                assert_eq!(data, b"hello\nworld");
            }
            _ => panic!("expected Output event"),
        }
    }

    #[test]
    fn test_parse_window_add() {
        let line = "%window-add @1";
        let event = parse_notification(line).unwrap();
        match event {
            TmuxEvent::WindowAdd { window_id } => {
                assert_eq!(window_id, "@1");
            }
            _ => panic!("expected WindowAdd event"),
        }
    }

    #[test]
    fn test_parser_command_response() {
        let mut parser = ControlParser::new();

        assert!(matches!(
            parser.parse_line("%begin 1700000000 1"),
            ParsedLine::Partial
        ));
        assert!(matches!(
            parser.parse_line("session_name: dev"),
            ParsedLine::Partial
        ));
        match parser.parse_line("%end 1700000000 1") {
            ParsedLine::CommandResponse { cmd_num, result } => {
                assert_eq!(cmd_num, 1);
                assert!(result.success);
                assert_eq!(result.lines, vec!["session_name: dev"]);
            }
            _ => panic!("expected CommandResponse"),
        }
    }
}
