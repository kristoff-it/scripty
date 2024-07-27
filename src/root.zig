const vm = @import("vm.zig");
const types = @import("types.zig");

pub const Parser = @import("Parser.zig");
pub const VM = vm.VM;
pub const defaultDot = types.defaultDot;
pub const defaultCall = types.defaultCall;

test {
    _ = vm;
}
