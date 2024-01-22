const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;

test "@memmove slice" {
    if (builtin.zig_backend == .stage2_aarch64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_arm) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_sparc64) return error.SkipZigTest;
    if (builtin.zig_backend == .stage2_spirv64) return error.SkipZigTest;

    try testMemmoveSlice();
    comptime try testMemmoveSlice();
}

fn testMemmoveSlice() !void {
    const string: []u8 = @constCast("Hello");
    @memmove(string.ptr + 3, string.ptr);

    expect(std.mem.eql(u8, slice, "HeHel"));
}
