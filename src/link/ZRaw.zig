//! The driver for the Z80 binary format.
//! Mostly in charge of making sure address are aligned corretly.
//! Doesn't do any actual linking per se.

const std = @import("std");
const Allocator = std.mem.Allocator;

const link = @import("../link.zig");

const ZRaw = @This();

base: link.File,

pub fn openPath(allocator: Allocator, sub_path: []const u8, options: link.Options) !*ZRaw {
    if (options.use_llvm)
        return error.LLVMBackendDoesNotSupportZ80;

    const self = try createEmpty(allocator, options);
    errdefer self.base.destroy();

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{
        .read = true,
        .mode = link.determineMode(options),
    });
    errdefer file.close();
    self.base.file = file;
}

pub fn createEmpty(gpa: Allocator, options: link.Options) !*ZRaw {
    _ = gpa;
    _ = options;

    @panic("TODO ZRaw createEmpty");
}

const Bases = struct {
    text: u64,
    /// the Global Offset Table starts at the beginning of the data section
    data: u64,
};
