const uefi = @import("std").os.uefi;
const Guid = uefi.Guid;

pub const ConfigurationTable = extern struct {
    vendor_guid: Guid,
    vendor_table: *anyopaque,

    pub const acpi_20 = Guid{
        .time_low = 0x8868e871,
        .time_mid = 0xe4f1,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0xbc,
        .clock_seq_low = 0x22,
        .node = [_]u8{ 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 },
    };

    pub const acpi_10 = Guid{
        .time_low = 0xeb9d2d30,
        .time_mid = 0x2d88,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0x9a,
        .clock_seq_low = 0x16,
        .node = [_]u8{ 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d },
    };

    pub const sal_system = Guid{
        .time_low = 0xeb9d2d32,
        .time_mid = 0x2d88,
        .time_high_and_version = 0x113d,
        .clock_seq_high_and_reserved = 0x9a,
        .clock_seq_low = 0x16,
        .node = [_]u8{ 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d },
    };

    pub const smbios = Guid{
        .time_low = 0xeb9d2d31,
        .time_mid = 0x2d88,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0x9a,
        .clock_seq_low = 0x16,
        .node = [_]u8{ 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d },
    };

    pub const smbios3 = Guid{
        .time_low = 0xf2fd1544,
        .time_mid = 0x9794,
        .time_high_and_version = 0x4a2c,
        .clock_seq_high_and_reserved = 0x99,
        .clock_seq_low = 0x2e,
        .node = [_]u8{ 0xe5, 0xbb, 0xcf, 0x20, 0xe3, 0x94 },
    };

    pub const mps = Guid{
        .time_low = 0xeb9d2d2f,
        .time_mid = 0x2d88,
        .time_high_and_version = 0x11d3,
        .clock_seq_high_and_reserved = 0x9a,
        .clock_seq_low = 0x16,
        .node = [_]u8{ 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d },
    };

    pub const json_config_data = Guid{
        .time_low = 0x87367f87,
        .time_mid = 0x1119,
        .time_high_and_version = 0x41ce,
        .clock_seq_high_and_reserved = 0xaa,
        .clock_seq_low = 0xec,
        .node = [_]u8{ 0x8b, 0xe0, 0x11, 0x1f, 0x55, 0x8a },
    };

    pub const json_capsule_data = Guid{
        .time_low = 0x35e7a725,
        .time_mid = 0x8dd2,
        .time_high_and_version = 0x4cac,
        .clock_seq_high_and_reserved = 0x80,
        .clock_seq_low = 0x11,
        .node = [_]u8{ 0x33, 0xcd, 0xa8, 0x10, 0x90, 0x56 },
    };

    pub const json_capsule_result = Guid{
        .time_low = 0xdbc461c3,
        .time_mid = 0xb3de,
        .time_high_and_version = 0x422a,
        .clock_seq_high_and_reserved = 0xb9,
        .clock_seq_low = 0xb4,
        .node = [_]u8{ 0x98, 0x86, 0xfd, 0x49, 0xa1, 0xe5 },
    };

    pub const dtb = Guid{
        .time_low = 0xb1b621d5,
        .time_mid = 0xf19c,
        .time_high_and_version = 0x41a5,
        .clock_seq_high_and_reserved = 0x83,
        .clock_seq_low = 0x0b,
        .node = [_]u8{ 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 },
    };

    pub const RtPropertiesTable = extern struct {
        pub const guid = Guid{
            .time_low = 0xeb66918a,
            .time_mid = 0x7eef,
            .time_high_and_version = 0x402a,
            .clock_seq_high_and_reserved = 0x84,
            .clock_seq_low = 0x2e,
            .node = [_]u8{ 0x93, 0x1d, 0x21, 0xc3, 0x8a, 0xe9 },
        };

        pub const Services = packed struct(u32) {
            get_time: bool,
            set_time: bool,
            get_wakeup_time: bool,
            set_wakeup_time: bool,
            get_variable: bool,
            get_next_variable_name: bool,
            set_variable: bool,
            set_virtual_address_map: bool,
            convert_pointer: bool,
            get_next_high_monotonic_count: bool,
            reset_system: bool,
            update_capsule: bool,
            query_capsule_capabilities: bool,
            _padding: u19,
        };

        version: u16,
        length: u16,
        services_supported: Services,
    };

    pub const MemoryAttributesTable = extern struct {
        pub const guid = Guid{
            .time_low = 0xdcfa911d,
            .time_mid = 0x26eb,
            .time_high_and_version = 0x469f,
            .clock_seq_high_and_reserved = 0xa2,
            .clock_seq_low = 0x20,
            .node = [_]u8{ 0x38, 0xb7, 0xdc, 0x46, 0x12, 0x20 },
        };

        version: u32,
        number_of_entries: u32,
        descriptor_size: u32,
        flags: u32,

        // TODO: descriptor iterator
    };

    pub const ConformanceProfileTable = extern struct {
        pub const guid = Guid{
            .time_low = 0x36122546,
            .time_mid = 0xf7e7,
            .time_high_and_version = 0x4c8f,
            .clock_seq_high_and_reserved = 0xbd,
            .clock_seq_low = 0x9b,
            .node = [_]u8{ 0xeb, 0x85, 0x25, 0xb5, 0x0c, 0x0b },
        };

        version: u16,
        number_of_profiles: u16,

        // TODO: profile iterator

        pub const profile_uefi_spec = Guid{
            .time_low = 0x523c91af,
            .time_mid = 0xa195,
            .time_high_and_version = 0x4382,
            .clock_seq_high_and_reserved = 0x81,
            .clock_seq_low = 0x8d,
            .node = [_]u8{ 0x29, 0x5f, 0xe4, 0x00, 0x64, 0x65 },
        };
    };

    pub const MemoryRangeCapsuleResult = extern struct {
        pub const guid = uefi.RuntimeServices.MemoryRangeCapsule.guid;

        firmware_memory_requirement: u64,
        number_of_memory_ranges: u64,
    };

    // TODO: 4.6.6 Other Configuration Tables
};
