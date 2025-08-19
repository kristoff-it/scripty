const Tokenizer = @This();

const std = @import("std");

idx: u32 = 0,

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: u32,
        end: u32,

        pub fn len(loc: Loc) u32 {
            return loc.end - loc.start;
        }

        pub fn slice(self: Loc, code: []const u8) []const u8 {
            return code[self.start..self.end];
        }

        pub fn unquote(
            self: Loc,
            gpa: std.mem.Allocator,
            code: []const u8,
        ) ![]const u8 {
            const s = code[self.start..self.end];
            const quoteless = s[1 .. s.len - 1];

            for (quoteless) |c| {
                if (c == '\\') break;
            } else {
                return quoteless;
            }

            const quote = s[0];
            var out: std.ArrayList(u8) = try .initCapacity(gpa, quoteless.len);
            var last = quote;
            var skipped = false;
            for (quoteless) |c| {
                if (c == '\\' and last == '\\' and !skipped) {
                    skipped = true;
                    last = c;
                    continue;
                }
                if (c == quote and last == '\\' and !skipped) {
                    out.items[out.items.len - 1] = quote;
                    last = c;
                    continue;
                }
                out.appendAssumeCapacity(c);
                skipped = false;
                last = c;
            }
            return try out.toOwnedSlice(gpa);
        }
    };

    pub const Tag = enum {
        invalid,
        dollar,
        dot,
        comma,
        lparen,
        rparen,
        string,
        identifier,
        number,

        pub fn lexeme(self: Tag) ?[]const u8 {
            return switch (self) {
                .invalid,
                .string,
                .identifier,
                .number,
                => null,
                .dollar => "$",
                .dot => ".",
                .comma => ",",
                .lparen => "(",
                .rparen => ")",
            };
        }
    };
};

const State = enum {
    invalid,
    start,
    identifier,
    number,
    string,
};

