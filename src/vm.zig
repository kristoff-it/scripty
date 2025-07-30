const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("tracy");
const types = @import("types.zig");
const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");

const log = std.log.scoped(.scripty);

pub const Diagnostics = struct {
    loc: Tokenizer.Token.Loc,
};

pub const RunError = error{ OutOfMemory, Interrupt, Quota };

pub fn VM(
    comptime _Context: type,
    comptime _Value: type,
) type {
    return struct {
        parser: Parser = .{},
        stack: std.MultiArrayList(Result) = .{},
        state: enum { ready, waiting, pending } = .ready,

        pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
            self.stack.deinit(gpa);
        }

        pub const Context = _Context;
        pub const Value = _Value;

        pub const Result = struct {
            debug: if (builtin.mode == .Debug)
                enum { unset, set }
            else
                enum { set } = .set,
            value: Value,
            loc: Tokenizer.Token.Loc,
        };

        const unset = if (builtin.mode == .Debug) .unset else undefined;

        pub const RunOptions = struct {
            diag: ?*Diagnostics = null,
            quota: usize = 0,
        };

        const ScriptyVM = @This();

        pub fn insertValue(vm: *ScriptyVM, v: Value) void {
            std.debug.assert(vm.state == .waiting);
            const stack_values = vm.stack.items(.value);
            stack_values[stack_values.len - 1] = v;
            vm.state = .pending;
            vm.ext = undefined;
        }

        pub fn reset(vm: *ScriptyVM) void {
            vm.stack.shrinkRetainingCapacity(0);
            vm.state = .ready;
            vm.parser = .{};
        }

        pub fn run(
            vm: *ScriptyVM,
            gpa: std.mem.Allocator,
            ctx: *Context,
            src: []const u8,
            opts: RunOptions,
        ) RunError!Result {
            log.debug("Starting ScriptyVM", .{});
            log.debug("State: {s}", .{@tagName(vm.state)});
            switch (vm.state) {
                .ready => {},
                .waiting => unreachable, // programming error
                .pending => {
                    const result = vm.stack.get(vm.stack.len - 1);
                    if (result.value == .err) {
                        vm.reset();
                        return .{ .loc = result.loc, .value = result.value };
                    }
                },
            }

            // On error make the vm usable again.
            errdefer |err| switch (@as(RunError, err)) {
                error.Quota, error.Interrupt => {},
                else => vm.reset(),
            };

            var quota = opts.quota;
            if (opts.diag != null) @panic("TODO: implement diagnostics");
            if (quota == 1) return error.Quota;

            while (vm.parser.next(src)) |node| : ({
                if (quota == 1) return error.Quota;
                if (quota > 1) quota -= 1;
            }) {
                if (builtin.mode == .Debug) {
                    if (vm.stack.len == 0) {
                        log.debug("Stack is empty", .{});
                    } else {
                        const last = vm.stack.get(vm.stack.len - 1);
                        log.debug("Top of stack: ({}) '{s}' {s}", .{
                            vm.stack.len,
                            last.loc.slice(src),
                            if (last.debug == .unset)
                                "<unset>"
                            else
                                @tagName(last.value),
                        });

                        if (@hasField(Value, "page")) {
                            if (last.debug != .unset and last.value == .page) {
                                log.debug("Page: {*}", .{last.value.page});
                            }
                        }
                    }
                }
                log.debug("Now processing node: '{s}' {any}", .{
                    node.loc.slice(src),
                    node,
                });
                switch (node.tag) {
                    .err_invalid_token,
                    .err_unexpected_token,
                    .err_missing_dollar,
                    .err_not_identifier,
                    .err_not_callable,
                    .err_outside_call,
                    .err_truncated,
                    => {
                        vm.reset();
                        return .{
                            .loc = node.loc,
                            .value = .{ .err = node.tag.errorMessage() },
                        };
                    },
                    .string => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromStringLiteral(try node.loc.unquote(gpa, src)),
                        .loc = node.loc,
                    }),
                    .number => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromNumberLiteral(node.loc.slice(src)),
                        .loc = node.loc,
                    }),
                    .true => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromBooleanLiteral(true),
                        .loc = node.loc,
                    }),
                    .false => try vm.stack.append(gpa, .{
                        .debug = .set,
                        .value = Value.fromBooleanLiteral(false),
                        .loc = node.loc,
                    }),
                    .call => {
                        // std.debug.assert(vm.stack.len > 0);
                        // @breakpoint();
                        if (vm.stack.len == 0) {
                            vm.reset();
                            return .{
                                .loc = node.loc,
                                .value = .{
                                    .err = "top-level builtin calls are not allowed",
                                },
                            };
                        }
                        std.debug.assert(src[node.loc.end] == '(');
                        try vm.stack.append(gpa, .{
                            .loc = node.loc,
                            .value = undefined,
                            .debug = unset,
                        });
                    },

                    .path => {
                        // log.err("(vm) {any} `{s}`", .{
                        //     node.loc,
                        //     code[node.loc.start..node.loc.end],
                        // });
                        const slice = vm.stack.slice();
                        const stack_locs = slice.items(.loc);
                        const stack_values = slice.items(.value);
                        const global = src[node.loc.start] == '$';
                        const start = node.loc.start + @intFromBool(global);
                        const end = node.loc.end;
                        const path = src[start..end];

                        const old_value = if (global)
                            try Value.from(gpa, ctx)
                        else blk: {
                            if (builtin.mode == .Debug) {
                                const stack_debug = slice.items(.debug);

                                std.debug.assert(
                                    stack_debug[stack_debug.len - 1] == .set,
                                );
                            }
                            break :blk stack_values[stack_values.len - 1];
                        };

                        const new_value = try dotPath(gpa, old_value, path);
                        if (new_value == .err) {
                            vm.reset();
                            return .{ .loc = node.loc, .value = new_value };
                        }
                        if (global) {
                            try vm.stack.append(gpa, .{
                                .loc = node.loc,
                                .value = new_value,
                                .debug = .set,
                            });
                        } else {
                            stack_locs[stack_locs.len - 1] = node.loc;
                            stack_values[stack_values.len - 1] = new_value;
                            if (builtin.mode == .Debug) {
                                const stack_debug = slice.items(.debug);
                                stack_debug[stack_values.len - 1] = .set;
                            }
                        }
                    },
                    .apply => {
                        const slice = vm.stack.slice();
                        const stack_locs = slice.items(.loc);
                        const stack_values = slice.items(.value);

                        var call_idx = stack_locs.len - 1;
                        const call_loc = while (true) : (call_idx -= 1) {
                            const current = stack_locs[call_idx];
                            if (src[current.end] == '(') {
                                break current;
                            }
                        };

                        const fn_name = src[call_loc.start..call_loc.end];
                        const args = stack_values[call_idx + 1 ..];
                        // // TODO: this is actually a parsing error
                        if (call_idx == 0) {
                            vm.reset();
                            return .{
                                .loc = call_loc,
                                .value = .{
                                    .err = "cannot call a function directly from the global scope",
                                },
                            };
                        }

                        // Remove arguments and fn_name
                        vm.stack.shrinkRetainingCapacity(call_idx);

                        // center on the old value
                        call_idx -= 1;
                        const old_value = stack_values[call_idx];
                        if (builtin.mode == .Debug) {
                            const stack_debug = slice.items(.debug);
                            std.debug.assert(
                                stack_debug[call_idx] == .set,
                            );
                        }

                        // disarm location as a call
                        stack_locs[call_idx].start = call_loc.start;
                        stack_locs[call_idx].end = call_loc.end + 1;

                        const new_value = blk: {
                            const apply_zone = tracy.traceNamed(@src(), "apply");
                            defer apply_zone.end();

                            break :blk old_value.call(gpa, ctx, fn_name, args) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.Interrupt => {
                                    vm.state = .waiting;
                                    return error.Interrupt;
                                },
                            };
                        };

                        if (new_value == .err) {
                            vm.reset();
                            return .{ .loc = call_loc, .value = new_value };
                        }

                        // old value becomes the new result
                        stack_values[call_idx] = new_value;
                        if (builtin.mode == .Debug) {
                            const stack_debug = slice.items(.debug);
                            stack_debug[call_idx] = .set;
                        }
                    },
                }
            }

            std.debug.assert(vm.stack.items(.loc).len == 1);
            const result = vm.stack.pop().?;
            std.debug.assert(result.value != .err);
            vm.reset();
            log.debug("returning = '{any}'", .{result});
            return result;
        }

        fn dotPath(gpa: std.mem.Allocator, value: Value, path: []const u8) !Value {
            var it = std.mem.tokenizeScalar(u8, path, '.');
            var val = value;
            while (it.next()) |component| {
                val = try val.dot(gpa, component);
                if (val == .err) break;
            }

            return val;
        }
    };
}

