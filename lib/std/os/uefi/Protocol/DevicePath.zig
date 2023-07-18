const std = @import("std");
const uefi = std.os.uefi;

const Guid = uefi.Guid;

const assert = std.debug.assert;

// All Device Path Nodes are byte-packed and may appear on any byte boundary.
// All code references to device path nodes must assume all fields are unaligned.
pub const DevicePath = extern struct {
    pub const Type = enum(u8) {
        hardware = 0x01,
        acpi = 0x02,
        messaging = 0x03,
        media = 0x04,
        bios_boot = 0x05,
        end = 0x7f,
        _,
    };

    header: PathHeader,
    hardware: HardwarePath,
    acpi: AcpiPath,
    messaging: MessagingPath,
    media: MediaPath,
    bios_boot: BiosBootPath,
    end: EndPath,

    pub const guid = Guid{
        .time_low = 0x09576e91,
        .time_mid = 0x6d3f,
        .time_high_and_version = 0x11d2,
        .clock_seq_high_and_reserved = 0x8e,
        .clock_seq_low = 0x39,
        .node = [_]u8{ 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b },
    };

    pub const loaded_image_guid = Guid{
        .time_low = 0xbc62157e,
        .time_mid = 0x3e33,
        .time_high_and_version = 0x4fec,
        .clock_seq_high_and_reserved = 0x99,
        .clock_seq_low = 0x20,
        .node = [_]u8{ 0x2d, 0x3b, 0x36, 0xd7, 0x50, 0xdf },
    };

    pub const PathHeader = extern struct {
        comptime {
            assert(@sizeOf(@This()) == 4);
        }

        type: Type,
        subtype: u8,
        length: u16 align(1),

        pub fn data(this: *const @This()) []const u8 {
            return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
        }
    };

    pub const HardwarePath = extern union {
        pub const Subtype = enum(u8) {
            pci = 1,
            pccard = 2,
            memory_mapped = 3,
            vendor = 4,
            controller = 5,
            bmc = 6,
            _,
        };

        header: Header,
        pci: Pci,
        pccard: PcCard,
        memory_mapped: MemoryMapped,
        vendor: Vendor,
        controller: Controller,
        bmc: Bmc,

        pub const Header = extern struct {
            type: Type,
            subtype: Subtype,
            length: u16 align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const Pci = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 6);
            }

            header: Header = .{ .type = .hardware, .subtype = .pci, .length = @sizeOf(@This()) },
            function: u8,
            device: u8,
        };

        pub const PcCard = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 5);
            }

            header: Header = .{ .type = .hardware, .subtype = .pccard, .length = @sizeOf(@This()) },
            function: u8,
        };

        pub const MemoryMapped = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 24);
            }

            header: Header = .{ .type = .hardware, .subtype = .memory_mapped, .length = @sizeOf(@This()) },
            memory_type: u32 align(1),
            start_address: u64 align(1),
            end_address: u64 align(1),
        };

        pub const Vendor = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .hardware, .subtype = .vendor, .length = @sizeOf(@This()) },
            vendor_guid: Guid align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const Controller = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 8);
            }

            header: Header = .{ .type = .hardware, .subtype = .controller, .length = @sizeOf(@This()) },
            number: u32 align(1),
        };

        pub const Bmc = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 13);
            }

            header: Header = .{ .type = .hardware, .subtype = .bmc, .length = @sizeOf(@This()) },
            interface_type: u8,
            base_address: u64 align(1),
        };
    };

    pub const AcpiPath = extern union {
        pub const Subtype = enum(u8) {
            acpi = 1,
            expanded_acpi = 2,
            adr = 3,
            _,
        };

        header: Header,
        acpi: BaseAcpi,
        expanded_acpi: ExpandedAcpi,
        adr: Adr,

        pub const Header = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            type: Type,
            subtype: Subtype,
            length: u16 align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const BaseAcpi = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 12);
            }

            header: Header = .{ .type = .acpi, .subtype = .acpi, .length = @sizeOf(@This()) },
            hid: u32 align(1),
            uid: u32 align(1),
        };

        pub const ExpandedAcpi = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 16);
            }

            header: Header = .{ .type = .acpi, .subtype = .expanded_acpi, .length = @sizeOf(@This()) },
            hid: u32 align(1),
            uid: u32 align(1),
            cid: u32 align(1),
            // variable length u16[*:0] strings
            // hid_str, uid_str, cid_str

            pub fn hid_str(this: *const ExpandedAcpi) [*:0]const u8 {
                const byte_ptr: [*]const u8 = @ptrCast(this);
                return @ptrCast(byte_ptr + @sizeOf(@This()));
            }

            pub fn uid_str(this: *const ExpandedAcpi) [*:0]const u8 {
                var byte_ptr: [*]const u8 = @ptrCast(this);
                byte_ptr += @sizeOf(@This());

                while (byte_ptr[0] != 0)
                    byte_ptr += 1;
                byte_ptr += 1; // skip the null terminator

                return @ptrCast(byte_ptr);
            }

            pub fn cid_str(this: *const ExpandedAcpi) [*:0]const u8 {
                var byte_ptr: [*]const u8 = @ptrCast(this);
                byte_ptr += @sizeOf(@This());

                while (byte_ptr[0] != 0)
                    byte_ptr += 1;
                byte_ptr += 1; // skip the null terminator

                while (byte_ptr[0] != 0)
                    byte_ptr += 1;
                byte_ptr += 1; // skip the null terminator

                return @ptrCast(byte_ptr);
            }
        };

        pub const Adr = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            header: Header = .{ .type = .acpi, .subtype = .adr, .length = @sizeOf(@This()) },

            pub fn adr(this: *const Adr) []align(1) const u32 {
                const byte_ptr: [*]const u8 = @ptrCast(this);
                const adr_ptr: [*]const u32 = @ptrCast(byte_ptr + @sizeOf(@This()));
                const entries = (this.header.length - @sizeOf(@This())) / @sizeOf(u32);
                return adr_ptr[0..entries];
            }
        };
    };

    pub const MessagingPath = extern union {
        pub const Subtype = enum(u8) {
            atapi = 1,
            scsi = 2,
            fibre_channel = 3,
            fibre_channel_ex = 21,
            @"1394" = 4,
            usb = 5,
            sata = 18,
            usb_wwid = 16,
            lun = 17,
            usb_class = 15,
            i2o = 6,
            mac_address = 11,
            ipv4 = 12,
            ipv6 = 13,
            vlan = 20,
            infiniband = 9,
            uart = 14,
            vendor = 10,
            _,
        };

        header: Header,
        atapi: Atapi,
        scsi: Scsi,
        fibre_channel: FibreChannel,
        fibre_channel_ex: FibreChannelEx,
        @"1394": @"1394",
        usb: Usb,
        sata: Sata,
        usb_wwid: UsbWwid,
        lun: DeviceLogicalUnit,
        usb_class: UsbClass,
        i2o: I2o,
        mac_address: MacAddress,
        ipv4: Ipv4,
        ipv6: Ipv6,
        vlan: Vlan,
        infiniband: InfiniBand,
        uart: Uart,
        vendor: Vendor,

        pub const Header = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            type: Type,
            subtype: Subtype,
            length: u16 align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const Atapi = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 8);
            }

            const Role = enum(u8) {
                master = 0,
                slave = 1,
            };

            const Rank = enum(u8) {
                primary = 0,
                secondary = 1,
            };

            header: Header = .{ .type = .messaging, .subtype = .atapi, .length = @sizeOf(@This()) },
            primary_secondary: Rank,
            slave_master: Role,
            logical_unit_number: u16 align(1),
        };

        pub const Scsi = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 8);
            }

            header: Header = .{ .type = .messaging, .subtype = .scsi, .length = @sizeOf(@This()) },
            target_id: u16 align(1),
            logical_unit_number: u16 align(1),
        };

        pub const FibreChannel = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 24);
            }

            header: Header = .{ .type = .messaging, .subtype = .fibre_channel, .length = @sizeOf(@This()) },
            reserved: u32 align(1),
            world_wide_name: u64 align(1),
            logical_unit_number: u64 align(1),
        };

        pub const FibreChannelEx = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 24);
            }

            header: Header = .{ .type = .messaging, .subtype = .fibre_channel_ex, .length = @sizeOf(@This()) },
            reserved: u32 align(1),
            world_wide_name: u64 align(1),
            logical_unit_number: u64 align(1),
        };

        pub const @"1394" = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 16);
            }

            header: Header = .{ .type = .messaging, .subtype = .@"1394", .length = @sizeOf(@This()) },
            reserved: u32 align(1),
            guid: u64 align(1),
        };

        pub const Usb = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 6);
            }

            header: Header = .{ .type = .messaging, .subtype = .usb, .length = @sizeOf(@This()) },
            parent_port_number: u8,
            interface_number: u8,
        };

        pub const Sata = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 10);
            }

            header: Header = .{ .type = .messaging, .subtype = .sata, .length = @sizeOf(@This()) },
            hba_port_number: u16 align(1),
            port_multiplier_port_number: u16 align(1),
            logical_unit_number: u16 align(1),
        };

        pub const UsbWwid = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 10);
            }

            header: Header = .{ .type = .messaging, .subtype = .usb_wwid, .length = @sizeOf(@This()) },
            interface_number: u16 align(1),
            device_vendor_id: u16 align(1),
            device_product_id: u16 align(1),

            pub fn serial_number(this: *const UsbWwid) []align(1) const u16 {
                const byte_ptr: [*]const u8 = @ptrCast(this);
                const serial_len = (this.header.length - @sizeOf(@This())) / @sizeOf(u16);
                const serial_start = byte_ptr + @sizeOf(@This());
                return serial_start[0..serial_len];
            }
        };

        pub const DeviceLogicalUnit = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 5);
            }

            header: Header = .{ .type = .messaging, .subtype = .lun, .length = @sizeOf(@This()) },
            lun: u8,
        };

        pub const UsbClass = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 11);
            }

            header: Header = .{ .type = .messaging, .subtype = .usb_class, .length = @sizeOf(@This()) },
            vendor_id: u16 align(1),
            product_id: u16 align(1),
            device_class: u8,
            device_subclass: u8,
            device_protocol: u8,
        };

        pub const I2o = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 8);
            }

            header: Header = .{ .type = .messaging, .subtype = .i2o, .length = @sizeOf(@This()) },
            tid: u32 align(1),
        };

        pub const MacAddress = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 37);
            }

            header: Header = .{ .type = .messaging, .subtype = .mac_address, .length = @sizeOf(@This()) },
            mac_address: uefi.MacAddress,
            if_type: u8,
        };

        pub const Ipv4 = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 27);
            }

            pub const IpType = enum(u8) {
                dhcp = 0,
                static = 1,
            };

            header: Header = .{ .type = .messaging, .subtype = .ipv4, .length = @sizeOf(@This()) },
            local_ip_address: uefi.Ipv4Address align(1),
            remote_ip_address: uefi.Ipv4Address align(1),
            local_port: u16 align(1),
            remote_port: u16 align(1),
            network_protocol: u16 align(1),
            static_ip_address: IpType,
            gateway_ip_address: uefi.Ipv4Address align(1),
            subnet_mask: uefi.Ipv4Address align(1),
        };

        pub const Ipv6 = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 60);
            }

            pub const Origin = enum(u8) {
                manual = 0,
                assigned_stateless = 1,
                assigned_stateful = 2,
            };

            header: Header = .{ .type = .messaging, .subtype = .ipv6, .length = @sizeOf(@This()) },
            local_ip_address: uefi.Ipv6Address,
            remote_ip_address: uefi.Ipv6Address,
            local_port: u16 align(1),
            remote_port: u16 align(1),
            protocol: u16 align(1),
            ip_address_origin: Origin,
            prefix_length: u8,
            gateway_ip_address: uefi.Ipv6Address,
        };

        pub const Vlan = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 6);
            }

            header: Header = .{ .type = .messaging, .subtype = .vlan, .length = @sizeOf(@This()) },
            vlan_id: u16 align(1),
        };

        pub const InfiniBand = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 48);
            }

            pub const ResourceFlags = packed struct(u32) {
                pub const ControllerType = enum(u1) {
                    ioc = 0,
                    service = 1,
                };

                ioc_or_service: ControllerType,
                extend_boot_environment: bool,
                console_protocol: bool,
                storage_protocol: bool,
                network_protocol: bool,

                reserved: u27,
            };

            header: Header = .{ .type = .messaging, .subtype = .infiniband, .length = @sizeOf(@This()) },
            resource_flags: ResourceFlags align(1),
            port_gid: [16]u8,
            service_id: u64 align(1),
            target_port_id: u64 align(1),
            device_id: u64 align(1),
        };

        pub const Uart = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 19);
            }

            pub const Parity = enum(u8) {
                default = 0,
                none = 1,
                even = 2,
                odd = 3,
                mark = 4,
                space = 5,
                _,
            };

            pub const StopBits = enum(u8) {
                default = 0,
                one = 1,
                one_half = 2,
                two = 3,
                _,
            };

            header: Header = .{ .type = .messaging, .subtype = .uart, .length = @sizeOf(@This()) },
            reserved: u32 align(1),
            baud_rate: u64 align(1),
            data_bits: u8,
            parity: Parity,
            stop_bits: StopBits,
        };

        pub const Vendor = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .messaging, .subtype = .vendor, .length = @sizeOf(@This()) },
            vendor_guid: Guid align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };
    };

    pub const MediaPath = extern union {
        hard_drive: HardDrive,
        cdrom: Cdrom,
        vendor: Vendor,
        file_path: FilePath,
        media_protocol: MediaProtocol,
        piwg_firmware_file: PiwgFirmwareFile,
        piwg_firmware_volume: PiwgFirmwareVolume,
        relative_offset_range: RelativeOffsetRange,
        ram_disk: RamDisk,

        pub const Subtype = enum(u8) {
            hard_drive = 1,
            cdrom = 2,
            vendor = 3,
            file_path = 4,
            media_protocol = 5,
            piwg_firmware_file = 6,
            piwg_firmware_volume = 7,
            relative_offset_range = 8,
            ram_disk = 9,
            _,
        };

        pub const Header = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            type: Type,
            subtype: Subtype,
            length: u16 align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const HardDrive = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 42);
            }

            pub const Format = enum(u8) {
                mbr = 0x01,
                gpt = 0x02,
            };

            pub const Signature = enum(u8) {
                none = 0x00,
                /// "32-bit signature from address 0x1b8 of the type 0x01 MBR"
                mbr = 0x01,
                guid = 0x02,
            };

            header: Header = .{ .type = .media, .subtype = .hard_drive, .length = @sizeOf(@This()) },
            partition_number: u32 align(1),
            partition_start: u64 align(1),
            partition_size: u64 align(1),
            partition_signature: [16]u8,
            partition_format: Format,
            signature_type: Signature,
        };

        pub const Cdrom = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 24);
            }

            header: Header = .{ .type = .media, .subtype = .cdrom, .length = @sizeOf(@This()) },
            boot_entry: u32 align(1),
            partition_start: u64 align(1),
            partition_size: u64 align(1),
        };

        pub const Vendor = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .media, .subtype = .vendor, .length = @sizeOf(@This()) },
            guid: Guid align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const FilePath = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            header: Header = .{ .type = .media, .subtype = .file_path, .length = @sizeOf(@This()) },

            pub fn path(this: *const FilePath) [*:0]align(1) const u16 {
                const byte_ptr: [*]const u8 = @ptrCast(this);
                return @ptrCast(byte_ptr + @sizeOf(@This()));
            }
        };

        pub const MediaProtocol = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .media, .subtype = .media_protocol, .length = @sizeOf(@This()) },
            guid: Guid align(1),
        };

        pub const PiwgFirmwareFile = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .media, .subtype = .piwg_firmware_file, .length = @sizeOf(@This()) },
            fv_filename: Guid align(1),
        };

        pub const PiwgFirmwareVolume = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 20);
            }

            header: Header = .{ .type = .media, .subtype = .piwg_firmware_volume, .length = @sizeOf(@This()) },
            fv_name: Guid align(1),
        };

        pub const RelativeOffsetRange = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 24);
            }

            header: Header = .{ .type = .media, .subtype = .relative_offset_range, .length = @sizeOf(@This()) },
            reserved: u32 align(1),
            start: u64 align(1),
            end: u64 align(1),
        };

        pub const RamDisk = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 38);
            }

            header: Header = .{ .type = .media, .subtype = .ram_disk, .length = @sizeOf(@This()) },
            start: u64 align(1),
            end: u64 align(1),
            disk_type: Guid align(1),
            instance: u16 align(1),

            pub const virtual_disk_guid = Guid{
                .time_low = 0x77ab535a,
                .time_mid = 0x45fc,
                .time_high_and_version = 0x624b,
                .clock_seq_high_and_reserved = 0x55,
                .clock_seq_low = 0x60,
                .node = [_]u8{ 0xf7, 0xb2, 0x81, 0xd1, 0xf9, 0x6e },
            };

            pub const virtual_cd_guid = Guid{
                .time_low = 0x3d5abd30,
                .time_mid = 0x4175,
                .time_high_and_version = 0x87ce,
                .clock_seq_high_and_reserved = 0x6d,
                .clock_seq_low = 0x64,
                .node = [_]u8{ 0xd2, 0xad, 0xe5, 0x23, 0xc4, 0xbb },
            };

            pub const persistent_virtual_disk_guid = Guid{
                .time_low = 0x5cea02c9,
                .time_mid = 0x4d07,
                .time_high_and_version = 0x69d3,
                .clock_seq_high_and_reserved = 0x26,
                .clock_seq_low = 0x9f,
                .node = [_]u8{ 0x44, 0x96, 0xfb, 0xe0, 0x96, 0xf9 },
            };

            pub const persistent_virtual_cd_guid = Guid{
                .time_low = 0x08018188,
                .time_mid = 0x42cd,
                .time_high_and_version = 0xbb48,
                .clock_seq_high_and_reserved = 0x10,
                .clock_seq_low = 0x0f,
                .node = [_]u8{ 0x53, 0x87, 0xd5, 0x3d, 0xed, 0x3d },
            };
        };
    };

    pub const BiosBootPath = extern union {
        pub const Subtype = enum(u8) {
            bbs101 = 1,
            _,
        };

        any: Header,
        bbs101: BBS101,

        pub const Header = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 4);
            }

            type: Type,
            subtype: Subtype,
            length: u16 align(1),

            pub fn data(this: *const @This()) []const u8 {
                return (@as([*]const u8, @ptrCast(this)) + @sizeOf(@This()))[0 .. this.length - @sizeOf(@This())];
            }
        };

        pub const BBS101 = extern struct {
            comptime {
                assert(@sizeOf(@This()) == 8);
            }

            header: Header = .{ .type = .bios_boot, .subtype = .bbs101, .length = @sizeOf(@This()) },
            device_type: u16 align(1),
            status_flag: u16 align(1),

            pub fn getDescription(this: *const BBS101) [*:0]const u8 {
                const byte_ptr: [*]const u8 = @ptrCast(this);
                return @ptrCast(byte_ptr + @sizeOf(BBS101));
            }
        };
    };

    pub const EndPath = extern struct {
        comptime {
            assert(@sizeOf(@This()) == 4);
        }

        pub const Subtype = enum(u8) {
            instance = 0x01,
            entire = 0xff,
            _,
        };

        type: Type,
        subtype: Subtype,
        length: u16 align(1),
    };

    /// Returns the next DevicePathProtocol node in the sequence, if any.
    pub fn next(this: *const DevicePath) ?*const DevicePath {
        if (this.header.type == .end and this.end.subtype == .entire)
            return null;

        const byte_ptr: [*]const u8 = @ptrCast(this);
        const next_path: *const DevicePath = @ptrCast(byte_ptr + this.header.length);

        return next_path;
    }

    /// Calculates the total length of the device path structure in bytes, including the end of device path node.
    pub fn size(this: *const DevicePath) usize {
        var node = this;

        while (node.next()) |next_node| {
            node = next_node;
        }

        return (@intFromPtr(node) + node.header.length) - @intFromPtr(this);
    }

    pub fn format(
        this: *const @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        if (fmt.len != 0) std.fmt.invalidFmtError(fmt, this);

        switch (this.header.type) {
            .hardware => try this.hardware.format(fmt, options, writer),
            .acpi => try this.acpi.format(fmt, options, writer),
            .msg => try this.messaging.format(fmt, options, writer),
            .media => try this.media.format(fmt, options, writer),
            .bios => try this.bios.format(fmt, options, writer),
            .end => try this.end.format(fmt, options, writer),
            else => try writer.print("Path(0x{x}, 0x{x}, {})", .{
                this.header.type,
                this.header.subtype,
                std.fmt.fmtSliceHexLower(this.header.data()),
            }),
        }
    }
};
