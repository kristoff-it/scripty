const std = @import("std");
const context = @import("context.zig");
const Interpreter = context.Interpreter;
const ctx = context.ctx;

pub const std_options = .{ .log_level = .err };
const mem = std.mem;

// const toggle_me = std.mem.backend_can_use_eql_bytes;
// comptime {
//     std.debug.assert(toggle_me == false);
// }

var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .{};
var arena_impl: std.heap.ArenaAllocator = .{
    .child_allocator = undefined,
    .state = .{},
};
export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    const gpa = gpa_impl.allocator();
    arena_impl.child_allocator = gpa;
    const arena = arena_impl.allocator();
    _ = arena_impl.reset(.retain_capacity);

    const src = buf[0..@intCast(len)];
    var t = ctx;
    var vm: Interpreter = .{};
    _ = vm.run(arena, &t, src, .{}) catch {};
}
