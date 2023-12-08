const std = @import("std");

const CodeGen = @This();

const codegen = @import("../../codegen.zig");
const link = @import("../../link.zig");
const Module = @import("../../Module.zig");
const InternPool = @import("../../InternPool.zig");
const Air = @import("../../Air.zig");
const Liveness = @import("../../Liveness.zig");
