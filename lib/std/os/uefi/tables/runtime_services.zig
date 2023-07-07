const std = @import("std");
const uefi = std.os.uefi;

const Guid = uefi.Guid;
const Status = uefi.Status;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;

/// Runtime services are provided by the firmware before and after exitBootServices has been called.
///
/// As the runtime_services table may grow with new UEFI versions, it is important to check hdr.header_size.
///
/// Some functions may not be supported. Check the RuntimeServicesSupported variable using getVariable.
/// getVariable is one of the functions that may not be supported.
///
/// Some functions may not be called while other functions are running.
pub const RuntimeServices = extern struct {
    header: uefi.TableHeader,

    _getTime: *const fn (time: *uefi.Time, capabilities: ?*uefi.TimeCapabilities) callconv(.C) Status,
    _setTime: *const fn (time: *uefi.Time) callconv(.C) Status,
    _getWakeupTime: *const fn (enabled: *bool, pending: *bool, time: *uefi.Time) callconv(.C) Status,
    _setWakeupTime: *const fn (enable: bool, time: ?*uefi.Time) callconv(.C) Status,

    _setVirtualAddressMap: *const fn (mmap_size: usize, descriptor_size: usize, descriptor_version: u32, virtual_map: [*]MemoryDescriptor) callconv(.C) Status,
    _convertPointer: *const fn (debug_disposition: usize, address: **anyopaque) callconv(.C) Status,

    _getVariable: *const fn (var_name: [*:0]const u16, vendor_guid: *align(8) const Guid, attributes: ?*u32, data_size: *usize, data: ?*anyopaque) callconv(.C) Status,
    getNextVariableName: *const fn (var_name_size: *usize, var_name: [*:0]u16, vendor_guid: *align(8) Guid) callconv(.C) Status,
    _setVariable: *const fn (var_name: [*:0]const u16, vendor_guid: *align(8) const Guid, attributes: u32, data_size: usize, data: *anyopaque) callconv(.C) Status,

    _getNextHighMonotonicCount: *const fn (high_count: *u32) callconv(.C) Status,
    _resetSystem: *const fn (reset_type: ResetType, reset_status: Status, data_size: usize, reset_data: ?*const anyopaque) callconv(.C) noreturn,

    _updateCapsule: *const fn (capsule_header_array: *const *CapsuleHeader, capsule_count: usize, scatter_gather_list: uefi.EfiPhysicalAddress) callconv(.C) Status,
    _queryCapsuleCapabilities: *const fn (capsule_header_array: *const *CapsuleHeader, capsule_count: usize, maximum_capsule_size: *usize, resetType: ResetType) callconv(.C) Status,

    _queryVariableInfo: *const fn (attributes: *u32, maximum_variable_storage_size: *u64, remaining_variable_storage_size: *u64, maximum_variable_size: *u64) callconv(.C) Status,

    pub const signature: u64 = 0x56524553544e5552;

    /// Returns the value of a variable.
    pub fn getVariable(this: *const RuntimeServices, name: [:0]const u16, vendor: Guid) !usize {
        var size: usize = 0;
        switch (this._getVariable(name.ptr, &vendor, null, &size, null)) {
            .success => return size,
            .not_found => return error.NotFound, // The variable was not found.
            .buffer_too_small => return error.TooSmall, // The buffer is too small for the result.
            .invalid_parameter => unreachable, // Name, vendor, size, or data is null.
            .device_error => return error.Hardware, // The variable could not be retrieved due to a hardware error.
            .security_violation => return error.Access, // The variable could not be retrieved due to an authentication failure.
            .unsupported => return error.Unsupported, // After ExitBootServices() has been called, this return code may be returned if no variable storage is supported.
            else => return error.Unexpected,
        }
    }

    /// Returns the length of a variable.
    pub fn getVariableLength(this: *const RuntimeServices, name: [:0]const u16, vendor: Guid) !usize {
        var size: usize = 0;
        switch (this._getVariable(name.ptr, &vendor, null, &size, null)) {
            .success => return size,
            .not_found => return 0, // The variable was not found.
            .buffer_too_small => unreachable, // The buffer is too small for the result.
            .invalid_parameter => unreachable, // Name, vendor, size, or data is null.
            .device_error => return error.Hardware, // The variable could not be retrieved due to a hardware error.
            .security_violation => return error.Access, // The variable could not be retrieved due to an authentication failure.
            .unsupported => return error.Unsupported, // After ExitBootServices() has been called, this return code may be returned if no variable storage is supported.
            else => return error.Unexpected,
        }
    }

    /// Returns the attributes of a variable.
    pub fn getVariableAttributes(this: *const RuntimeServices, name: [:0]const u16, vendor: Guid) !VariableAttributes {
        var size: usize = 0;
        var attributes: VariableAttributes = 0;
        switch (this._getVariable(name.ptr, &vendor, &attributes, &size, null)) {
            .success => return attributes,
            .not_found => return error.NotFound, // The variable was not found.
            .buffer_too_small => return attributes,
            .invalid_parameter => unreachable, // Name, vendor, size, or data is null.
            .device_error => return error.Hardware, // The variable could not be retrieved due to a hardware error.
            .security_violation => return error.Access, // The variable could not be retrieved due to an authentication failure.
            .unsupported => return error.Unsupported, // After ExitBootServices() has been called, this return code may be returned if no variable storage is supported.
            else => return error.Unexpected,
        }
    }

    // TODO: VariableIterator

    /// Sets the value of a variable. This service can be used to create a new variable, modify the value of an existing variable, or to delete an existing variable.
    pub fn setVariable(this: *const RuntimeServices, name: [:0]const u16, vendor: Guid, attributes: VariableAttributes, data: []const u8) !void {
        switch (this._setVariable(name.ptr, &vendor, attributes, data.len, data.ptr)) {
            .success => return,
            .invalid_parameter => unreachable, // An invalid combination of attribute bits, name, and GUID was supplied, or the size exceeds the maximum allowed.
            .out_of_resources => return error.OutOfMemory, // Not enough storage is available to hold the variable and its data.
            .device_error => return error.Hardware, // The variable could not be saved due to a hardware failure.
            .write_protected => return error.WriteProtected, // The variable in question is read-only or cannot be deleted.
            .security_violation => return error.Access, // The variable could not be saved due to an authentication failure.
            .not_found => return error.NotFound, // The variable trying to be updated or deleted was not found.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    pub const VariableInfo = struct {
        max_storage_size: u64,
        remaining_storage_size: u64,
        max_variable_size: u64,
    };

    /// Returns information about the EFI variables.
    pub fn queryVariableInfo(this: *const RuntimeServices, attributes: VariableAttributes) !VariableInfo {
        if (!this.header.isAtLeast(2, 0, 0)) return error.Unsupported;

        var max_storage_size: u64 = undefined;
        var remaining_storage_size: u64 = undefined;
        var max_variable_size: u64 = undefined;
        switch (this._queryVariableInfo(attributes, &max_storage_size, &remaining_storage_size, &max_variable_size)) {
            .success => return VariableInfo{
                .max_storage_size = max_storage_size,
                .remaining_storage_size = remaining_storage_size,
                .max_variable_size = max_variable_size,
            },
            .invalid_parameter => unreachable, // An invalid combination of attribute bits was supplied.
            .unsupported => return error.Unsupported, // The attribute is not supported on this platform.
            else => return error.Unexpected,
        }
    }

    /// Returns the current time and date information.
    pub fn getTime(this: *const RuntimeServices) !uefi.Time {
        var time: uefi.Time = undefined;
        switch (this._getTime(&time, null)) {
            .success => return time,
            .invalid_parameter => unreachable, // Time is null.
            .device_error => return error.Hardware, // The time could not be retrieved due to a hardware error.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Returns the time-keeping capabilities of the hardware platform.
    pub fn getTimeCapabilities(this: *const RuntimeServices) !uefi.TimeCapabilities {
        var time: uefi.Time = undefined;
        var capabilities: uefi.TimeCapabilities = undefined;
        switch (this._getTime(&time, capabilities)) {
            .success => return capabilities,
            .invalid_parameter => unreachable, // Time is null.
            .device_error => return error.Hardware, // The time could not be retrieved due to a hardware error.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Sets the current local time and date information.
    pub fn setTime(this: *const RuntimeServices, time: uefi.Time) !void {
        switch (this._setTime(&time)) {
            .success => return,
            .invalid_parameter => unreachable, // A time field is out of range.
            .device_error => return error.Hardware, // The time could not be set due to a hardware error.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Returns the current wakeup alarm clock setting.
    pub fn getWakeupTime(this: *const RuntimeServices, enabled: *bool, pending: *bool, time: *uefi.Time) !void {
        switch (this._getWakeupTime(enabled, pending, time)) {
            .success => return,
            .invalid_parameter => unreachable, // Enabled, pending, or time is null.
            .device_error => return error.Hardware, // The wakeup time could not be retrieved due to a hardware error.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Sets the system wakeup alarm clock time.
    pub fn setWakeupTime(this: *const RuntimeServices, enable: bool, time: ?*uefi.Time) !void {
        switch (this._setWakeupTime(enable, time)) {
            .success => return,
            .invalid_parameter => unreachable, // A time field is out of range.
            .device_error => return error.Hardware, // The wakeup time could not be set due to a hardware error.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Changes the runtime addressing mode of EFI firmware from physical to virtual.
    pub fn setVirtualAddressMap(this: *const RuntimeServices, memory_map: []MemoryDescriptor) !void {
        switch (this._setVirtualAddressMap(memory_map.len * @sizeOf(MemoryDescriptor), @sizeOf(MemoryDescriptor), MemoryDescriptor.version, memory_map.ptr)) {
            .success => return,
            .unsupported => return error.Unsupported, // EFI firmware is not at runtime, or the EFI firmware is already in virtual address mapped mode.
            .invalid_parameter => unreachable, // DescriptorSize or DescriptorVersion is invalid.
            .no_mapping => return error.IncompleteMap, // A virtual address was not supplied for a range in the memory map that requires a mapping.
            .not_found => return error.InvalidMap, // A virtual address was supplied for an address that is not found in the memory map.
            else => return error.Unexpected,
        }
    }

    /// Determines the new virtual address that is to be used on subsequent memory accesses.
    pub fn convertPointer(this: *const RuntimeServices, ptr: anytype) !@TypeOf(ptr) {
        const T = @TypeOf(ptr);
        const info = @typeInfo(T);

        if (info == .Pointer or (info == .Optional and @typeInfo(info.Optional.child) == .Pointer)) @compileError("cannot convert non pointer type " ++ @typeName(T));

        var addr = ptr;
        const disposition = if (@typeInfo(@TypeOf(ptr)) == .Optional) 0x1 else 0x0;

        switch (this._convertPointer(disposition, &addr)) {
            .success => return,
            .not_found => return error.InvalidMap, // The pointer pointed to by address was not found to be part of the current memory map. This is normally fatal.
            .invalid_parameter => unreachable, // address is null; address is null and disposition does not have the optional bit (bit 0) set.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    /// Resets the entire platform. If the platform supports EFI_RESET_NOTIFICATION_PROTOCOL, then prior to completing the reset of the platform, all of the pending notifications must be called.
    pub fn resetSystem(this: *const RuntimeServices, reset_type: ResetType, reset_status: Status, reset_data: ?[:0]const u8) noreturn {
        this._resetSystem(
            reset_type,
            reset_status,
            if (reset_data) |data| data.len else 0,
            if (reset_data) |data| data.ptr else null,
        );
    }

    /// Returns the next high 32 bits of the platform’s monotonic counter
    pub fn getNextHighMonotonicCount(this: *const RuntimeServices) !u32 {
        var count: u32 = undefined;
        switch (this._getNextHighMonotonicCount(count)) {
            .success => return,
            .device_error => return error.Hardware, // The device is not functioning properly.
            .invalid_parameter => unreachable, // count is null.
            .unsupported => return error.Unsupported, // This call is not supported by this platform at the time the call is made.
            else => return error.Unexpected,
        }
    }

    pub fn updateCapsule(this: *const RuntimeServices, capsules: []CapsuleHeader, scatter_gather_list: uefi.EfiPhysicalMemory) !void {
        if (!this.header.isAtLeast(2, 0, 0)) return error.Unsupported;

        switch (this._updateCapsule(&capsules.ptr, capsules.len, scatter_gather_list)) {
            .success => return,
            .invalid_parameter => unreachable, // Capsules is empty, a capsule is not valid.
            .device_error => return error.Hardware, // The capsule update was started, but failed due to a device error.
            .unsupported => return error.Unsupported, // This call or capsule type is not supported by this platform at the time the call is made.
            .out_of_resources => return error.OutOfMemory, // The capsule is compatible with the platform, but there are not enough resources available to complete the capsule update.
            else => return error.Unexpected,
        }
    }

    pub fn queryCapsuleCapabilities(this: *const RuntimeServices, capsules: []CapsuleHeader, maximum_capsule_size: *u64) !void {
        if (!this.header.isAtLeast(2, 0, 0)) return error.Unsupported;

        var reset_type: ResetType = undefined;
        switch (this._queryCapsuleCapabilities(&capsules.ptr, capsules.len, maximum_capsule_size, &reset_type)) {
            .success => return,
            .invalid_parameter => unreachable, // maximum_capsule_size is NULL.
            .unsupported => return error.Unsupported, // The capsule type is not supported on this platform, and maximum_capsule_size is undefined; or this call is not supported by this platform at the time the call is made.
            .out_of_resources => return error.OutOfMemory, // The capsule is compatible with the platform, but there are not enough resources available to complete the capsule update.
            else => return error.Unexpected,
        }
    }
};

/// This structure represents time information.
pub const Time = extern struct {
    pub const DaylightSavings = packed struct(u8) {
        /// If true, the time is affected by daylight savings time.
        adjust_daylight: bool = false,

        /// If true, the time has been adjusted for daylight savings time.
        in_daylight: bool = false,

        _padding: u6 = 0,
    };

    /// 1900 - 9999
    year: u16,

    /// 1 - 12
    month: u8,

    /// 1 - 31
    day: u8,

    /// 0 - 23
    hour: u8,

    /// 0 - 59
    minute: u8,

    /// 0 - 59
    second: u8,

    /// 0 - 999999999
    nanosecond: u32 = 0,

    /// The time's offset in minutes from UTC.
    /// Allowed values are -1440 to 1440 or unspecified_timezone
    timezone: i16 = unspecified_timezone,

    /// A bitmask containing the daylight savings time information for the time.
    daylight: DaylightSavings = .{},

    /// Time is to be interpreted as local time
    pub const unspecified_timezone: i16 = 0x7ff;
};

/// Capabilities of the clock device
pub const TimeCapabilities = extern struct {
    /// Resolution in Hz
    resolution: u32,

    /// Accuracy in an error rate of 1e-6 parts per million.
    accuracy: u32,

    /// If true, a time set operation clears the device's time below the resolution level.
    sets_to_zero: bool,
};

pub const VariableAttributes = packed struct(u32) {
    non_volatile: bool = false,
    boot_service_access: bool = false,
    runtime_access: bool = false,
    hardware_error_record: bool = false,
    authenticated_write_access: bool = false, // Deprecated
    time_based_authenticated_write_access: bool = false,
    append_write: bool = false,
    enhanced_authenticated_access: bool = false,
    _padding: u24 = 0,
};

pub const ResetType = enum(u32) {
    cold,
    warm,
    shutdown,
    platform_specific,
};

pub const CapsuleFlags = packed struct(u32) {
    guid_specific: u16,
    persist_across_reset: bool = false,
    populate_system_table: bool = false,
    initiate_reset: bool = false, // If this is true, `persist_across_reset` must also be true.
    _padding: u13 = 0,
};

pub const CapsuleHeader = extern struct {
    guid: Guid,
    size: u32,
    flags: u32,
    image_size: u32,
};

pub const UefiCapsuleBlockDescriptor = extern struct {
    length: u64,
    address: extern union {
        dataBlock: uefi.EfiPhysicalAddress,
        continuationPointer: uefi.EfiPhysicalAddress,
    },
};

pub const global_variable align(8) = Guid{
    .time_low = 0x8be4df61,
    .time_mid = 0x93ca,
    .time_high_and_version = 0x11d2,
    .clock_seq_high_and_reserved = 0xaa,
    .clock_seq_low = 0x0d,
    .node = [_]u8{ 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c },
};
