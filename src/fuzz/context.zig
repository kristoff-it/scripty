const std = @import("std");
const scripty = @import("scripty");

pub const Interpreter = scripty.VM(TestContext, TestValue);
pub const ctx: TestContext = .{
    .version = "v0",
    .page = .{
        .title = "Home",
        .content = "<p>Welcome!</p>",
    },
    .site = .{
        .name = "Loris Cro's Personal Blog",
    },
};

const TestValue = union(Tag) {
    global: *TestContext,
    site: *TestContext.Site,
    page: *TestContext.Page,
    string: []const u8,
    bool: bool,
    int: usize,
    float: f64,
    err: []const u8, // error message
    nil,

    pub const Tag = enum {
        global,
        site,
        page,
        string,
        bool,
        int,
        float,
        err,
        nil,
    };
    pub fn dot(
        self: TestValue,
        gpa: std.mem.Allocator,
        path: []const u8,
    ) error{OutOfMemory}!TestValue {
        switch (self) {
            .string,
            .bool,
            .int,
            .float,
            .err,
            .nil,
            => return .{ .err = "primitive value" },
            inline else => |v| return v.dot(gpa, path),
        }
    }

    pub const call = scripty.defaultCall(TestValue, TestContext);

    pub fn builtinsFor(comptime tag: Tag) type {
        const StringBuiltins = struct {
            pub const len = struct {
                pub fn call(
                    str: []const u8,
                    gpa: std.mem.Allocator,
                    _: *const TestContext,
                    args: []const TestValue,
                ) !TestValue {
                    if (args.len != 0) return .{ .err = "'len' wants no arguments" };
                    return TestValue.from(gpa, str.len);
                }
            };
        };
        return switch (tag) {
            .string => StringBuiltins,
            else => struct {},
        };
    }

    pub fn fromStringLiteral(bytes: []const u8) TestValue {
        return .{ .string = bytes };
    }

    pub fn fromNumberLiteral(bytes: []const u8) TestValue {
        _ = bytes;
        return .{ .int = 0 };
    }

    pub fn fromBooleanLiteral(b: bool) TestValue {
        return .{ .bool = b };
    }

    pub fn from(gpa: std.mem.Allocator, value: anytype) !TestValue {
        _ = gpa;
        const T = @TypeOf(value);
        switch (T) {
            *TestContext => return .{ .global = value },
            *TestContext.Site => return .{ .site = value },
            *TestContext.Page => return .{ .page = value },
            []const u8 => return .{ .string = value },
            usize => return .{ .int = value },
            else => @compileError("TODO: add support for " ++ @typeName(T)),
        }
    }
};
const TestContext = struct {
    version: []const u8,
    page: Page,
    site: Site,

    pub const Site = struct {
        name: []const u8,

        pub const PassByRef = true;
        pub const dot = scripty.defaultDot(Site, TestValue, true);
    };
    pub const Page = struct {
        title: []const u8,
        content: []const u8,

        pub const PassByRef = true;
        pub const dot = scripty.defaultDot(Page, TestValue, true);
    };

    pub const PassByRef = true;
    pub const dot = scripty.defaultDot(TestContext, TestValue, true);
};
