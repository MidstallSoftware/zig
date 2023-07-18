const std = @import("std");
const uefi = std.os.uefi;

const DevicePath = uefi.Protocol.DevicePath;

/// Convert device nodes and paths to text.
pub const DevicePathToText = extern struct {
    _convertDeviceNodeToText: *const fn (path: *const DevicePath, display: bool, shortcuts: bool) callconv(.C) ?[*:0]const u16,
    _convertDevicePathToText: *const fn (path: *const DevicePath, display: bool, shortcuts: bool) callconv(.C) ?[*:0]const u16,

    /// Converts a device node to its text representation and copies it into a newly allocated buffer.
    ///
    /// The display_only parameter controls whether the longer (parseable) or shorter (display-only) form of the conversion is used.
    /// When shortcuts is false, then the shortcut forms of text representation for a device node cannot be used.
    /// A shortcut form is one which uses information other than the type or subtype.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn convertDeviceNodeToText(this: *const DevicePathToText, path: *const DevicePath, display_only: bool, shortcuts: bool) ![:0]const u16 {
        return std.mem.span(this._convertDeviceNodeToText(path, display_only, shortcuts) orelse return error.OutOfMemory);
    }

    /// Converts a device path to its text representation and copies it into a newly allocated buffer.
    ///
    /// The display_only parameter controls whether the longer (parseable) or shorter (display-only) form of the conversion is used.
    /// When shortcuts is false, then the shortcut forms of text representation for a device node cannot be used.
    /// A shortcut form is one which uses information other than the type or subtype.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn convertDevicePathToText(this: *const DevicePathToText, path: *const DevicePath, display_only: bool, shortcuts: bool) ![:0]const u16 {
        return std.mem.span(this._convertDevicePathToText(path, display_only, shortcuts) orelse return error.OutOfMemory);
    }

    pub const guid = uefi.Guid{
        .time_low = 0x8b843e20,
        .time_mid = 0x8132,
        .time_high_and_version = 0x4852,
        .clock_seq_high_and_reserved = 0x90,
        .clock_seq_low = 0xcc,
        .node = [_]u8{ 0x55, 0x1a, 0x4e, 0x4a, 0x7f, 0x1c },
    };
};
