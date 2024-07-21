const interpreter = @import("interpreter.zig");
const types = @import("types.zig");

pub const VM = interpreter.VM;
pub const defaultDot = types.defaultDot;
pub const defaultCall = types.defaultCall;

test {
    _ = interpreter;
}
