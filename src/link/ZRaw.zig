//! The driver for the Z80 binary format.
//! Mostly in charge of making sure address are aligned corretly.
//! Doesn't do any actual linking per se.

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.link);

const link = @import("../link.zig");
const Module = @import("../Module.zig");
const InternPool = @import("../InternPool.zig");
const Air = @import("../Air.zig");
const Liveness = @import("../Liveness.zig");
const Compilation = @import("../Compilation.zig");

const ZRaw = @This();

base: link.File,

pub fn openPath(allocator: Allocator, sub_path: []const u8, options: link.Options) !*ZRaw {
    if (options.use_llvm) return error.LLVM_BackendIsUnsupportedForZ80;
    if (options.use_lld) return error.LLD_LinkingIsUnsupportedForZ80;

    const self = try createEmpty(allocator, options);
    errdefer self.base.destroy();

    const file = try options.emit.?.directory.handle.createFile(sub_path, .{ .truncate = true, .read = true });
    self.base.file = file;

    return self;
}

pub fn createEmpty(gpa: Allocator, options: link.Options) !*ZRaw {
    const self = try gpa.create(ZRaw);
    self.* = .{
        .base = .{
            .tag = .zraw,
            .options = options,
            .file = null,
            .allocator = gpa,
        },
    };
    errdefer self.deinit();

    return self;
}

pub fn deinit(self: *ZRaw) void {
    _ = self;
}

pub fn updateFunc(
    self: *ZRaw,
    module: *Module,
    func_index: InternPool.Index,
    air: Air,
    liveness: Liveness,
) !void {
    _ = self;
    _ = air;
    _ = liveness;
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const func = module.funcInfo(func_index);
    const decl = module.declPtr(func.owner_decl);
    log.debug("lowering function {s}", .{module.intern_pool.stringToSlice(decl.name)});
}

pub fn updateDecl(self: *ZRaw, module: *Module, decl_index: InternPool.DeclIndex) !void {
    _ = self;
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    const decl = module.declPtr(decl_index);
    log.debug("lowering declaration {s}", .{module.intern_pool.stringToSlice(decl.name)});
}

pub fn updateExports(
    self: *ZRaw,
    mod: *Module,
    exported: Module.Exported,
    exports: []const *Module.Export,
) !void {
    _ = mod;
    _ = self;
    _ = exports;
    const decl_index = switch (exported) {
        .decl_index => |i| i,
        .value => |val| {
            _ = val;
            @panic("TODO: implement ZRaw linker code for exporting a constant value");
        },
    };
    _ = decl_index;

    // TODO: Export regular functions, variables, etc using Linkage attributes.
}

pub fn freeDecl(self: *ZRaw, decl_index: InternPool.DeclIndex) void {
    _ = self;
    _ = decl_index;
}

pub fn flush(self: *ZRaw, comp: *Compilation, prog_node: *std.Progress.Node) link.File.FlushError!void {
    if (build_options.have_llvm and self.base.options.use_lld) {
        return error.LLD_LinkingIsUnsupportedForZ80;
    } else {
        return self.flushModule(comp, prog_node);
    }
}

pub fn flushModule(self: *ZRaw, comp: *Compilation, prog_node: *std.Progress.Node) link.File.FlushError!void {
    if (build_options.skip_non_native) {
        @panic("Attempted to compile for architecture that was disabled by build configuration");
    }

    _ = self;
    _ = comp;
    _ = prog_node;
}
