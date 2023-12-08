//! This file is hand-made until a better source for the feature set can be found.

const std = @import("../std.zig");
const CpuFeature = std.Target.Cpu.Feature;
const CpuModel = std.Target.Cpu.Model;

pub const Feature = enum {
    @"8bit",
};

pub const featureSet = CpuFeature.feature_set_fns(Feature).featureSet;
pub const featureSetHas = CpuFeature.feature_set_fns(Feature).featureSetHas;
pub const featureSetHasAny = CpuFeature.feature_set_fns(Feature).featureSetHasAny;
pub const featureSetHasAll = CpuFeature.feature_set_fns(Feature).featureSetHasAll;

pub const all_features = blk: {
    @setEvalBranchQuota(2000);
    const len = @typeInfo(Feature).Enum.fields.len;
    std.debug.assert(len <= CpuFeature.Set.needed_bit_count);
    var result: [len]CpuFeature = undefined;

    result[@intFromEnum(Feature.@"8bit")] = .{
        .llvm_name = null,
        .description = "8-bit instructions",
        .dependencies = featureSet(&[_]Feature{}),
    };

    const ti = @typeInfo(Feature);
    for (&result, 0..) |*elem, i| {
        elem.index = i;
        elem.name = ti.Enum.fields[i].name;
    }

    break :blk result;
};

pub const cpu = struct {
    // This is a bit confused because the CPU module
    // is called the same as the architecture.
    pub const z80 = CpuModel{
        .name = "z80",
        .llvm_name = null,
        .features = featureSet(&[_]Feature{}),
    };
};
