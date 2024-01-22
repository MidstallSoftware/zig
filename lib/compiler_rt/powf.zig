const std = @import("std");
const common = @import("./common.zig");
const builtin = @import("builtin");

comptime {
    @export(powf, .{ .name = "powf", .linkage = common.linkage, .visibility = common.visibility });
}

pub fn powf(x: f32, y: f32) callconv(.C) f32 {
    var result: f32 = 1.0;

    if (x >= 0) {
        var i: f32 = 0;
        while (i < y) : (i += 1) {
            result *= x;
        }
    } else {
        var i: f32 = 0;
        while (i > y) : (i -= 1) {
            result /= x;
        }
    }

    return result;
}
