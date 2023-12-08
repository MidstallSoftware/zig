const std = @import("std");
const bits = @import("bits.zig");
const Register = bits.Register;

const RegisterManagerFn = @import("../../register_manager.zig").RegisterManager;

pub const c_abi_int_param_regs_caller_view = [_]Register{ .o0, .o1, .o2, .o3, .o4, .o5 };
pub const c_abi_int_param_regs_callee_view = [_]Register{ .i0, .i1, .i2, .i3, .i4, .i5 };

pub const c_abi_int_return_regs_caller_view = [_]Register{ .o0, .o1, .o2, .o3 };
pub const c_abi_int_return_regs_callee_view = [_]Register{ .i0, .i1, .i2, .i3 };

const allocatable_regs = [_]Register{
    .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7,
};

pub const RegisterManager = RegisterManagerFn(@import("CodeGen.zig"), Register, &allocatable_regs);
