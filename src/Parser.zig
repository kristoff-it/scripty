const Parser = @This();

const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");

it: Tokenizer = .{},
state: State = .start,
call_depth: u32 = 0, // 0 = not in a call
last_path_end: u32 = 0, // used for call

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
    var path: Node = .{
        .tag = .path,
        .loc = undefined,
    };

    var path_segments: u32 = 0;

    // if (p.call_depth == 1) @breakpoint();

    while (p.it.next(code)) |tok| switch (p.state) {
        .syntax => unreachable,
        .start => switch (tok.tag) {
            .dollar => {
                p.state = .global;
                path.loc = tok.loc;
            },
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
        .global => switch (tok.tag) {
            .identifier => {
                p.state = .extend_path;
                path_segments = 1;
                path.loc.end = tok.loc.end;
            },
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
        .extend_path => switch (tok.tag) {
            .dot => {
                const id_tok = p.it.next(code);
                if (id_tok == null or id_tok.?.tag != .identifier) {
                    p.state = .syntax;
                    return .{ .tag = .syntax_error, .loc = tok.loc };
                }

                if (path_segments == 0) {
                    path.loc = id_tok.?.loc;
                } else {
                    p.last_path_end = path.loc.end;
                    path.loc.end = id_tok.?.loc.end;
                }

                path_segments += 1;
            },
            .lparen => {
                if (path_segments < 2) {
                    p.state = .syntax;
                    return .{ .tag = .syntax_error, .loc = tok.loc };
                }

                // rewind to get a a lparen
                p.it.idx -= 1;
                p.state = .call_begin;
                if (path_segments > 1) {
                    path.loc.end = p.last_path_end;
                    return path;
                } else {
                    // self.last_path_end = path.loc.start - 1; // TODO: check tha this is correct
                }
            },
            .rparen => {
                p.state = .call_end;
                // roll back to get a rparen token next
                p.it.idx -= 1;
                if (path_segments == 0) {
                    p.state = .syntax;
                    return .{ .tag = .syntax_error, .loc = tok.loc };
                }
                return path;
            },
            .comma => {
                p.state = .call_arg;
                if (p.call_depth == 0) {
                    p.state = .syntax;
                    return .{ .tag = .syntax_error, .loc = tok.loc };
                }
                return path;
            },
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
        .call_begin => {
            p.call_depth += 1;
            switch (tok.tag) {
                .lparen => {
                    p.state = .call_arg;
                    return .{
                        .tag = .call,
                        .loc = .{
                            .start = p.last_path_end + 1,
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
                const src = tok.loc.src(code);
                if (std.mem.eql(u8, "true", src)) {
                    return .{ .tag = .true, .loc = tok.loc };
                } else if (std.mem.eql(u8, "false", src)) {
                    return .{ .tag = .false, .loc = tok.loc };
                } else {
                    p.state = .syntax;
                    return .{ .tag = .syntax_error, .loc = tok.loc };
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
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
        .extend_call => switch (tok.tag) {
            .comma => p.state = .call_arg,
            .rparen => {
                // rewind to get a .rparen next call
                p.it.idx -= 1;
                p.state = .call_end;
            },
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
        .call_end => {
            if (p.call_depth == 0) {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            }
            p.call_depth -= 1;
            p.state = .after_call;
            return .{ .tag = .apply, .loc = tok.loc };
        },
        .after_call => switch (tok.tag) {
            .dot => {
                // rewind to get a .dot next
                p.it.idx -= 1;
                p.last_path_end = tok.loc.start;
                p.state = .extend_path;
            },
            .comma => {
                p.state = .call_arg;
            },
            .rparen => {
                // rewind to get a .rparen next
                p.it.idx -= 1;
                p.state = .call_end;
            },
            else => {
                p.state = .syntax;
                return .{ .tag = .syntax_error, .loc = tok.loc };
            },
        },
    };

    const not_good_state = (p.state != .after_call and
        p.state != .extend_path);

    const code_len: u32 = @intCast(code.len);
    if (p.call_depth > 0 or not_good_state) {
        p.state = .syntax;
        return .{
            .tag = .syntax_error,
            .loc = .{ .start = code_len - 1, .end = code_len },
        };
    }

    if (path_segments == 0) return null;
    path.loc.end = code_len;
    return path;
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
