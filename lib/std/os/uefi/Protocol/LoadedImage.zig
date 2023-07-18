const std = @import("std");
const uefi = std.os.uefi;

const Handle = uefi.Handle;

pub const LoadedImage = extern struct {
    revision: u32,
    parent_handle: Handle,
    system_table: *uefi.SystemTable,
    device_handle: Handle,
    file_path: *uefi.Protocol.DevicePath,
    reserved: usize,
    load_options_size: u32,
    load_options: ?*anyopaque,
    image_base: [*]u8,
    image_size: u64,
    image_code_type: uefi.MemoryType,
    image_data_type: uefi.MemoryType,

    _unload: *const fn (Handle) callconv(.C) uefi.Status,

    /// Unloads an image from memory.
    pub fn unload(this: *const LoadedImage, handle: Handle) !void {
        switch (this._unload(handle)) {
            .success => return,
            .invalid_parameter => unreachable, // The handle is invalid.
            else => return error.Unexpected,
        }
    }

    pub const guid = uefi.Guid{
        .time_low = 0x5b1b31a1,
        .time_mid = 0x9562,
        .time_high_and_version = 0x11d2,
        .clock_seq_high_and_reserved = 0x8e,
        .clock_seq_low = 0x3f,
        .node = [_]u8{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
    };
};
