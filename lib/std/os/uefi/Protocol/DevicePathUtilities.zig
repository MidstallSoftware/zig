const std = @import("std");
const uefi = std.os.uefi;

const DevicePath = uefi.Protocol.DevicePath;

/// Creates and manipulates device paths and device nodes.
pub const DevicePathUtilities = extern struct {
    _getDevicePathSize: *const fn (path: *const DevicePath) callconv(.C) usize,
    _duplicateDevicePath: *const fn (path: *const DevicePath) callconv(.C) ?*DevicePath,
    _appendDevicePath: *const fn (src1: *const DevicePath, src2: *const DevicePath) callconv(.C) *DevicePath,
    _appendDeviceNode: *const fn (path: *const DevicePath, node: *const DevicePath) callconv(.C) *DevicePath,
    _appendDevicePathInstance: *const fn (path: *const DevicePath, path_instance: *const DevicePath) callconv(.C) *DevicePath,
    _getNextDevicePathInstance: *const fn (instance: *?*const DevicePath, instance_size: ?*usize) callconv(.C) *DevicePath,
    _isDevicePathMultiInstance: *const fn (path: *const DevicePath) callconv(.C) bool,
    _createDeviceNode: *const fn (type: DevicePath.Type, subtype: u8, length: u16) callconv(.C) *DevicePath,

    /// Returns the size of the specified device path, in bytes, including the end-of-path tag.
    pub fn getDevicePathSize(this: *const DevicePathUtilities, path: *const DevicePath) usize {
        return this._getDevicePathSize(path);
    }

    /// Creates a duplicate of the specified device path. The memory is allocated from EFI boot services memory.
    /// It is the responsibility of the caller to free the memory allocated
    pub fn duplicateDevicePath(this: *const DevicePathUtilities, path: *const DevicePath) !*DevicePath {
        return this._duplicateDevicePath(path) orelse return error.OutOfMemory;
    }

    /// Creates a new device path by appending a copy of the second device path to a copy of the first device
    /// path in a newly allocated buffer. Only the end-of-device-path device node from the second device path is retained.
    pub fn appendDevicePath(this: *const DevicePathUtilities, src1: *const DevicePath, src2: *const DevicePath) !*DevicePath {
        return this._appendDevicePath(src1, src2) orelse return error.OutOfMemory;
    }

    /// creates a new device path by appending a copy of the specified device node to a copy of the specified
    /// device path in an allocated buffer. The end-of-device-path device node is moved after the end of the appended device node.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn appendDeviceNode(this: *const DevicePathUtilities, path: *const DevicePath, node: *const DevicePath) !*DevicePath {
        return this._appendDeviceNode(path, node) orelse return error.OutOfMemory;
    }

    /// This function creates a new device path by appending a copy of the specified device path instance to a copy of the
    /// specified device path in an allocated buffer. The end-of-device-path device node is moved after the end of the appended
    /// device node and a new end-of-device-path-instance node is inserted between.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn appendDeviceInstance(this: *const DevicePathUtilities, path: *const DevicePath, path_instance: *const DevicePath) !*DevicePath {
        return this._appendDevicePathInstance(path, path_instance) orelse return error.OutOfMemory;
    }

    pub const Iterator = struct {
        protocol: *const DevicePathUtilities,
        prev: ?*const DevicePath,
        size: usize = 0,

        /// Returns the next device path instance from the device path or null if there are no more device path instances in path.
        ///
        /// Creates a copy of the current device path instance. The memory is allocated from EFI boot services memory.
        /// It is the responsibility of the caller to free the memory allocated.
        pub fn next(it: *Iterator) ?*DevicePath {
            var path: ?*DevicePath = it.prev;
            it.protocol._getNextDevicePathInstance(&path, &it.size);

            it.prev = path;
            return path;
        }
    };

    pub fn instanceIterator(this: *const DevicePathUtilities, path: *const DevicePath) Iterator {
        return Iterator{ .protocol = this, .prev = path };
    }

    /// Returns true if the device path is a multi-instance device path.
    pub fn isDevicePathMultiInstance(this: *const DevicePathUtilities, path: *const DevicePath) bool {
        return this._isDevicePathMultiInstance(path);
    }

    /// This function creates a new device node in a newly allocated buffer.
    ///
    /// The memory is allocated from EFI boot services memory. It is the responsibility of the caller to free the memory allocated.
    pub fn createDevicePathNode(this: *const DevicePathUtilities, kind: DevicePath.Type, subtype: u8, length: u16) !*DevicePath {
        return this._createDeviceNode(kind, subtype, length) orelse return error.OutOfMemory;
    }

    pub const guid = uefi.Guid{
        .time_low = 0x379be4e,
        .time_mid = 0xd706,
        .time_high_and_version = 0x437d,
        .clock_seq_high_and_reserved = 0xb0,
        .clock_seq_low = 0x37,
        .node = [_]u8{ 0xed, 0xb8, 0x2f, 0xb7, 0x72, 0xa4 },
    };
};
