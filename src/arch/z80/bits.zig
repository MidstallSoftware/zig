// Based off https://www.zilog.com/docs/z80/um0080.pdf

const std = @import("std");
const DW = std.dwarf;
const assert = std.debug.assert;
const testing = std.testing;

//  Instruction Notation Summary:
//
//  r      - Indicates any of the 8-bit registers.
//
//  (HL)   - Indicates the value at the memory address stored
//           in the HL register pair.
//
//  (IX+d) - Indicates the value at the memory address stored
//           in the IX register pair plus the value of the displacement d.
//
//  (IY+d) - Indicates the value at the memory address stored
//           in the IY register pair plus the value of the displacement d.
//
//  n      - Indicates an 8-bit immediate value. (u8)
//
//  nn     - Indicates a 16-bit immediate value. (u16)
//
//  d      - Indicates an 8-bit displacement. (i8)
//
//  b      - Indicates a bit position. (u3)
//
//  e      - Indicates a relative jump offset. (i8)
//
//  cc     - Identifies the status of the Flag Register as any of (NZ, Z, NC, C, PO, PE, P,
//           or M) for the conditional jumps, calls, and return instructions
//
//  qq     - Identifies any of the register pairs BC, DE, HL or AF
//
//  ss     - Identifies any of the register pairs BC, DE, HL or SP
//
//  pp     - Identifies any of the register pairs BC, DE, IX or SP
//
//  s      - Identifies any of r, n, (HL), (IX+d) or (IY+d)
//
//  m      - Identifies any of r, (HL), (IX+d) or (IY+d)
//
//
//  Notes:
//      All Op Codes are either 0, 1, or 2 bytes long.

/// Represents the 8-bit registers.
//
//  Flag Register Bit Positions:
//  __________________________________
// | 7 | 6 | 5 | 4 | 3 |  2  | 1 | 0 |
// | S | Z | Y | H | X | P/V | N | C |
// ----------------------------------
//
//  Flag Definitions:
//
//  C - Carry Flag
//  N - Add/Subtract Flag
//  P/V - Parity/Overflow Flag
//  H - Half Carry Flag
//  Z - Zero Flag
//  S - Sign Flag
//  X - Not useds

pub const Register = enum(u3) {
    r0,
    r1,
    r2,
    r3,
    r4,
    r5,
    r6,
    r7,
};

/// Represents an instruction in the Z80 instruction set.
pub const Instruction = union(enum) {
    // Load Instructions

    /// LD r, r'
    /// Loads the value of register r' into register r.
    ///
    /// OP Code: LD
    /// Operands: r, r'
    ///
    /// Cycles: 1
    /// T States: 4
    ///
    /// No condition flags are affected.
    load_r_r: packed struct {},

    // Block Transfer Instructions

    // Arithmetic and Logic Instructions

    // Rotate and Shift Instructions

    // Bit Set, Reset, and Test Instructions

    // Jump, Call, and Return Instructions

    // Input and Output Instructions

    // CPU Control Instructions

    /// Represents the possible operations
    const Opcode = enum(u4) {
        // TODO: Fill this out.
        add,
    };
};
