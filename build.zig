const std = @import("std");
const afl = @import("zig-afl-kit");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scripty = b.addModule("scripty", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const fuzz_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_unit_tests.root_module.addImport("scripty", scripty);
    const run_fuzz_unit_tests = b.addRunArtifact(fuzz_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_fuzz_unit_tests.step);

    const fuzz = b.step("fuzz", "Generate an executable for AFL++ (persistent mode) plus extra tooling");
    const scripty_fuzz = b.addExecutable(.{
        .name = "scriptyfuzz",
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = .Debug,
        .single_threaded = true,
    });

    scripty_fuzz.root_module.addImport("scripty", scripty);
    fuzz.dependOn(&b.addInstallArtifact(scripty_fuzz, .{}).step);

    const afl_obj = b.addObject(.{
        .name = "scriptyfuzz-afl",
        .root_source_file = b.path("src/fuzz/afl.zig"),
        // .target = b.resolveTargetQuery(.{ .cpu_model = .baseline }),
        .target = target,
        .optimize = .Debug,
        .single_threaded = true,
    });

    afl_obj.root_module.addImport("scripty", scripty);
    afl_obj.root_module.stack_check = false; // not linking with compiler-rt
    afl_obj.root_module.link_libc = true; // afl runtime depends on libc
    // afl_obj.root_module.fuzz = true;

    const afl_fuzz = afl.addInstrumentedExe(b, target, optimize, afl_obj);
    fuzz.dependOn(&b.addInstallBinFile(afl_fuzz, "scriptyfuzz-afl").step);
    // fuzz.dependOn(&b.addInstallArtifact(afl_fuzz, .{}).step);
}