pub const TestValue = union(Tag) {
    global: *const TestContext,
    site: *const TestContext.Site,
    page: *const TestContext.Page,
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

    pub const call = types.defaultCall(TestValue, TestContext);

    pub fn builtinsFor(comptime tag: Tag) type {
        const StringBuiltins = struct {
            pub const len = struct {
                pub fn call(
                    str: []const u8,
                    gpa: std.mem.Allocator,
                    _: *const TestContext,
                    args: []const TestValue,
                ) !TestValue {
                    if (args.len != 0) return .{
                        .err = "'len' wants no arguments",
                    };
                    return TestValue.from(gpa, str.len);
                }
            };
            pub const ext = struct {
                pub fn call(
                    str: []const u8,
                    gpa: std.mem.Allocator,
                    _: *const TestContext,
                    args: []const TestValue,
                ) !TestValue {
                    if (args.len != 0) return .{
                        .err = "'ext' wants no arguments",
                    };
                    _ = str;
                    _ = gpa;
                    return error.Interrupt;
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
            *TestContext, *const TestContext => return .{ .global = value },
            *const TestContext.Site => return .{ .site = value },
            *const TestContext.Page => return .{ .page = value },
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
        pub const dot = types.defaultDot(Site, TestValue, false);
    };
    pub const Page = struct {
        title: []const u8,
        content: []const u8,

        pub const PassByRef = true;
        pub const dot = types.defaultDot(Page, TestValue, false);
    };

    pub const PassByRef = true;
    pub const dot = types.defaultDot(TestContext, TestValue, false);
};

const test_ctx: TestContext = .{
    .version = "v0",
    .page = .{
        .title = "Home",
        .content = "<p>Welcome!</p>",
    },
    .site = .{
        .name = "Loris Cro's Personal Blog",
    },
};

const TestInterpreter = VM(TestContext, TestValue);

test "basic" {
    const code = "$page.title";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    const result = try vm.run(arena.allocator(), &t, code, .{});

    const ex: TestInterpreter.Result = .{
        .loc = .{ .start = 0, .end = code.len },
        .value = .{ .string = "Home" },
    };

    errdefer log.debug("result = `{s}`\n", .{result.value.string});

    try std.testing.expectEqualDeep(ex, result);
}

test "builtin" {
    const code = "$page.title.len()";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    const result = try vm.run(arena.allocator(), &t, code, .{});

    const ex: TestInterpreter.Result = .{
        .loc = .{ .start = 12, .end = 16 },
        .value = .{ .int = 4 },
    };

    errdefer log.debug("result = `{s}`\n", .{result.value.string});

    try std.testing.expectEqualDeep(ex, result);
}

test "interrupt" {
    const code = "$page.title.ext()";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var t = test_ctx;
    var vm: TestInterpreter = .{};
    try std.testing.expectError(
        error.Interrupt,
        vm.run(arena.allocator(), &t, code, .{}),
    );
}
