const std = @import("std");
const context = @import("fuzz/context.zig");
const Interpreter = context.Interpreter;
const ctx = context.ctx;

pub const std_options: std.Options = .{ .log_level = .err };

/// This main function is meant to be used via black box fuzzers
/// and/or to manually weed out test cases that are not valid anymore
/// after fixing bugs.
///
/// See fuzz/afl.zig for the AFL++ specific executable.
pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const src = switch (args.len) {
        1 => try std.io.getStdIn().reader().readAllAlloc(
            arena,
            std.math.maxInt(u32),
        ),
        2 => args[1],
        else => @panic("wrong number of arguments"),
    };

    std.debug.print("Input: '{s}'\n", .{src});

    var t = ctx;
    var vm: Interpreter = .{};
    const result = try vm.run(arena, &t, src, .{});
    std.debug.print("Result:\n{any}\n", .{result});
}

test "afl++ fuzz cases" {
    const cases: []const []const u8 = &.{
        @embedFile("fuzz/cases/1-1.txt"),
        @embedFile("fuzz/cases/2-1.txt"),
    };

    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    for (cases) |c| {
        var t = ctx;
        var vm: Interpreter = .{};
        std.debug.print("\n\ncase: '{s}'\n", .{c});
        const result = try vm.run(arena, &t, c, .{});
        std.debug.print("Result:\n{any}\n", .{result});
    }
}
