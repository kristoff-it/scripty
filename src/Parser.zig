const Parser = @This();

const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");

it: Tokenizer = .{},
state: State = .start,
call_depth: u32 = 0, // 0 = not in a call
previous_segment_end: u32 = 0, // used for call

const State = enum {
    start,
    global,
    extend_path,
    call_begin,
    call_arg,
    extend_call,
    call_end,
    after_call,

    // Error state
    syntax,
};

pub const Node = struct {
    tag: Tag,
    loc: Tokenizer.Token.Loc,

    pub const Tag = enum {
        path,
        call,
        apply,
        true,
        false,
        string,
        number,
        syntax_error,
    };
};

pub fn next(p: *Parser, code: []const u8) ?Node {
    if (p.it.idx == code.len) {
        const in_terminal_state = (p.state == .after_call or
            p.state == .extend_path);
        if (in_terminal_state) return null;
        return p.syntaxError(.{
            .start = p.it.idx,
            .end = p.it.idx,
        });
    }
    var path: Node = .{
        .tag = .path,
        .loc = undefined,
    };

    var path_starts_at_global = false;
    var dotted_path = false;

    while (p.it.next(code)) |tok| switch (p.state) {
        .syntax => unreachable,
        .start => switch (tok.tag) {
            .dollar => {
                p.state = .global;
                path.loc = tok.loc;
            },
            else => {
                return p.syntaxError(tok.loc);
            },
        },
        .global => switch (tok.tag) {
            .identifier => {
                p.state = .extend_path;
                path.loc.end = tok.loc.end;
                path_starts_at_global = true;
            },
            else => return p.syntaxError(tok.loc),
        },
        .extend_path => switch (tok.tag) {
            .dot => {
                const id_tok = p.it.next(code);
                if (id_tok == null or id_tok.?.tag != .identifier) {
                    return p.syntaxError(tok.loc);
                }

                // we can also get here from 'after call', eg:
                //   $foo.bar().baz()
                //   ----------^
                // everything before the dot has already
                // been returned as a node

                p.previous_segment_end = tok.loc.end;
                path.loc.end = id_tok.?.loc.end;
                dotted_path = true;
            },
            .lparen => {
                if (path_starts_at_global and !dotted_path) {
                    return p.syntaxError(tok.loc);
                }

                // rewind to get a a lparen
                p.it.idx -= 1;
                p.state = .call_begin;

                if (dotted_path) {
                    // return the collected path up to the
                    // previous segment, as the current one
                    // will become part of a 'call' node
                    path.loc.end = p.previous_segment_end;
                    return path;
                }
            },
            .rparen => {
                p.state = .call_end;
                // roll back to get a rparen token next
                p.it.idx -= 1;
                return path;
            },
            .comma => {
                p.state = .call_arg;
                if (p.call_depth == 0) {
                    return p.syntaxError(tok.loc);
                }
                return path;
            },
            else => return p.syntaxError(tok.loc),
        },
        .call_begin => {
            p.call_depth += 1;
            switch (tok.tag) {
                .lparen => {
                    p.state = .call_arg;
                    return .{
                        .tag = .call,
                        .loc = .{
                            .start = p.previous_segment_end,
                            .end = tok.loc.start,
                        },
                    };
                },
                else => unreachable,
            }
        },
        .call_arg => switch (tok.tag) {
            .dollar => {
                p.state = .global;
                path.loc = tok.loc;
            },
            .rparen => {
                // rollback to get a rparen next
                p.it.idx -= 1;
                p.state = .call_end;
            },
            .identifier => {
                p.state = .extend_call;
                const src = tok.loc.slice(code);
                if (std.mem.eql(u8, "true", src)) {
                    return .{ .tag = .true, .loc = tok.loc };
                } else if (std.mem.eql(u8, "false", src)) {
                    return .{ .tag = .false, .loc = tok.loc };
                } else {
                    return p.syntaxError(tok.loc);
                }
            },
            .string => {
                p.state = .extend_call;
                return .{ .tag = .string, .loc = tok.loc };
            },
            .number => {
                p.state = .extend_call;
                return .{ .tag = .number, .loc = tok.loc };
            },
            else => return p.syntaxError(tok.loc),
        },
        .extend_call => switch (tok.tag) {
            .comma => p.state = .call_arg,
            .rparen => {
                // rewind to get a .rparen next call
                p.it.idx -= 1;
                p.state = .call_end;
            },
            else => return p.syntaxError(tok.loc),
        },
        .call_end => {
            if (p.call_depth == 0) {
                return p.syntaxError(tok.loc);
            }
            p.call_depth -= 1;
            p.state = .after_call;
            return .{ .tag = .apply, .loc = tok.loc };
        },
        .after_call => switch (tok.tag) {
            .dot => {
                const id_tok = p.it.next(code);
                if (id_tok == null or id_tok.?.tag != .identifier) {
                    return p.syntaxError(tok.loc);
                }

                p.state = .extend_path;
                p.previous_segment_end = tok.loc.end;
                path.loc = id_tok.?.loc;
            },
            .comma => {
                p.state = .call_arg;
            },
            .rparen => {
                // rewind to get a .rparen next
                p.it.idx -= 1;
                p.state = .call_end;
            },
            else => return p.syntaxError(tok.loc),
        },
    };

    const in_terminal_state = (p.state == .after_call or
        p.state == .extend_path);

    const code_len: u32 = @intCast(code.len);
    if (p.call_depth > 0 or !in_terminal_state) {
        return p.syntaxError(.{
            .start = code_len - 1,
            .end = code_len,
        });
    }

    path.loc.end = code_len;
    if (path.loc.len() == 0) return null;
    return path;
}

fn syntaxError(p: *Parser, loc: Tokenizer.Token.Loc) Node {
    p.state = .syntax;
    return .{ .tag = .syntax_error, .loc = loc };
}

test "basics" {
    const case = "$page.has('a', $page.title.slice(0, 4), 'b').foo.not()";
    const expected: []const Node.Tag = &.{
        .path,
        .call,
        .string,
        .path,
        .call,
        .number,
        .number,
        .apply,
        .string,
        .apply,
        .path,
        .call,
        .apply,
    };

    var p: Parser = .{};

    for (expected) |ex| {
        const actual = p.next(case).?;
        try std.testing.expectEqual(ex, actual.tag);
    }
    try std.testing.expectEqual(@as(?Node, null), p.next(case));
}

test "basics 2" {
    const case = "$page.call('banana')";
    const expected: []const Node.Tag = &.{
        .path,
        .call,
        .string,
        .apply,
    };

    var p: Parser = .{};

    for (expected) |ex| {
        try std.testing.expectEqual(ex, p.next(case).?.tag);
    }
    try std.testing.expectEqual(@as(?Node, null), p.next(case));
}
test "method chain" {
    const case = "$page.permalink().endsWith('/posts/').then('x', '')";
    const expected: []const Node.Tag = &.{
        .path,  .call, .apply,  .call,   .string,
        .apply, .call, .string, .string, .apply,
    };

    var p: Parser = .{};

    for (expected) |ex| {
        try std.testing.expectEqual(ex, p.next(case).?.tag);
    }
    try std.testing.expectEqual(@as(?Node, null), p.next(case));
}

test "dot after call" {
    const case = "$page.locale!('en-US').custom";
    const expected: []const Node.Tag = &.{
        .path, .call, .string, .apply,
        .path,
    };

    var p: Parser = .{};

    for (expected) |ex| {
        try std.testing.expectEqual(ex, p.next(case).?.tag);
    }
    try std.testing.expectEqual(@as(?Node, null), p.next(case));
}
