const std = @import("std");
const context = @import("context.zig");
const Interpreter = context.Interpreter;
const ctx = context.ctx;

pub const std_options: std.Options = .{ .log_level = .err };
const mem = std.mem;

// const toggle_me = std.mem.backend_can_use_eql_bytes;
// comptime {
//     std.debug.assert(toggle_me == false);
// }

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer std.debug.assert(gpa_impl.deinit() == .ok);

    var arena_impl = std.heap.ArenaAllocator.init(gpa_impl.allocator());
    defer arena_impl.deinit();

    const arena = arena_impl.allocator();

    const src = buf[0..@intCast(len)];
    var t = ctx;
    var vm: Interpreter = .{};
    _ = vm.run(arena, &t, src, .{}) catch {};
}