pub fn next(tokenizer: *Tokenizer, src: []const u8) ?Token {
    var tok: Token = .{
        .tag = .invalid,
        .loc = .{
            .start = tokenizer.idx,
            .end = undefined,
        },
    };

    state: switch (State.start) {
        .start => start: switch (tokenizer.char(src)) {
            else => continue :state .invalid,
            0 => return null,
            // Ignore reasonable whitespace
            ' ', '\n', '\t', '\r' => {
                tokenizer.idx += 1;
                tok.loc.start += 1;
                continue :start tokenizer.char(src);
            },
            'a'...'z', 'A'...'Z', '_' => {
                tokenizer.idx += 1;
                continue :state .identifier;
            },
            '"', '\'' => {
                tokenizer.idx += 1;
                continue :state .string;
            },
            '0'...'9', '-' => {
                tokenizer.idx += 1;
                continue :state .number;
            },

            '$' => {
                tokenizer.idx += 1;
                tok.tag = .dollar;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
            ',' => {
                tokenizer.idx += 1;
                tok.tag = .comma;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
            '.' => {
                tokenizer.idx += 1;
                tok.tag = .dot;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
            '(' => {
                tokenizer.idx += 1;
                tok.tag = .lparen;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
            ')' => {
                tokenizer.idx += 1;
                tok.tag = .rparen;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
        },
        .identifier => identifier: switch (tokenizer.char(src)) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => {
                tokenizer.idx += 1;
                continue :identifier tokenizer.char(src);
            },
            else => {
                tok.tag = .identifier;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
        },
        .string => string: switch (tokenizer.char(src)) {
            0 => {
                tok.tag = .invalid;
                tok.loc.end = tokenizer.idx;
                break :state;
            },

            '"', '\'' => if (src[tokenizer.idx] == src[tok.loc.start] and
                evenSlashes(src[0..tokenizer.idx]))
            {
                tokenizer.idx += 1;
                tok.tag = .string;
                tok.loc.end = tokenizer.idx;
                break :state;
            } else {
                tokenizer.idx += 1;
                continue :string tokenizer.char(src);
            },
            else => {
                tokenizer.idx += 1;
                continue :string tokenizer.char(src);
            },
        },
        .number => number: switch (tokenizer.char(src)) {
            '0'...'9', '.', '_' => {
                tokenizer.idx += 1;
                continue :number tokenizer.char(src);
            },
            else => {
                tok.tag = .number;
                tok.loc.end = tokenizer.idx;
                break :state;
            },
        },
        .invalid => invalid: switch (tokenizer.char(src)) {
            'a'...'z', 'A'...'Z', '0'...'9', '?', '!', '_' => {
                tokenizer.idx += 1;
                continue :invalid tokenizer.char(src);
            },
            else => {
                tok.loc.end = tokenizer.idx;
                break :state;
            },
        },
    }
    return tok;
}

fn char(tokenizer: Tokenizer, src: []const u8) u8 {
    return if (tokenizer.idx < src.len) src[tokenizer.idx] else 0;
}

fn evenSlashes(str: []const u8) bool {
    var i = str.len - 1;
    var even = true;
    while (true) : (i -= 1) {
        if (str[i] != '\\') break;
        even = !even;
        if (i == 0) break;
    }
    return even;
}

test "general language" {
    const Case = struct {
        code: []const u8,
        expected: []const Token.Tag,
    };
    const cases: []const Case = &.{
        .{ .code = "$page", .expected = &.{
            .dollar,
            .identifier,
        } },
        .{ .code = "$page.foo", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
        } },
        .{ .code = "$page.foo()", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
            .lparen,
            .rparen,
        } },

        .{ .code = "$page.foo.bar()", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
            .dot,
            .identifier,
            .lparen,
            .rparen,
        } },

        .{ .code = "$page(true)", .expected = &.{
            .dollar,
            .identifier,
            .lparen,
            .identifier,
            .rparen,
        } },
        .{ .code = "$page(-123.4124)", .expected = &.{
            .dollar,
            .identifier,
            .lparen,
            .number,
            .rparen,
        } },
        .{ .code = "$authors.split(1, 2, 3).not()", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
            .lparen,
            .number,
            .comma,
            .number,
            .comma,
            .number,
            .rparen,
            .dot,
            .identifier,
            .lparen,
            .rparen,
        } },
        .{ .code = "$date.asDate('iso8601')", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
            .lparen,
            .string,
            .rparen,
        } },
        // zig fmt: off
        .{ .code = "$post.draft.and($post.date.isFuture().or($post.author.is('loris-cro')))", .expected = &.{
            .dollar, .identifier, .dot, .identifier, .dot, .identifier, .lparen,
            .dollar, .identifier, .dot, .identifier, .dot, .identifier, .lparen,
            .rparen,
            .dot, .identifier, .lparen,
            .dollar, .identifier, .dot, .identifier, .dot, .identifier, .lparen,
            .string,
            .rparen,
            .rparen,
            .rparen,
        } },
        // zig fmt: on
        .{ .code = "$date.asDate('iso8601', 'b', \n 'c')", .expected = &.{
            .dollar,
            .identifier,
            .dot,
            .identifier,
            .lparen,
            .string,
            .comma,
            .string,
            .comma,
            .string,
            .rparen,
        } },
    };

    for (cases) |case| {
        // std.debug.print("Case: {s}\n", .{case.code});

        var it: Tokenizer = .{};
        for (case.expected) |ex| {
            errdefer std.debug.print("{any}\n", .{it});

            const t = it.next(case.code) orelse return error.Null;
            try std.testing.expectEqual(ex, t.tag);
            const src = case.code[t.loc.start..t.loc.end];
            // std.debug.print(".{s} => `{s}`\n", .{ @tagName(t.tag), src });
            if (t.tag.lexeme()) |l| {
                try std.testing.expectEqualStrings(l, src);
            }
        }

        try std.testing.expectEqual(@as(?Token, null), it.next(case.code));
    }
}

test "strings" {
    const cases =
        \\"arst"
        \\"arst"
        \\"ba\"nana1"
        \\"ba\'nana2"
        \\'ba\'nana3'
        \\'ba\"nana4'
        \\'b1a\''
        \\"b2a\""
        \\"b3a\'"
        \\"b4a\\"
        \\"b5a\\\\"
        \\"b6a\\\\\\"
        \\'ba\\"nana5'
    .*;
    var cases_it = std.mem.tokenizeScalar(u8, &cases, '\n');
    while (cases_it.next()) |case| {
        errdefer std.debug.print("Case: {s}\n", .{case});

        var it: Tokenizer = .{};
        errdefer std.debug.print("Tokenizer idx: {}\n", .{it.idx});
        const t = it.next(case) orelse return error.Null;
        errdefer std.debug.print("tok: {}\n", .{t});
        if (t.loc.end > case.len + 1) return error.OutOfBounds;
        const src = case[t.loc.start..t.loc.end];
        errdefer std.debug.print(".{s} => `{s}`\n", .{ @tagName(t.tag), src });
        try std.testing.expectEqual(@as(Token.Tag, .string), t.tag);
        try std.testing.expectEqual(@as(?Token, null), it.next(case));
    }
}

// benchmark
pub fn main() void {
    const case = "$post.draft.and($post.date.isFuture().or($post.author.is('loris-cro')))";

    for (0..1_000_000) |_| {
        var it: Tokenizer = .{};
        while (it.next(case)) |t| {
            if (t.tag == .invalid) @panic("bad");
        }
    }
}
