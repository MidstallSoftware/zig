const std = @import("std");
const uefi = std.os.uefi;

const Status = uefi.Status;
const SimpleInput = uefi.Protocol.SimpleInput;

pub const SimpleInputEx = extern struct {
    _reset: *const fn (this: *const SimpleInputEx, extended: bool) callconv(.C) Status,
    _readKeyStroke: *const fn (this: *const SimpleInputEx, key_data: *KeyData) callconv(.C) Status,
    wait_for_key: uefi.Event,
    _setState: *const fn (this: *const SimpleInputEx, state: *const KeyState.ToggleState) callconv(.C) Status,
    _registerKeyNotify: *const fn (
        this: *const SimpleInputEx,
    ) callconv(.C) Status,
    _unregisterKeyNotify: *const fn (
        this: *const SimpleInputEx,
    ) callconv(.C) Status,

    /// Resets the input device hardware.
    ///
    /// Any input queues resident in memory used for buffering keystroke data are cleared and the input stream is in a known
    /// empty state after reset() has been called.
    ///
    /// As part of initialization process, the firmware/device will make a quick but reasonable attempt to verify that the device
    /// is functioning. If the `extended` flag is `true` the firmware may take an extended amount of time to verify
    /// the device is operating on reset. Otherwise the reset operation is to occur as quickly as possible.
    pub fn reset(this: *const SimpleInputEx, extended: bool) !void {
        switch (this._reset(this, extended)) {
            .success => {},
            .device_error => return error.Hardware, // The device is not functioning correctly and could not be reset.
            else => return error.Unexpected,
        }
    }

    pub fn readKeyStroke(this: *const SimpleInputEx) !?KeyData {
        var data: KeyData = undefined;
        switch (this._readKeyStroke(this, &data)) {
            .success => return data,
            .not_ready => return null, // There was no keystroke data available.
            .device_error => return error.Hardware, // The keystroke information was not returned due to hardware errors.
            .unsupported => return error.Unsupported, // The device does not support the ability to read keystroke data.
            else => return error.Unexpected,
        }
    }

    pub const guid = uefi.Guid{
        .time_low = 0xdd9e7534,
        .time_mid = 0x7762,
        .time_high_and_version = 0x4698,
        .clock_seq_high_and_reserved = 0x8c,
        .clock_seq_low = 0x14,
        .node = [_]u8{ 0xf5, 0x85, 0x17, 0xa6, 0x25, 0xaa },
    };

    pub const KeyData = extern struct {
        key: SimpleInput.InputKey,
        state: KeyState,
    };

    pub const KeyState = extern struct {
        shift_state: ShiftState,
        toggle_state: ToggleState,

        pub const ShiftState = packed struct(u32) {
            shift_right: bool,
            shift_left: bool,
            control_right: bool,
            control_left: bool,
            alt_right: bool,
            alt_left: bool,
            logo_right: bool,
            logo_left: bool,
            menu: bool,
            sys_req: bool,
            _: u21,
            valid: bool,
        };

        pub const ToggleState = packed struct(u8) {
            scroll_lock: bool,
            num_lock: bool,
            caps_lock: bool,
            _: u3,
            exposed: bool,
            valid: bool,
        };
    };
};
