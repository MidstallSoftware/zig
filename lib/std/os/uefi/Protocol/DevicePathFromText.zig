const std = @import("std");
const uefi = std.os.uefi;

const DevicePath = uefi.Protocol.DevicePath;

/// Convert text to device paths and device nodes.
pub const DevicePathFromText = extern struct {
    _convertTextToDeviceNode: *const fn (text: [*:0]const u16) callconv(.C) ?*DevicePath,
    _convertTextToDevicePath: *const fn (text: [*:0]const u16) callconv(.C) ?*DevicePath,

    /// Converts text to its binary device node representation and copies it into an allocated buffer.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn convertTextToDeviceNode(this: *const DevicePathFromText, text: [:0]const u16) !*DevicePath {
        return this._convertTextToDeviceNode(text.ptr) orelse return error.OutOfMemory;
    }

    /// Converts text to its binary device path representation and copies it into an allocated buffer.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn convertTextToDevicePath(this: *const DevicePathFromText, text: [:0]const u16) !*DevicePath {
        return this._convertTextToDevicePath(text.ptr) orelse return error.OutOfMemory;
    }

    pub const guid = uefi.Guid{
        .time_low = 0x5c99a21,
        .time_mid = 0xc70f,
        .time_high_and_version = 0x4ad2,
        .clock_seq_high_and_reserved = 0x8a,
        .clock_seq_low = 0x5f,
        .node = [_]u8{ 0x35, 0xdf, 0x33, 0x43, 0xf5, 0x1e },
    };
};
