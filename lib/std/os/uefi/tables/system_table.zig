const std = @import("std");
const uefi = std.os.uefi;

/// The EFI System Table contains pointers to the runtime and boot services tables.
///
/// As the system_table may grow with new UEFI versions, it is important to check hdr.header_size.
///
/// After successfully calling boot_services.exitBootServices, console_in_handle,
/// con_in, console_out_handle, con_out, standard_error_handle, std_err, and
/// boot_services should be set to null. After setting these attributes to null,
/// hdr.crc32 must be recomputed.
pub const SystemTable = extern struct {
    hdr: uefi.TableHeader,

    /// A null-terminated string that identifies the vendor that produces the system firmware of the platform.
    firmware_vendor: [*:0]u16,

    /// A firmware vendor specific value that identifies the revision of the system firmware for the platform.
    firmware_revision: u32,

    /// The handle for the active console input device. Will be null after boot services exit.
    console_in_handle: ?uefi.Handle,

    /// A pointer to the SimpleTextInputProtocol interface on the active console input device.
    console_in: ?*const uefi.protocols.SimpleTextInputProtocol,

    /// The handle for the active console output device. Will be null after boot services exit.
    console_out_handle: ?uefi.Handle,

    /// A pointer to the SimpleTextOutputProtocol interface on the active console output device.
    console_out: ?*const uefi.protocols.SimpleTextOutputProtocol,

    /// The handle for the active standard error console device. Will be null after boot services exit.
    standard_error_handle: ?uefi.Handle,

    /// A pointer to the SimpleTextOutputProtocol interface on the active standard error console device.
    standard_error: ?*const uefi.protocols.SimpleTextOutputProtocol,

    /// A pointer to the EFI Runtime Services Table.
    runtime_services: *const uefi.RuntimeServices,

    /// A pointer to the EFI Boot Services Table. Will be null after boot services exit.
    boot_services: ?*const uefi.BootServices,

    /// The number of system configuration tables in the configuration_table array.
    number_of_table_entries: usize,

    /// A pointer to the system configuration tables.
    configuration_table: [*]uefi.ConfigurationTable,

    pub const signature = 0x5453595320494249;
};
