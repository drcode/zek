const std = @import("std");
/// Zig version. When writing code that supports multiple versions of Zig, prefer
/// feature detection (i.e. with `@hasDecl` or `@hasField`) over version checks.
pub const zig_version = std.SemanticVersion.parse("0.9.0-dev.1374+8b8827478") catch unreachable;
/// Temporary until self-hosted is feature complete.
pub const zig_is_stage2 = false;
/// Temporary until self-hosted supports the `cpu.arch` value.
pub const stage2_arch: std.Target.Cpu.Arch = .aarch64;
/// Temporary until self-hosted can call `std.Target.x86.featureSetHas` at comptime.
pub const stage2_x86_cx16 = false;

pub const output_mode = std.builtin.OutputMode.Exe;
pub const link_mode = std.builtin.LinkMode.Static;
pub const is_test = false;
pub const single_threaded = false;
pub const abi = std.Target.Abi.musl;
pub const cpu: std.Target.Cpu = .{
    .arch = .aarch64,
    .model = &std.Target.aarch64.cpu.generic,
    .features = std.Target.aarch64.featureSet(&[_]std.Target.aarch64.Feature{
        .ete,
        .fp_armv8,
        .fuse_aes,
        .neon,
        .perfmon,
        .trbe,
        .use_postra_scheduler,
    }),
};
pub const os = std.Target.Os{
    .tag = .linux,
    .version_range = .{ .linux = .{
        .range = .{
            .min = .{
                .major = 3,
                .minor = 16,
                .patch = 0,
            },
            .max = .{
                .major = 5,
                .minor = 5,
                .patch = 5,
            },
        },
        .glibc = .{
            .major = 2,
            .minor = 17,
            .patch = 0,
        },
    }},
};
pub const target = std.Target{
    .cpu = cpu,
    .os = os,
    .abi = abi,
};
pub const object_format = std.Target.ObjectFormat.elf;
pub const mode = std.builtin.Mode.Debug;
pub const link_libc = false;
pub const link_libcpp = false;
pub const have_error_return_tracing = true;
pub const valgrind_support = false;
pub const position_independent_code = false;
pub const position_independent_executable = false;
pub const strip_debug_info = false;
pub const code_model = std.builtin.CodeModel.default;
