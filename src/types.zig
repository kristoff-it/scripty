const std = @import("std");

pub fn defaultDot(
    comptime Context: type,
    comptime Value: type,
    comptime mutable: bool,
) fn (constify(Context, mutable), std.mem.Allocator, []const u8) error{OutOfMemory}!Value {
    return struct {
        pub fn dot(
            self: constify(Context, mutable),
            gpa: std.mem.Allocator,
            path: []const u8,
        ) !Value {
            const info = @typeInfo(Context).Struct;
            inline for (info.fields) |f| {
                if (f.name[0] == '_') continue;
                if (std.mem.eql(u8, f.name, path)) {
                    const by_ref = @typeInfo(f.type) == .Struct and @hasDecl(f.type, "PassByRef") and f.type.PassByRef;
                    if (by_ref) {
                        return Value.from(gpa, &@field(self, f.name));
                    } else {
                        return Value.from(gpa, @field(self, f.name));
                    }
                }
            }

            return .{ .err = "field not found" };
        }
    }.dot;
}

pub fn defaultCall(comptime Value: type) fn (
    Value,
    std.mem.Allocator,
    []const u8,
    []const Value,
) error{ OutOfMemory, Interrupt }!Value {
    return struct {
        pub fn call(
            value: Value,
            gpa: std.mem.Allocator,
            fn_name: []const u8,
            args: []const Value,
        ) error{ OutOfMemory, Interrupt }!Value {
            switch (value) {
                inline else => |v, tag| {
                    const Builtin = if (@hasDecl(Value, "builtinsFor"))
                        Value.builtinsFor(tag)
                    else
                        defaultBuiltinsFor(Value, @TypeOf(v));

                    inline for (@typeInfo(Builtin).Struct.decls) |decl| {
                        if (decl.name[0] == '_') continue;
                        if (std.mem.eql(u8, decl.name, fn_name)) {
                            return @field(Builtin, decl.name).call(
                                v,
                                gpa,
                                args,
                            );
                        }
                    }

                    if (hasDecl(@TypeOf(v), "fallbackCall")) {
                        return v.fallbackCall(
                            gpa,
                            fn_name,
                            args,
                        );
                    }

                    return .{ .err = "builtin not found" };
                },
            }
        }
    }.call;
}

inline fn hasDecl(T: type, comptime decl: []const u8) bool {
    return switch (@typeInfo(T)) {
        else => false,
        .Pointer => |p| return hasDecl(p.child, decl),
        .Struct, .Union, .Enum, .Opaque => return @hasDecl(T, decl),
    };
}

inline fn constify(comptime T: type, comptime mut: bool) type {
    return switch (mut) {
        true => *T,
        false => *const T,
    };
}

pub fn defaultBuiltinsFor(comptime Value: type, comptime Field: type) type {
    inline for (std.meta.fields(Value)) |f| {
        if (f.type == Field) {
            switch (@typeInfo(f.type)) {
                .Pointer => |ptr| {
                    if (@typeInfo(ptr.child) == .Struct) {
                        return @field(ptr.child, "Builtins");
                    }
                },
                .Struct => {
                    return @field(f.type, "Builtins");
                },
                else => {},
            }

            return struct {};
        }
    }
    @compileError("Value has no field of value " ++ @typeName(Field));
}
