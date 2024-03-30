//! Machine Intermediate Representation.
//! This data is produced by RISCV64 Codegen or RISCV64 assembly parsing
//! These instructions have a 1:1 correspondence with machine code instructions
//! for the target. MIR can be lowered to source-annotated textual assembly code
//! instructions, or it can be lowered to machine code.
//! The main purpose of MIR is to postpone the assignment of offsets until Isel,
//! so that, for example, the smaller encodings of jump instructions can be used.

instructions: std.MultiArrayList(Inst).Slice,
/// The meaning of this data is determined by `Inst.Tag` value.
extra: []const u32,

pub const Inst = struct {
    tag: Tag,
    /// The meaning of this depends on `tag`.
    data: Data,

    pub const Tag = enum(u16) {
        addi,
        addiw,
        jalr,
        lui,
        mv,

        unimp,
        ebreak,
        ecall,

        /// OR instruction. Uses r_type payload.
        @"or",

        /// Addition
        add,
        /// Subtraction
        sub,
        /// Multiply, uses r_type. Needs the M extension.
        mul,

        /// Absolute Value, uses i_type payload.
        abs,

        /// Immediate Logical Right Shift, uses i_type payload
        srli,
        /// Immediate Logical Left Shift, uses i_type payload
        slli,
        /// Register Logical Left Shift, uses r_type payload
        sllw,
        /// Register Logical Right Shit, uses r_type payload
        srlw,

        jal,
        /// Jumps. Uses `inst` payload.
        j,

        /// Immediate AND, uses i_type payload
        andi,

        // NOTE: Maybe create a special data for compares that includes the ops
        /// Register `==`, uses r_type
        cmp_eq,
        /// Register `!=`, uses r_type
        cmp_neq,
        /// Register `>`, uses r_type
        cmp_gt,
        /// Register `<`, uses r_type
        cmp_lt,
        /// Register `>=`, uses r_type
        cmp_gte,

        /// Immediate `>=`, uses r_type
        ///
        /// Note: this uses r_type because RISC-V does not provide a good way
        /// to do `>=` comparisons on immediates. Usually we would just subtract
        /// 1 from the immediate and do a `>` comparison, however there is no `>`
        /// register to immedate comparison in RISC-V. This leads us to need to
        /// allocate a register for temporary use.
        cmp_imm_gte,

        /// Immediate `==`, uses i_type
        cmp_imm_eq,
        /// Immediate `!=`, uses i_type.
        cmp_imm_neq,
        /// Immediate `<=`, uses i_type
        cmp_imm_lte,
        /// Immediate `<`, uses i_type
        cmp_imm_lt,

        /// Branch if equal, Uses b_type
        beq,
        /// Branch if not equal, Uses b_type
        bne,

        /// Boolean NOT, Uses rr payload
        not,

        nop,
        ret,

        /// Load double (64 bits)
        ld,
        /// Store double (64 bits)
        sd,
        /// Load word (32 bits)
        lw,
        /// Store word (32 bits)
        sw,
        /// Load half (16 bits)
        lh,
        /// Store half (16 bits)
        sh,
        /// Load byte (8 bits)
        lb,
        /// Store byte (8 bits)
        sb,

        /// Pseudo-instruction: End of prologue
        dbg_prologue_end,
        /// Pseudo-instruction: Beginning of epilogue
        dbg_epilogue_begin,
        /// Pseudo-instruction: Update debug line
        dbg_line,

        /// Psuedo-instruction that will generate a backpatched
        /// function prologue.
        psuedo_prologue,
        /// Psuedo-instruction that will generate a backpatched
        /// function epilogue
        psuedo_epilogue,

        /// Loads the address of a value that hasn't yet been allocated in memory.
        ///
        /// uses the Mir.LoadSymbolPayload payload.
        load_symbol,

        // TODO: add description
        // this is bad, remove this
        ldr_ptr_stack,
    };

    /// The position of an MIR instruction within the `Mir` instructions array.
    pub const Index = u32;

    /// All instructions have a 4-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        /// No additional data
        ///
        /// Used by e.g. ebreak
        nop: void,
        /// Another instruction.
        ///
        /// Used by e.g. b
        inst: Index,
        /// A 16-bit immediate value.
        ///
        /// Used by e.g. svc
        imm16: i16,
        /// A 12-bit immediate value.
        ///
        /// Used by e.g. psuedo_prologue
        imm12: i12,
        /// Index into `extra`. Meaning of what can be found there is context-dependent.
        ///
        /// Used by e.g. load_memory
        payload: u32,
        /// A register
        ///
        /// Used by e.g. blr
        reg: Register,
        /// Two registers
        ///
        /// Used by e.g. mv
        rr: struct {
            rd: Register,
            rs: Register,
        },
        /// I-Type
        ///
        /// Used by e.g. jalr
        i_type: struct {
            rd: Register,
            rs1: Register,
            imm12: i12,
        },
        /// R-Type
        ///
        /// Used by e.g. add
        r_type: struct {
            rd: Register,
            rs1: Register,
            rs2: Register,
        },
        /// B-Type
        ///
        /// Used by e.g. beq
        b_type: struct {
            rs1: Register,
            rs2: Register,
            inst: Inst.Index,
        },
        /// J-Type
        ///
        /// Used by e.g. jal
        j_type: struct {
            rd: Register,
            inst: Inst.Index,
        },
        /// U-Type
        ///
        /// Used by e.g. lui
        u_type: struct {
            rd: Register,
            imm20: i20,
        },
        /// Debug info: line and column
        ///
        /// Used by e.g. dbg_line
        dbg_line_column: struct {
            line: u32,
            column: u32,
        },
    };

    // Make sure we don't accidentally make instructions bigger than expected.
    // Note that in Debug builds, Zig is allowed to insert a secret field for safety checks.
    // comptime {
    //     if (builtin.mode != .Debug) {
    //         assert(@sizeOf(Inst) == 8);
    //     }
    // }
};

pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
    mir.instructions.deinit(gpa);
    gpa.free(mir.extra);
    mir.* = undefined;
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(mir: Mir, comptime T: type, index: usize) struct { data: T, end: usize } {
    const fields = std.meta.fields(T);
    var i: usize = index;
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => mir.extra[i],
            i32 => @as(i32, @bitCast(mir.extra[i])),
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = i,
    };
}

pub const LoadSymbolPayload = struct {
    register: u32,
    atom_index: u32,
    sym_index: u32,
};

/// Used in conjunction with payload to transfer a list of used registers in a compact manner.
pub const RegisterList = struct {
    bitset: BitSet = BitSet.initEmpty(),

    const BitSet = IntegerBitSet(32);
    const Self = @This();

    fn getIndexForReg(registers: []const Register, reg: Register) BitSet.MaskInt {
        for (registers, 0..) |cpreg, i| {
            if (reg.id() == cpreg.id()) return @intCast(i);
        }
        unreachable; // register not in input register list!
    }

    pub fn push(self: *Self, registers: []const Register, reg: Register) void {
        const index = getIndexForReg(registers, reg);
        self.bitset.set(index);
    }

    pub fn isSet(self: Self, registers: []const Register, reg: Register) bool {
        const index = getIndexForReg(registers, reg);
        return self.bitset.isSet(index);
    }

    pub fn iterator(self: Self, comptime options: std.bit_set.IteratorOptions) BitSet.Iterator(options) {
        return self.bitset.iterator(options);
    }

    pub fn count(self: Self) u32 {
        return @intCast(self.bitset.count());
    }

    pub fn size(self: Self) u32 {
        return @intCast(self.bitset.count() * 8);
    }
};

const Mir = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const bits = @import("bits.zig");
const Register = bits.Register;
const IntegerBitSet = std.bit_set.IntegerBitSet;
