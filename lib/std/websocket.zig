const std = @import("std.zig");

pub const Client = @import("websocket/Client.zig");

pub const Opcode = enum(u4) {};

pub const mask_vector_len = @max(8, std.simd.suggestVectorSize(u8));
pub const MaskVector = @Vector(mask_vector_len, u8);

pub const Frame = struct {
    fin: bool = true,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    mask: ?MaskVector = null,
    length: u64,
};
