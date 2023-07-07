const std = @import("../std.zig");

/// A protocol is an interface identified by a GUID.
pub const protocol = @import("uefi/protocol.zig");

pub const SystemTable = @import("uefi/table/system_table.zig").SystemTable;
pub const BootServices = @import("uefi/table/boot_services.zig").BootServices;
pub const RuntimeServices = @import("uefi/table/runtime_services.zig").RuntimeServices;
pub const ConfigurationTable = @import("uefi/table/configuration_table.zig").ConfigurationTable;

/// Status codes returned by EFI interfaces
pub const Status = @import("uefi/status.zig").Status;

/// The memory type to allocate when using the pool
/// Defaults to .LoaderData, the default data allocation type
/// used by UEFI applications to allocate pool memory.
pub var efi_pool_memory_type: tables.MemoryType = .LoaderData;
pub const pool_allocator = @import("uefi/pool_allocator.zig").pool_allocator;
pub const raw_pool_allocator = @import("uefi/pool_allocator.zig").raw_pool_allocator;

/// The EFI image's handle that is passed to its entry point.
pub var handle: Handle = undefined;

/// A pointer to the EFI System Table that is passed to the EFI image's entry point.
pub var system_table: *SystemTable = undefined;
pub var boot_services: ?*BootServices = undefined;
pub var runtime_services: *RuntimeServices = undefined;

/// A handle to an event structure.
pub const Event = *opaque {};

/// An EFI Handle represents a collection of related interfaces.
pub const Handle = *opaque {};

/// File Handle as specified in the EFI Shell Spec
pub const FileHandle = *opaque {};

pub const PhysicalAddress = u64;

/// GUIDs are align(8) unless otherwise specified.
pub const Guid = extern struct {
    time_low: u32 align(8),
    time_mid: u16,
    time_high_and_version: u16,
    clock_seq_high_and_reserved: u8,
    clock_seq_low: u8,
    node: [6]u8,

    /// Format GUID into hexadecimal lowercase xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx format
    pub fn format(
        self: @This(),
        comptime f: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (f.len == 0) {
            const fmt = std.fmt.fmtSliceHexLower;

            const time_low = @byteSwap(self.time_low);
            const time_mid = @byteSwap(self.time_mid);
            const time_high_and_version = @byteSwap(self.time_high_and_version);

            return std.fmt.format(writer, "{:0>8}-{:0>4}-{:0>4}-{:0>2}{:0>2}-{:0>12}", .{
                fmt(std.mem.asBytes(&time_low)),
                fmt(std.mem.asBytes(&time_mid)),
                fmt(std.mem.asBytes(&time_high_and_version)),
                fmt(std.mem.asBytes(&self.clock_seq_high_and_reserved)),
                fmt(std.mem.asBytes(&self.clock_seq_low)),
                fmt(std.mem.asBytes(&self.node)),
            });
        } else {
            std.fmt.invalidFmtError(f, self);
        }
    }

    pub fn eql(a: Guid, b: Guid) bool {
        return a.time_low == b.time_low and
            a.time_mid == b.time_mid and
            a.time_high_and_version == b.time_high_and_version and
            a.clock_seq_high_and_reserved == b.clock_seq_high_and_reserved and
            a.clock_seq_low == b.clock_seq_low and
            std.mem.eql(u8, &a.node, &b.node);
    }

    test Guid {
        var bytes = [_]u8{ 137, 60, 203, 50, 128, 128, 124, 66, 186, 19, 80, 73, 135, 59, 194, 135 };

        var guid: Guid = @bitCast(bytes);

        var str = try std.fmt.allocPrint(std.testing.allocator, "{}", .{guid});
        defer std.testing.allocator.free(str);

        try std.testing.expect(std.mem.eql(u8, str, "32cb3c89-8080-427c-ba13-5049873bc287"));
    }
};

pub const TableHeader = extern struct {
    /// A 64-bit signature that identifies the type of table that follows.
    signature: u64,

    /// The revision of the EFI Specification to which this table conforms
    revision: u32,

    /// The size, in bytes, of the entire table including the TableHeader
    header_size: u32,

    /// A CCITT32 checksum of the entire table (from the signature to signature + header_size) with this field set to 0.
    crc32: u32,

    /// Must always be zero.
    reserved: u32,

    /// Verify that the table is following at least the specified revision.
    pub fn isAtLeast(self: TableHeader, major: u16, minor: u8, patch: u8) bool {
        return self.revision >= (@as(u32, major) << 16) | (minor * 10) | patch;
    }

    /// Check the integrity of the table.
    pub fn check(self: *const TableHeader, signature: u64) !void {
        if (self.signature != signature) return error.InvalidTable;
        if (self.reserved != 0) return error.InvalidTable;

        const mutable: *TableHeader = @constCast(self);
        const original = self.crc32;
        var calculated: u32 = 0;

        mutable.crc32 = 0;
        _ = system_table.boot_services.?.calculateCrc32(@ptrCast(self), self.header_size, &calculated);
        mutable.crc32 = original;

        if (calculated != original) return error.InvalidTable;
    }
};

test {
}
