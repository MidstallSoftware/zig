const std = @import("std");
const builtin = @import("builtin");
const Type = @import("type.zig").Type;
const log2 = std.math.log2;
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Target = std.Target;
const Allocator = std.mem.Allocator;
const Module = @import("Module.zig");
const Air = @import("Air.zig");
const TypedValue = @import("TypedValue.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");

pub const Value = struct {
    /// We are migrating towards using this for every Value object. However, many
    /// values are still represented the legacy way. This is indicated by using
    /// InternPool.Index.none.
    ip_index: InternPool.Index,

    /// This is the raw data, with no bookkeeping, no memory awareness,
    /// no de-duplication, and no type system awareness.
    /// This union takes advantage of the fact that the first page of memory
    /// is unmapped, giving us 4096 possible enum tags that have no payload.
    legacy: extern union {
        ptr_otherwise: *Payload,
    },

    // Keep in sync with tools/stage2_pretty_printers_common.py
    pub const Tag = enum(usize) {
        // The first section of this enum are tags that require no payload.
        // After this, the tag requires a payload.

        /// When the type is error union:
        /// * If the tag is `.@"error"`, the error union is an error.
        /// * If the tag is `.eu_payload`, the error union is a payload.
        /// * A nested error such as `anyerror!(anyerror!T)` in which the the outer error union
        ///   is non-error, but the inner error union is an error, is represented as
        ///   a tag of `.eu_payload`, with a sub-tag of `.@"error"`.
        eu_payload,
        /// When the type is optional:
        /// * If the tag is `.null_value`, the optional is null.
        /// * If the tag is `.opt_payload`, the optional is a payload.
        /// * A nested optional such as `??T` in which the the outer optional
        ///   is non-null, but the inner optional is null, is represented as
        ///   a tag of `.opt_payload`, with a sub-tag of `.null_value`.
        opt_payload,
        /// Pointer and length as sub `Value` objects.
        slice,
        /// A slice of u8 whose memory is managed externally.
        bytes,
        /// This value is repeated some number of times. The amount of times to repeat
        /// is stored externally.
        repeated,
        /// An instance of a struct, array, or vector.
        /// Each element/field stored as a `Value`.
        /// In the case of sentinel-terminated arrays, the sentinel value *is* stored,
        /// so the slice length will be one more than the type's array length.
        aggregate,
        /// An instance of a union.
        @"union",

        pub fn Type(comptime t: Tag) type {
            return switch (t) {
                .eu_payload,
                .opt_payload,
                .repeated,
                => Payload.SubValue,
                .slice => Payload.Slice,
                .bytes => Payload.Bytes,
                .aggregate => Payload.Aggregate,
                .@"union" => Payload.Union,
            };
        }

        pub fn create(comptime t: Tag, ally: Allocator, data: Data(t)) error{OutOfMemory}!Value {
            const ptr = try ally.create(t.Type());
            ptr.* = .{
                .base = .{ .tag = t },
                .data = data,
            };
            return Value{
                .ip_index = .none,
                .legacy = .{ .ptr_otherwise = &ptr.base },
            };
        }

        pub fn Data(comptime t: Tag) type {
            return std.meta.fieldInfo(t.Type(), .data).type;
        }
    };

    pub fn initPayload(payload: *Payload) Value {
        return Value{
            .ip_index = .none,
            .legacy = .{ .ptr_otherwise = payload },
        };
    }

    pub fn tag(self: Value) Tag {
        assert(self.ip_index == .none);
        return self.legacy.ptr_otherwise.tag;
    }

    /// Prefer `castTag` to this.
    pub fn cast(self: Value, comptime T: type) ?*T {
        if (self.ip_index != .none) {
            return null;
        }
        if (@hasField(T, "base_tag")) {
            return self.castTag(T.base_tag);
        }
        inline for (@typeInfo(Tag).Enum.fields) |field| {
            const t = @enumFromInt(Tag, field.value);
            if (self.legacy.ptr_otherwise.tag == t) {
                if (T == t.Type()) {
                    return @fieldParentPtr(T, "base", self.legacy.ptr_otherwise);
                }
                return null;
            }
        }
        unreachable;
    }

    pub fn castTag(self: Value, comptime t: Tag) ?*t.Type() {
        if (self.ip_index != .none) return null;

        if (self.legacy.ptr_otherwise.tag == t)
            return @fieldParentPtr(t.Type(), "base", self.legacy.ptr_otherwise);

        return null;
    }

    /// It's intentional that this function is not passed a corresponding Type, so that
    /// a Value can be copied from a Sema to a Decl prior to resolving struct/union field types.
    pub fn copy(self: Value, arena: Allocator) error{OutOfMemory}!Value {
        if (self.ip_index != .none) {
            return Value{ .ip_index = self.ip_index, .legacy = undefined };
        }
        switch (self.legacy.ptr_otherwise.tag) {
            .bytes => {
                const bytes = self.castTag(.bytes).?.data;
                const new_payload = try arena.create(Payload.Bytes);
                new_payload.* = .{
                    .base = .{ .tag = .bytes },
                    .data = try arena.dupe(u8, bytes),
                };
                return Value{
                    .ip_index = .none,
                    .legacy = .{ .ptr_otherwise = &new_payload.base },
                };
            },
            .eu_payload,
            .opt_payload,
            .repeated,
            => {
                const payload = self.cast(Payload.SubValue).?;
                const new_payload = try arena.create(Payload.SubValue);
                new_payload.* = .{
                    .base = payload.base,
                    .data = try payload.data.copy(arena),
                };
                return Value{
                    .ip_index = .none,
                    .legacy = .{ .ptr_otherwise = &new_payload.base },
                };
            },
            .slice => {
                const payload = self.castTag(.slice).?;
                const new_payload = try arena.create(Payload.Slice);
                new_payload.* = .{
                    .base = payload.base,
                    .data = .{
                        .ptr = try payload.data.ptr.copy(arena),
                        .len = try payload.data.len.copy(arena),
                    },
                };
                return Value{
                    .ip_index = .none,
                    .legacy = .{ .ptr_otherwise = &new_payload.base },
                };
            },
            .aggregate => {
                const payload = self.castTag(.aggregate).?;
                const new_payload = try arena.create(Payload.Aggregate);
                new_payload.* = .{
                    .base = payload.base,
                    .data = try arena.alloc(Value, payload.data.len),
                };
                for (new_payload.data, 0..) |*elem, i| {
                    elem.* = try payload.data[i].copy(arena);
                }
                return Value{
                    .ip_index = .none,
                    .legacy = .{ .ptr_otherwise = &new_payload.base },
                };
            },
            .@"union" => {
                const tag_and_val = self.castTag(.@"union").?.data;
                const new_payload = try arena.create(Payload.Union);
                new_payload.* = .{
                    .base = .{ .tag = .@"union" },
                    .data = .{
                        .tag = try tag_and_val.tag.copy(arena),
                        .val = try tag_and_val.val.copy(arena),
                    },
                };
                return Value{
                    .ip_index = .none,
                    .legacy = .{ .ptr_otherwise = &new_payload.base },
                };
            },
        }
    }

    fn copyPayloadShallow(self: Value, arena: Allocator, comptime T: type) error{OutOfMemory}!Value {
        const payload = self.cast(T).?;
        const new_payload = try arena.create(T);
        new_payload.* = payload.*;
        return Value{
            .ip_index = .none,
            .legacy = .{ .ptr_otherwise = &new_payload.base },
        };
    }

    pub fn format(val: Value, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = val;
        _ = fmt;
        _ = options;
        _ = writer;
        @compileError("do not use format values directly; use either fmtDebug or fmtValue");
    }

    /// This is a debug function. In order to print values in a meaningful way
    /// we also need access to the type.
    pub fn dump(
        start_val: Value,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        comptime assert(fmt.len == 0);
        if (start_val.ip_index != .none) {
            try out_stream.print("(interned: {})", .{start_val.toIntern()});
            return;
        }
        var val = start_val;
        while (true) switch (val.tag()) {
            .aggregate => {
                return out_stream.writeAll("(aggregate)");
            },
            .@"union" => {
                return out_stream.writeAll("(union value)");
            },
            .bytes => return out_stream.print("\"{}\"", .{std.zig.fmtEscapes(val.castTag(.bytes).?.data)}),
            .repeated => {
                try out_stream.writeAll("(repeated) ");
                val = val.castTag(.repeated).?.data;
            },
            .eu_payload => {
                try out_stream.writeAll("(eu_payload) ");
                val = val.castTag(.repeated).?.data;
            },
            .opt_payload => {
                try out_stream.writeAll("(opt_payload) ");
                val = val.castTag(.repeated).?.data;
            },
            .slice => return out_stream.writeAll("(slice)"),
        };
    }

    pub fn fmtDebug(val: Value) std.fmt.Formatter(dump) {
        return .{ .data = val };
    }

    pub fn fmtValue(val: Value, ty: Type, mod: *Module) std.fmt.Formatter(TypedValue.format) {
        return .{ .data = .{
            .tv = .{ .ty = ty, .val = val },
            .mod = mod,
        } };
    }

    /// Asserts that the value is representable as an array of bytes.
    /// Returns the value as a null-terminated string stored in the InternPool.
    pub fn toIpString(val: Value, ty: Type, mod: *Module) !InternPool.NullTerminatedString {
        const ip = &mod.intern_pool;
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .enum_literal => |enum_literal| enum_literal,
            .ptr => |ptr| switch (ptr.len) {
                .none => unreachable,
                else => try arrayToIpString(val, ptr.len.toValue().toUnsignedInt(mod), mod),
            },
            .aggregate => |aggregate| switch (aggregate.storage) {
                .bytes => |bytes| try ip.getOrPutString(mod.gpa, bytes),
                .elems => try arrayToIpString(val, ty.arrayLen(mod), mod),
                .repeated_elem => |elem| {
                    const byte = @intCast(u8, elem.toValue().toUnsignedInt(mod));
                    const len = @intCast(usize, ty.arrayLen(mod));
                    try ip.string_bytes.appendNTimes(mod.gpa, byte, len);
                    return ip.getOrPutTrailingString(mod.gpa, len);
                },
            },
            else => unreachable,
        };
    }

    /// Asserts that the value is representable as an array of bytes.
    /// Copies the value into a freshly allocated slice of memory, which is owned by the caller.
    pub fn toAllocatedBytes(val: Value, ty: Type, allocator: Allocator, mod: *Module) ![]u8 {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .enum_literal => |enum_literal| allocator.dupe(u8, mod.intern_pool.stringToSlice(enum_literal)),
            .ptr => |ptr| switch (ptr.len) {
                .none => unreachable,
                else => try arrayToAllocatedBytes(val, ptr.len.toValue().toUnsignedInt(mod), allocator, mod),
            },
            .aggregate => |aggregate| switch (aggregate.storage) {
                .bytes => |bytes| try allocator.dupe(u8, bytes),
                .elems => try arrayToAllocatedBytes(val, ty.arrayLen(mod), allocator, mod),
                .repeated_elem => |elem| {
                    const byte = @intCast(u8, elem.toValue().toUnsignedInt(mod));
                    const result = try allocator.alloc(u8, @intCast(usize, ty.arrayLen(mod)));
                    @memset(result, byte);
                    return result;
                },
            },
            else => unreachable,
        };
    }

    fn arrayToAllocatedBytes(val: Value, len: u64, allocator: Allocator, mod: *Module) ![]u8 {
        const result = try allocator.alloc(u8, @intCast(usize, len));
        for (result, 0..) |*elem, i| {
            const elem_val = try val.elemValue(mod, i);
            elem.* = @intCast(u8, elem_val.toUnsignedInt(mod));
        }
        return result;
    }

    fn arrayToIpString(val: Value, len_u64: u64, mod: *Module) !InternPool.NullTerminatedString {
        const gpa = mod.gpa;
        const ip = &mod.intern_pool;
        const len = @intCast(usize, len_u64);
        try ip.string_bytes.ensureUnusedCapacity(gpa, len);
        for (0..len) |i| {
            // I don't think elemValue has the possibility to affect ip.string_bytes. Let's
            // assert just to be sure.
            const prev = ip.string_bytes.items.len;
            const elem_val = try val.elemValue(mod, i);
            assert(ip.string_bytes.items.len == prev);
            const byte = @intCast(u8, elem_val.toUnsignedInt(mod));
            ip.string_bytes.appendAssumeCapacity(byte);
        }
        return ip.getOrPutTrailingString(gpa, len);
    }

    pub fn intern(val: Value, ty: Type, mod: *Module) Allocator.Error!InternPool.Index {
        if (val.ip_index != .none) return (try mod.getCoerced(val, ty)).toIntern();
        switch (val.tag()) {
            .eu_payload => {
                const pl = val.castTag(.eu_payload).?.data;
                return mod.intern(.{ .error_union = .{
                    .ty = ty.toIntern(),
                    .val = .{ .payload = try pl.intern(ty.errorUnionPayload(mod), mod) },
                } });
            },
            .opt_payload => {
                const pl = val.castTag(.opt_payload).?.data;
                return mod.intern(.{ .opt = .{
                    .ty = ty.toIntern(),
                    .val = try pl.intern(ty.optionalChild(mod), mod),
                } });
            },
            .slice => {
                const pl = val.castTag(.slice).?.data;
                const ptr = try pl.ptr.intern(ty.slicePtrFieldType(mod), mod);
                var ptr_key = mod.intern_pool.indexToKey(ptr).ptr;
                assert(ptr_key.len == .none);
                ptr_key.ty = ty.toIntern();
                ptr_key.len = try pl.len.intern(Type.usize, mod);
                return mod.intern(.{ .ptr = ptr_key });
            },
            .bytes => {
                const pl = val.castTag(.bytes).?.data;
                return mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .bytes = pl },
                } });
            },
            .repeated => {
                const pl = val.castTag(.repeated).?.data;
                return mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .repeated_elem = try pl.intern(ty.childType(mod), mod) },
                } });
            },
            .aggregate => {
                const len = @intCast(usize, ty.arrayLen(mod));
                const old_elems = val.castTag(.aggregate).?.data[0..len];
                const new_elems = try mod.gpa.alloc(InternPool.Index, old_elems.len);
                defer mod.gpa.free(new_elems);
                const ty_key = mod.intern_pool.indexToKey(ty.toIntern());
                for (new_elems, old_elems, 0..) |*new_elem, old_elem, field_i|
                    new_elem.* = try old_elem.intern(switch (ty_key) {
                        .struct_type => ty.structFieldType(field_i, mod),
                        .anon_struct_type => |info| info.types[field_i].toType(),
                        inline .array_type, .vector_type => |info| info.child.toType(),
                        else => unreachable,
                    }, mod);
                return mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .elems = new_elems },
                } });
            },
            .@"union" => {
                const pl = val.castTag(.@"union").?.data;
                return mod.intern(.{ .un = .{
                    .ty = ty.toIntern(),
                    .tag = try pl.tag.intern(ty.unionTagTypeHypothetical(mod), mod),
                    .val = try pl.val.intern(ty.unionFieldType(pl.tag, mod), mod),
                } });
            },
        }
    }

    pub fn unintern(val: Value, arena: Allocator, mod: *Module) Allocator.Error!Value {
        return if (val.ip_index == .none) val else switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .int_type,
            .ptr_type,
            .array_type,
            .vector_type,
            .opt_type,
            .anyframe_type,
            .error_union_type,
            .simple_type,
            .struct_type,
            .anon_struct_type,
            .union_type,
            .opaque_type,
            .enum_type,
            .func_type,
            .error_set_type,
            .inferred_error_set_type,

            .undef,
            .runtime_value,
            .simple_value,
            .variable,
            .extern_func,
            .func,
            .int,
            .err,
            .enum_literal,
            .enum_tag,
            .empty_enum_value,
            .float,
            => val,

            .error_union => |error_union| switch (error_union.val) {
                .err_name => val,
                .payload => |payload| Tag.eu_payload.create(arena, payload.toValue()),
            },

            .ptr => |ptr| switch (ptr.len) {
                .none => val,
                else => |len| Tag.slice.create(arena, .{
                    .ptr = val.slicePtr(mod),
                    .len = len.toValue(),
                }),
            },

            .opt => |opt| switch (opt.val) {
                .none => val,
                else => |payload| Tag.opt_payload.create(arena, payload.toValue()),
            },

            .aggregate => |aggregate| switch (aggregate.storage) {
                .bytes => |bytes| Tag.bytes.create(arena, try arena.dupe(u8, bytes)),
                .elems => |old_elems| {
                    const new_elems = try arena.alloc(Value, old_elems.len);
                    for (new_elems, old_elems) |*new_elem, old_elem| new_elem.* = old_elem.toValue();
                    return Tag.aggregate.create(arena, new_elems);
                },
                .repeated_elem => |elem| Tag.repeated.create(arena, elem.toValue()),
            },

            .un => |un| Tag.@"union".create(arena, .{
                .tag = un.tag.toValue(),
                .val = un.val.toValue(),
            }),

            .memoized_call => unreachable,
        };
    }

    pub fn toIntern(val: Value) InternPool.Index {
        assert(val.ip_index != .none);
        return val.ip_index;
    }

    /// Asserts that the value is representable as a type.
    pub fn toType(self: Value) Type {
        return self.toIntern().toType();
    }

    pub fn intFromEnum(val: Value, ty: Type, mod: *Module) Allocator.Error!Value {
        const ip = &mod.intern_pool;
        return switch (ip.indexToKey(ip.typeOf(val.toIntern()))) {
            // Assume it is already an integer and return it directly.
            .simple_type, .int_type => val,
            .enum_literal => |enum_literal| {
                const field_index = ty.enumFieldIndex(enum_literal, mod).?;
                return switch (ip.indexToKey(ty.toIntern())) {
                    // Assume it is already an integer and return it directly.
                    .simple_type, .int_type => val,
                    .enum_type => |enum_type| if (enum_type.values.len != 0)
                        enum_type.values[field_index].toValue()
                    else // Field index and integer values are the same.
                        mod.intValue(enum_type.tag_ty.toType(), field_index),
                    else => unreachable,
                };
            },
            .enum_type => |enum_type| try mod.getCoerced(val, enum_type.tag_ty.toType()),
            else => unreachable,
        };
    }

    /// Asserts the value is an integer.
    pub fn toBigInt(val: Value, space: *BigIntSpace, mod: *Module) BigIntConst {
        return val.toBigIntAdvanced(space, mod, null) catch unreachable;
    }

    /// Asserts the value is an integer.
    pub fn toBigIntAdvanced(
        val: Value,
        space: *BigIntSpace,
        mod: *Module,
        opt_sema: ?*Sema,
    ) Module.CompileError!BigIntConst {
        return switch (val.toIntern()) {
            .bool_false => BigIntMutable.init(&space.limbs, 0).toConst(),
            .bool_true => BigIntMutable.init(&space.limbs, 1).toConst(),
            .null_value => BigIntMutable.init(&space.limbs, 0).toConst(),
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .runtime_value => |runtime_value| runtime_value.val.toValue().toBigIntAdvanced(space, mod, opt_sema),
                .int => |int| switch (int.storage) {
                    .u64, .i64, .big_int => int.storage.toBigInt(space),
                    .lazy_align, .lazy_size => |ty| {
                        if (opt_sema) |sema| try sema.resolveTypeLayout(ty.toType());
                        const x = switch (int.storage) {
                            else => unreachable,
                            .lazy_align => ty.toType().abiAlignment(mod),
                            .lazy_size => ty.toType().abiSize(mod),
                        };
                        return BigIntMutable.init(&space.limbs, x).toConst();
                    },
                },
                .enum_tag => |enum_tag| enum_tag.int.toValue().toBigIntAdvanced(space, mod, opt_sema),
                .opt, .ptr => BigIntMutable.init(
                    &space.limbs,
                    (try val.getUnsignedIntAdvanced(mod, opt_sema)).?,
                ).toConst(),
                else => unreachable,
            },
        };
    }

    pub fn getFunction(val: Value, mod: *Module) ?*Module.Fn {
        return mod.funcPtrUnwrap(val.getFunctionIndex(mod));
    }

    pub fn getFunctionIndex(val: Value, mod: *Module) Module.Fn.OptionalIndex {
        return if (val.ip_index != .none) mod.intern_pool.indexToFunc(val.toIntern()) else .none;
    }

    pub fn getExternFunc(val: Value, mod: *Module) ?InternPool.Key.ExternFunc {
        return if (val.ip_index != .none) switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .extern_func => |extern_func| extern_func,
            else => null,
        } else null;
    }

    pub fn getVariable(val: Value, mod: *Module) ?InternPool.Key.Variable {
        return if (val.ip_index != .none) switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .variable => |variable| variable,
            else => null,
        } else null;
    }

    /// If the value fits in a u64, return it, otherwise null.
    /// Asserts not undefined.
    pub fn getUnsignedInt(val: Value, mod: *Module) ?u64 {
        return getUnsignedIntAdvanced(val, mod, null) catch unreachable;
    }

    /// If the value fits in a u64, return it, otherwise null.
    /// Asserts not undefined.
    pub fn getUnsignedIntAdvanced(val: Value, mod: *Module, opt_sema: ?*Sema) !?u64 {
        return switch (val.toIntern()) {
            .undef => unreachable,
            .bool_false => 0,
            .bool_true => 1,
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .undef => unreachable,
                .int => |int| switch (int.storage) {
                    .big_int => |big_int| big_int.to(u64) catch null,
                    .u64 => |x| x,
                    .i64 => |x| std.math.cast(u64, x),
                    .lazy_align => |ty| if (opt_sema) |sema|
                        (try ty.toType().abiAlignmentAdvanced(mod, .{ .sema = sema })).scalar
                    else
                        ty.toType().abiAlignment(mod),
                    .lazy_size => |ty| if (opt_sema) |sema|
                        (try ty.toType().abiSizeAdvanced(mod, .{ .sema = sema })).scalar
                    else
                        ty.toType().abiSize(mod),
                },
                .ptr => |ptr| switch (ptr.addr) {
                    .int => |int| int.toValue().getUnsignedIntAdvanced(mod, opt_sema),
                    .elem => |elem| {
                        const base_addr = (try elem.base.toValue().getUnsignedIntAdvanced(mod, opt_sema)) orelse return null;
                        const elem_ty = mod.intern_pool.typeOf(elem.base).toType().elemType2(mod);
                        return base_addr + elem.index * elem_ty.abiSize(mod);
                    },
                    .field => |field| {
                        const base_addr = (try field.base.toValue().getUnsignedIntAdvanced(mod, opt_sema)) orelse return null;
                        const struct_ty = mod.intern_pool.typeOf(field.base).toType().childType(mod);
                        if (opt_sema) |sema| try sema.resolveTypeLayout(struct_ty);
                        return base_addr + struct_ty.structFieldOffset(@intCast(usize, field.index), mod);
                    },
                    else => null,
                },
                .opt => |opt| switch (opt.val) {
                    .none => 0,
                    else => |payload| payload.toValue().getUnsignedIntAdvanced(mod, opt_sema),
                },
                else => null,
            },
        };
    }

    /// Asserts the value is an integer and it fits in a u64
    pub fn toUnsignedInt(val: Value, mod: *Module) u64 {
        return getUnsignedInt(val, mod).?;
    }

    /// Asserts the value is an integer and it fits in a i64
    pub fn toSignedInt(val: Value, mod: *Module) i64 {
        return switch (val.toIntern()) {
            .bool_false => 0,
            .bool_true => 1,
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .int => |int| switch (int.storage) {
                    .big_int => |big_int| big_int.to(i64) catch unreachable,
                    .i64 => |x| x,
                    .u64 => |x| @intCast(i64, x),
                    .lazy_align => |ty| @intCast(i64, ty.toType().abiAlignment(mod)),
                    .lazy_size => |ty| @intCast(i64, ty.toType().abiSize(mod)),
                },
                else => unreachable,
            },
        };
    }

    pub fn toBool(val: Value) bool {
        return switch (val.toIntern()) {
            .bool_true => true,
            .bool_false => false,
            else => unreachable,
        };
    }

    fn isDeclRef(val: Value, mod: *Module) bool {
        var check = val;
        while (true) switch (mod.intern_pool.indexToKey(check.toIntern())) {
            .ptr => |ptr| switch (ptr.addr) {
                .decl, .mut_decl, .comptime_field => return true,
                .eu_payload, .opt_payload => |base| check = base.toValue(),
                .elem, .field => |base_index| check = base_index.base.toValue(),
                else => return false,
            },
            else => return false,
        };
    }

    /// Write a Value's contents to `buffer`.
    ///
    /// Asserts that buffer.len >= ty.abiSize(). The buffer is allowed to extend past
    /// the end of the value in memory.
    pub fn writeToMemory(val: Value, ty: Type, mod: *Module, buffer: []u8) error{
        ReinterpretDeclRef,
        IllDefinedMemoryLayout,
        Unimplemented,
        OutOfMemory,
    }!void {
        const target = mod.getTarget();
        const endian = target.cpu.arch.endian();
        if (val.isUndef(mod)) {
            const size = @intCast(usize, ty.abiSize(mod));
            @memset(buffer[0..size], 0xaa);
            return;
        }
        switch (ty.zigTypeTag(mod)) {
            .Void => {},
            .Bool => {
                buffer[0] = @intFromBool(val.toBool());
            },
            .Int, .Enum => {
                const int_info = ty.intInfo(mod);
                const bits = int_info.bits;
                const byte_count = (bits + 7) / 8;

                var bigint_buffer: BigIntSpace = undefined;
                const bigint = val.toBigInt(&bigint_buffer, mod);
                bigint.writeTwosComplement(buffer[0..byte_count], endian);
            },
            .Float => switch (ty.floatBits(target)) {
                16 => std.mem.writeInt(u16, buffer[0..2], @bitCast(u16, val.toFloat(f16, mod)), endian),
                32 => std.mem.writeInt(u32, buffer[0..4], @bitCast(u32, val.toFloat(f32, mod)), endian),
                64 => std.mem.writeInt(u64, buffer[0..8], @bitCast(u64, val.toFloat(f64, mod)), endian),
                80 => std.mem.writeInt(u80, buffer[0..10], @bitCast(u80, val.toFloat(f80, mod)), endian),
                128 => std.mem.writeInt(u128, buffer[0..16], @bitCast(u128, val.toFloat(f128, mod)), endian),
                else => unreachable,
            },
            .Array => {
                const len = ty.arrayLen(mod);
                const elem_ty = ty.childType(mod);
                const elem_size = @intCast(usize, elem_ty.abiSize(mod));
                var elem_i: usize = 0;
                var buf_off: usize = 0;
                while (elem_i < len) : (elem_i += 1) {
                    const elem_val = try val.elemValue(mod, elem_i);
                    try elem_val.writeToMemory(elem_ty, mod, buffer[buf_off..]);
                    buf_off += elem_size;
                }
            },
            .Vector => {
                // We use byte_count instead of abi_size here, so that any padding bytes
                // follow the data bytes, on both big- and little-endian systems.
                const byte_count = (@intCast(usize, ty.bitSize(mod)) + 7) / 8;
                return writeToPackedMemory(val, ty, mod, buffer[0..byte_count], 0);
            },
            .Struct => switch (ty.containerLayout(mod)) {
                .Auto => return error.IllDefinedMemoryLayout,
                .Extern => for (ty.structFields(mod).values(), 0..) |field, i| {
                    const off = @intCast(usize, ty.structFieldOffset(i, mod));
                    const field_val = switch (val.ip_index) {
                        .none => val.castTag(.aggregate).?.data[i],
                        else => switch (mod.intern_pool.indexToKey(val.toIntern()).aggregate.storage) {
                            .bytes => |bytes| {
                                buffer[off] = bytes[i];
                                continue;
                            },
                            .elems => |elems| elems[i],
                            .repeated_elem => |elem| elem,
                        }.toValue(),
                    };
                    try writeToMemory(field_val, field.ty, mod, buffer[off..]);
                },
                .Packed => {
                    const byte_count = (@intCast(usize, ty.bitSize(mod)) + 7) / 8;
                    return writeToPackedMemory(val, ty, mod, buffer[0..byte_count], 0);
                },
            },
            .ErrorSet => {
                // TODO revisit this when we have the concept of the error tag type
                const Int = u16;
                const name = switch (mod.intern_pool.indexToKey(val.toIntern())) {
                    .err => |err| err.name,
                    .error_union => |error_union| error_union.val.err_name,
                    else => unreachable,
                };
                const int = @intCast(Module.ErrorInt, mod.global_error_set.getIndex(name).?);
                std.mem.writeInt(Int, buffer[0..@sizeOf(Int)], @intCast(Int, int), endian);
            },
            .Union => switch (ty.containerLayout(mod)) {
                .Auto => return error.IllDefinedMemoryLayout,
                .Extern => return error.Unimplemented,
                .Packed => {
                    const byte_count = (@intCast(usize, ty.bitSize(mod)) + 7) / 8;
                    return writeToPackedMemory(val, ty, mod, buffer[0..byte_count], 0);
                },
            },
            .Pointer => {
                if (ty.isSlice(mod)) return error.IllDefinedMemoryLayout;
                if (val.isDeclRef(mod)) return error.ReinterpretDeclRef;
                return val.writeToMemory(Type.usize, mod, buffer);
            },
            .Optional => {
                if (!ty.isPtrLikeOptional(mod)) return error.IllDefinedMemoryLayout;
                const child = ty.optionalChild(mod);
                const opt_val = val.optionalValue(mod);
                if (opt_val) |some| {
                    return some.writeToMemory(child, mod, buffer);
                } else {
                    return writeToMemory(try mod.intValue(Type.usize, 0), Type.usize, mod, buffer);
                }
            },
            else => return error.Unimplemented,
        }
    }

    /// Write a Value's contents to `buffer`.
    ///
    /// Both the start and the end of the provided buffer must be tight, since
    /// big-endian packed memory layouts start at the end of the buffer.
    pub fn writeToPackedMemory(
        val: Value,
        ty: Type,
        mod: *Module,
        buffer: []u8,
        bit_offset: usize,
    ) error{ ReinterpretDeclRef, OutOfMemory }!void {
        const target = mod.getTarget();
        const endian = target.cpu.arch.endian();
        if (val.isUndef(mod)) {
            const bit_size = @intCast(usize, ty.bitSize(mod));
            std.mem.writeVarPackedInt(buffer, bit_offset, bit_size, @as(u1, 0), endian);
            return;
        }
        switch (ty.zigTypeTag(mod)) {
            .Void => {},
            .Bool => {
                const byte_index = switch (endian) {
                    .Little => bit_offset / 8,
                    .Big => buffer.len - bit_offset / 8 - 1,
                };
                if (val.toBool()) {
                    buffer[byte_index] |= (@as(u8, 1) << @intCast(u3, bit_offset % 8));
                } else {
                    buffer[byte_index] &= ~(@as(u8, 1) << @intCast(u3, bit_offset % 8));
                }
            },
            .Int, .Enum => {
                if (buffer.len == 0) return;
                const bits = ty.intInfo(mod).bits;
                if (bits == 0) return;

                switch (mod.intern_pool.indexToKey((try val.intFromEnum(ty, mod)).toIntern()).int.storage) {
                    inline .u64, .i64 => |int| std.mem.writeVarPackedInt(buffer, bit_offset, bits, int, endian),
                    .big_int => |bigint| bigint.writePackedTwosComplement(buffer, bit_offset, bits, endian),
                    else => unreachable,
                }
            },
            .Float => switch (ty.floatBits(target)) {
                16 => std.mem.writePackedInt(u16, buffer, bit_offset, @bitCast(u16, val.toFloat(f16, mod)), endian),
                32 => std.mem.writePackedInt(u32, buffer, bit_offset, @bitCast(u32, val.toFloat(f32, mod)), endian),
                64 => std.mem.writePackedInt(u64, buffer, bit_offset, @bitCast(u64, val.toFloat(f64, mod)), endian),
                80 => std.mem.writePackedInt(u80, buffer, bit_offset, @bitCast(u80, val.toFloat(f80, mod)), endian),
                128 => std.mem.writePackedInt(u128, buffer, bit_offset, @bitCast(u128, val.toFloat(f128, mod)), endian),
                else => unreachable,
            },
            .Vector => {
                const elem_ty = ty.childType(mod);
                const elem_bit_size = @intCast(u16, elem_ty.bitSize(mod));
                const len = @intCast(usize, ty.arrayLen(mod));

                var bits: u16 = 0;
                var elem_i: usize = 0;
                while (elem_i < len) : (elem_i += 1) {
                    // On big-endian systems, LLVM reverses the element order of vectors by default
                    const tgt_elem_i = if (endian == .Big) len - elem_i - 1 else elem_i;
                    const elem_val = try val.elemValue(mod, tgt_elem_i);
                    try elem_val.writeToPackedMemory(elem_ty, mod, buffer, bit_offset + bits);
                    bits += elem_bit_size;
                }
            },
            .Struct => switch (ty.containerLayout(mod)) {
                .Auto => unreachable, // Sema is supposed to have emitted a compile error already
                .Extern => unreachable, // Handled in non-packed writeToMemory
                .Packed => {
                    var bits: u16 = 0;
                    const fields = ty.structFields(mod).values();
                    const storage = mod.intern_pool.indexToKey(val.toIntern()).aggregate.storage;
                    for (fields, 0..) |field, i| {
                        const field_bits = @intCast(u16, field.ty.bitSize(mod));
                        const field_val = switch (storage) {
                            .bytes => unreachable,
                            .elems => |elems| elems[i],
                            .repeated_elem => |elem| elem,
                        };
                        try field_val.toValue().writeToPackedMemory(field.ty, mod, buffer, bit_offset + bits);
                        bits += field_bits;
                    }
                },
            },
            .Union => switch (ty.containerLayout(mod)) {
                .Auto => unreachable, // Sema is supposed to have emitted a compile error already
                .Extern => unreachable, // Handled in non-packed writeToMemory
                .Packed => {
                    const field_index = ty.unionTagFieldIndex(val.unionTag(mod), mod);
                    const field_type = ty.unionFields(mod).values()[field_index.?].ty;
                    const field_val = try val.fieldValue(mod, field_index.?);

                    return field_val.writeToPackedMemory(field_type, mod, buffer, bit_offset);
                },
            },
            .Pointer => {
                assert(!ty.isSlice(mod)); // No well defined layout.
                if (val.isDeclRef(mod)) return error.ReinterpretDeclRef;
                return val.writeToPackedMemory(Type.usize, mod, buffer, bit_offset);
            },
            .Optional => {
                assert(ty.isPtrLikeOptional(mod));
                const child = ty.optionalChild(mod);
                const opt_val = val.optionalValue(mod);
                if (opt_val) |some| {
                    return some.writeToPackedMemory(child, mod, buffer, bit_offset);
                } else {
                    return writeToPackedMemory(try mod.intValue(Type.usize, 0), Type.usize, mod, buffer, bit_offset);
                }
            },
            else => @panic("TODO implement writeToPackedMemory for more types"),
        }
    }

    /// Load a Value from the contents of `buffer`.
    ///
    /// Asserts that buffer.len >= ty.abiSize(). The buffer is allowed to extend past
    /// the end of the value in memory.
    pub fn readFromMemory(
        ty: Type,
        mod: *Module,
        buffer: []const u8,
        arena: Allocator,
    ) Allocator.Error!Value {
        const target = mod.getTarget();
        const endian = target.cpu.arch.endian();
        switch (ty.zigTypeTag(mod)) {
            .Void => return Value.void,
            .Bool => {
                if (buffer[0] == 0) {
                    return Value.false;
                } else {
                    return Value.true;
                }
            },
            .Int, .Enum => |ty_tag| {
                const int_ty = switch (ty_tag) {
                    .Int => ty,
                    .Enum => ty.intTagType(mod),
                    else => unreachable,
                };
                const int_info = int_ty.intInfo(mod);
                const bits = int_info.bits;
                const byte_count = (bits + 7) / 8;
                if (bits == 0 or buffer.len == 0) return mod.getCoerced(try mod.intValue(int_ty, 0), ty);

                if (bits <= 64) switch (int_info.signedness) { // Fast path for integers <= u64
                    .signed => {
                        const val = std.mem.readVarInt(i64, buffer[0..byte_count], endian);
                        const result = (val << @intCast(u6, 64 - bits)) >> @intCast(u6, 64 - bits);
                        return mod.getCoerced(try mod.intValue(int_ty, result), ty);
                    },
                    .unsigned => {
                        const val = std.mem.readVarInt(u64, buffer[0..byte_count], endian);
                        const result = (val << @intCast(u6, 64 - bits)) >> @intCast(u6, 64 - bits);
                        return mod.getCoerced(try mod.intValue(int_ty, result), ty);
                    },
                } else { // Slow path, we have to construct a big-int
                    const Limb = std.math.big.Limb;
                    const limb_count = (byte_count + @sizeOf(Limb) - 1) / @sizeOf(Limb);
                    const limbs_buffer = try arena.alloc(Limb, limb_count);

                    var bigint = BigIntMutable.init(limbs_buffer, 0);
                    bigint.readTwosComplement(buffer[0..byte_count], bits, endian, int_info.signedness);
                    return mod.getCoerced(try mod.intValue_big(int_ty, bigint.toConst()), ty);
                }
            },
            .Float => return (try mod.intern(.{ .float = .{
                .ty = ty.toIntern(),
                .storage = switch (ty.floatBits(target)) {
                    16 => .{ .f16 = @bitCast(f16, std.mem.readInt(u16, buffer[0..2], endian)) },
                    32 => .{ .f32 = @bitCast(f32, std.mem.readInt(u32, buffer[0..4], endian)) },
                    64 => .{ .f64 = @bitCast(f64, std.mem.readInt(u64, buffer[0..8], endian)) },
                    80 => .{ .f80 = @bitCast(f80, std.mem.readInt(u80, buffer[0..10], endian)) },
                    128 => .{ .f128 = @bitCast(f128, std.mem.readInt(u128, buffer[0..16], endian)) },
                    else => unreachable,
                },
            } })).toValue(),
            .Array => {
                const elem_ty = ty.childType(mod);
                const elem_size = elem_ty.abiSize(mod);
                const elems = try arena.alloc(InternPool.Index, @intCast(usize, ty.arrayLen(mod)));
                var offset: usize = 0;
                for (elems) |*elem| {
                    elem.* = try (try readFromMemory(elem_ty, mod, buffer[offset..], arena)).intern(elem_ty, mod);
                    offset += @intCast(usize, elem_size);
                }
                return (try mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .elems = elems },
                } })).toValue();
            },
            .Vector => {
                // We use byte_count instead of abi_size here, so that any padding bytes
                // follow the data bytes, on both big- and little-endian systems.
                const byte_count = (@intCast(usize, ty.bitSize(mod)) + 7) / 8;
                return readFromPackedMemory(ty, mod, buffer[0..byte_count], 0, arena);
            },
            .Struct => switch (ty.containerLayout(mod)) {
                .Auto => unreachable, // Sema is supposed to have emitted a compile error already
                .Extern => {
                    const fields = ty.structFields(mod).values();
                    const field_vals = try arena.alloc(InternPool.Index, fields.len);
                    for (field_vals, fields, 0..) |*field_val, field, i| {
                        const off = @intCast(usize, ty.structFieldOffset(i, mod));
                        const sz = @intCast(usize, field.ty.abiSize(mod));
                        field_val.* = try (try readFromMemory(field.ty, mod, buffer[off..(off + sz)], arena)).intern(field.ty, mod);
                    }
                    return (try mod.intern(.{ .aggregate = .{
                        .ty = ty.toIntern(),
                        .storage = .{ .elems = field_vals },
                    } })).toValue();
                },
                .Packed => {
                    const byte_count = (@intCast(usize, ty.bitSize(mod)) + 7) / 8;
                    return readFromPackedMemory(ty, mod, buffer[0..byte_count], 0, arena);
                },
            },
            .ErrorSet => {
                // TODO revisit this when we have the concept of the error tag type
                const Int = u16;
                const int = std.mem.readInt(Int, buffer[0..@sizeOf(Int)], endian);
                const name = mod.global_error_set.keys()[@intCast(usize, int)];
                return (try mod.intern(.{ .err = .{
                    .ty = ty.toIntern(),
                    .name = name,
                } })).toValue();
            },
            .Pointer => {
                assert(!ty.isSlice(mod)); // No well defined layout.
                return readFromMemory(Type.usize, mod, buffer, arena);
            },
            .Optional => {
                assert(ty.isPtrLikeOptional(mod));
                const child = ty.optionalChild(mod);
                return readFromMemory(child, mod, buffer, arena);
            },
            else => @panic("TODO implement readFromMemory for more types"),
        }
    }

    /// Load a Value from the contents of `buffer`.
    ///
    /// Both the start and the end of the provided buffer must be tight, since
    /// big-endian packed memory layouts start at the end of the buffer.
    pub fn readFromPackedMemory(
        ty: Type,
        mod: *Module,
        buffer: []const u8,
        bit_offset: usize,
        arena: Allocator,
    ) Allocator.Error!Value {
        const target = mod.getTarget();
        const endian = target.cpu.arch.endian();
        switch (ty.zigTypeTag(mod)) {
            .Void => return Value.void,
            .Bool => {
                const byte = switch (endian) {
                    .Big => buffer[buffer.len - bit_offset / 8 - 1],
                    .Little => buffer[bit_offset / 8],
                };
                if (((byte >> @intCast(u3, bit_offset % 8)) & 1) == 0) {
                    return Value.false;
                } else {
                    return Value.true;
                }
            },
            .Int, .Enum => |ty_tag| {
                if (buffer.len == 0) return mod.intValue(ty, 0);
                const int_info = ty.intInfo(mod);
                const bits = int_info.bits;
                if (bits == 0) return mod.intValue(ty, 0);

                // Fast path for integers <= u64
                if (bits <= 64) {
                    const int_ty = switch (ty_tag) {
                        .Int => ty,
                        .Enum => ty.intTagType(mod),
                        else => unreachable,
                    };
                    return mod.getCoerced(switch (int_info.signedness) {
                        .signed => return mod.intValue(
                            int_ty,
                            std.mem.readVarPackedInt(i64, buffer, bit_offset, bits, endian, .signed),
                        ),
                        .unsigned => return mod.intValue(
                            int_ty,
                            std.mem.readVarPackedInt(u64, buffer, bit_offset, bits, endian, .unsigned),
                        ),
                    }, ty);
                }

                // Slow path, we have to construct a big-int
                const abi_size = @intCast(usize, ty.abiSize(mod));
                const Limb = std.math.big.Limb;
                const limb_count = (abi_size + @sizeOf(Limb) - 1) / @sizeOf(Limb);
                const limbs_buffer = try arena.alloc(Limb, limb_count);

                var bigint = BigIntMutable.init(limbs_buffer, 0);
                bigint.readPackedTwosComplement(buffer, bit_offset, bits, endian, int_info.signedness);
                return mod.intValue_big(ty, bigint.toConst());
            },
            .Float => return (try mod.intern(.{ .float = .{
                .ty = ty.toIntern(),
                .storage = switch (ty.floatBits(target)) {
                    16 => .{ .f16 = @bitCast(f16, std.mem.readPackedInt(u16, buffer, bit_offset, endian)) },
                    32 => .{ .f32 = @bitCast(f32, std.mem.readPackedInt(u32, buffer, bit_offset, endian)) },
                    64 => .{ .f64 = @bitCast(f64, std.mem.readPackedInt(u64, buffer, bit_offset, endian)) },
                    80 => .{ .f80 = @bitCast(f80, std.mem.readPackedInt(u80, buffer, bit_offset, endian)) },
                    128 => .{ .f128 = @bitCast(f128, std.mem.readPackedInt(u128, buffer, bit_offset, endian)) },
                    else => unreachable,
                },
            } })).toValue(),
            .Vector => {
                const elem_ty = ty.childType(mod);
                const elems = try arena.alloc(InternPool.Index, @intCast(usize, ty.arrayLen(mod)));

                var bits: u16 = 0;
                const elem_bit_size = @intCast(u16, elem_ty.bitSize(mod));
                for (elems, 0..) |_, i| {
                    // On big-endian systems, LLVM reverses the element order of vectors by default
                    const tgt_elem_i = if (endian == .Big) elems.len - i - 1 else i;
                    elems[tgt_elem_i] = try (try readFromPackedMemory(elem_ty, mod, buffer, bit_offset + bits, arena)).intern(elem_ty, mod);
                    bits += elem_bit_size;
                }
                return (try mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .elems = elems },
                } })).toValue();
            },
            .Struct => switch (ty.containerLayout(mod)) {
                .Auto => unreachable, // Sema is supposed to have emitted a compile error already
                .Extern => unreachable, // Handled by non-packed readFromMemory
                .Packed => {
                    var bits: u16 = 0;
                    const fields = ty.structFields(mod).values();
                    const field_vals = try arena.alloc(InternPool.Index, fields.len);
                    for (fields, 0..) |field, i| {
                        const field_bits = @intCast(u16, field.ty.bitSize(mod));
                        field_vals[i] = try (try readFromPackedMemory(field.ty, mod, buffer, bit_offset + bits, arena)).intern(field.ty, mod);
                        bits += field_bits;
                    }
                    return (try mod.intern(.{ .aggregate = .{
                        .ty = ty.toIntern(),
                        .storage = .{ .elems = field_vals },
                    } })).toValue();
                },
            },
            .Pointer => {
                assert(!ty.isSlice(mod)); // No well defined layout.
                return readFromPackedMemory(Type.usize, mod, buffer, bit_offset, arena);
            },
            .Optional => {
                assert(ty.isPtrLikeOptional(mod));
                const child = ty.optionalChild(mod);
                return readFromPackedMemory(child, mod, buffer, bit_offset, arena);
            },
            else => @panic("TODO implement readFromPackedMemory for more types"),
        }
    }

    /// Asserts that the value is a float or an integer.
    pub fn toFloat(val: Value, comptime T: type, mod: *Module) T {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .int => |int| switch (int.storage) {
                .big_int => |big_int| @floatCast(T, bigIntToFloat(big_int.limbs, big_int.positive)),
                inline .u64, .i64 => |x| {
                    if (T == f80) {
                        @panic("TODO we can't lower this properly on non-x86 llvm backend yet");
                    }
                    return @floatFromInt(T, x);
                },
                .lazy_align => |ty| @floatFromInt(T, ty.toType().abiAlignment(mod)),
                .lazy_size => |ty| @floatFromInt(T, ty.toType().abiSize(mod)),
            },
            .float => |float| switch (float.storage) {
                inline else => |x| @floatCast(T, x),
            },
            else => unreachable,
        };
    }

    /// TODO move this to std lib big int code
    fn bigIntToFloat(limbs: []const std.math.big.Limb, positive: bool) f128 {
        if (limbs.len == 0) return 0;

        const base = std.math.maxInt(std.math.big.Limb) + 1;
        var result: f128 = 0;
        var i: usize = limbs.len;
        while (i != 0) {
            i -= 1;
            const limb: f128 = @floatFromInt(f128, limbs[i]);
            result = @mulAdd(f128, base, result, limb);
        }
        if (positive) {
            return result;
        } else {
            return -result;
        }
    }

    pub fn clz(val: Value, ty: Type, mod: *Module) u64 {
        var bigint_buf: BigIntSpace = undefined;
        const bigint = val.toBigInt(&bigint_buf, mod);
        return bigint.clz(ty.intInfo(mod).bits);
    }

    pub fn ctz(val: Value, ty: Type, mod: *Module) u64 {
        var bigint_buf: BigIntSpace = undefined;
        const bigint = val.toBigInt(&bigint_buf, mod);
        return bigint.ctz(ty.intInfo(mod).bits);
    }

    pub fn popCount(val: Value, ty: Type, mod: *Module) u64 {
        var bigint_buf: BigIntSpace = undefined;
        const bigint = val.toBigInt(&bigint_buf, mod);
        return @intCast(u64, bigint.popCount(ty.intInfo(mod).bits));
    }

    pub fn bitReverse(val: Value, ty: Type, mod: *Module, arena: Allocator) !Value {
        const info = ty.intInfo(mod);

        var buffer: Value.BigIntSpace = undefined;
        const operand_bigint = val.toBigInt(&buffer, mod);

        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.bitReverse(operand_bigint, info.signedness, info.bits);

        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn byteSwap(val: Value, ty: Type, mod: *Module, arena: Allocator) !Value {
        const info = ty.intInfo(mod);

        // Bit count must be evenly divisible by 8
        assert(info.bits % 8 == 0);

        var buffer: Value.BigIntSpace = undefined;
        const operand_bigint = val.toBigInt(&buffer, mod);

        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.byteSwap(operand_bigint, info.signedness, info.bits / 8);

        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// Asserts the value is an integer and not undefined.
    /// Returns the number of bits the value requires to represent stored in twos complement form.
    pub fn intBitCountTwosComp(self: Value, mod: *Module) usize {
        var buffer: BigIntSpace = undefined;
        const big_int = self.toBigInt(&buffer, mod);
        return big_int.bitCountTwosComp();
    }

    /// Converts an integer or a float to a float. May result in a loss of information.
    /// Caller can find out by equality checking the result against the operand.
    pub fn floatCast(self: Value, dest_ty: Type, mod: *Module) !Value {
        const target = mod.getTarget();
        return (try mod.intern(.{ .float = .{
            .ty = dest_ty.toIntern(),
            .storage = switch (dest_ty.floatBits(target)) {
                16 => .{ .f16 = self.toFloat(f16, mod) },
                32 => .{ .f32 = self.toFloat(f32, mod) },
                64 => .{ .f64 = self.toFloat(f64, mod) },
                80 => .{ .f80 = self.toFloat(f80, mod) },
                128 => .{ .f128 = self.toFloat(f128, mod) },
                else => unreachable,
            },
        } })).toValue();
    }

    /// Asserts the value is a float
    pub fn floatHasFraction(self: Value, mod: *const Module) bool {
        return switch (mod.intern_pool.indexToKey(self.toIntern())) {
            .float => |float| switch (float.storage) {
                inline else => |x| @rem(x, 1) != 0,
            },
            else => unreachable,
        };
    }

    pub fn orderAgainstZero(lhs: Value, mod: *Module) std.math.Order {
        return orderAgainstZeroAdvanced(lhs, mod, null) catch unreachable;
    }

    pub fn orderAgainstZeroAdvanced(
        lhs: Value,
        mod: *Module,
        opt_sema: ?*Sema,
    ) Module.CompileError!std.math.Order {
        return switch (lhs.toIntern()) {
            .bool_false => .eq,
            .bool_true => .gt,
            else => switch (mod.intern_pool.indexToKey(lhs.toIntern())) {
                .ptr => |ptr| switch (ptr.addr) {
                    .decl, .mut_decl, .comptime_field => .gt,
                    .int => |int| int.toValue().orderAgainstZeroAdvanced(mod, opt_sema),
                    .elem => |elem| switch (try elem.base.toValue().orderAgainstZeroAdvanced(mod, opt_sema)) {
                        .lt => unreachable,
                        .gt => .gt,
                        .eq => if (elem.index == 0) .eq else .gt,
                    },
                    else => unreachable,
                },
                .int => |int| switch (int.storage) {
                    .big_int => |big_int| big_int.orderAgainstScalar(0),
                    inline .u64, .i64 => |x| std.math.order(x, 0),
                    .lazy_align, .lazy_size => |ty| return if (ty.toType().hasRuntimeBitsAdvanced(
                        mod,
                        false,
                        if (opt_sema) |sema| .{ .sema = sema } else .eager,
                    ) catch |err| switch (err) {
                        error.NeedLazy => unreachable,
                        else => |e| return e,
                    }) .gt else .eq,
                },
                .enum_tag => |enum_tag| enum_tag.int.toValue().orderAgainstZeroAdvanced(mod, opt_sema),
                .float => |float| switch (float.storage) {
                    inline else => |x| std.math.order(x, 0),
                },
                else => unreachable,
            },
        };
    }

    /// Asserts the value is comparable.
    pub fn order(lhs: Value, rhs: Value, mod: *Module) std.math.Order {
        return orderAdvanced(lhs, rhs, mod, null) catch unreachable;
    }

    /// Asserts the value is comparable.
    /// If opt_sema is null then this function asserts things are resolved and cannot fail.
    pub fn orderAdvanced(lhs: Value, rhs: Value, mod: *Module, opt_sema: ?*Sema) !std.math.Order {
        const lhs_against_zero = try lhs.orderAgainstZeroAdvanced(mod, opt_sema);
        const rhs_against_zero = try rhs.orderAgainstZeroAdvanced(mod, opt_sema);
        switch (lhs_against_zero) {
            .lt => if (rhs_against_zero != .lt) return .lt,
            .eq => return rhs_against_zero.invert(),
            .gt => {},
        }
        switch (rhs_against_zero) {
            .lt => if (lhs_against_zero != .lt) return .gt,
            .eq => return lhs_against_zero,
            .gt => {},
        }

        if (lhs.isFloat(mod) or rhs.isFloat(mod)) {
            const lhs_f128 = lhs.toFloat(f128, mod);
            const rhs_f128 = rhs.toFloat(f128, mod);
            return std.math.order(lhs_f128, rhs_f128);
        }

        var lhs_bigint_space: BigIntSpace = undefined;
        var rhs_bigint_space: BigIntSpace = undefined;
        const lhs_bigint = try lhs.toBigIntAdvanced(&lhs_bigint_space, mod, opt_sema);
        const rhs_bigint = try rhs.toBigIntAdvanced(&rhs_bigint_space, mod, opt_sema);
        return lhs_bigint.order(rhs_bigint);
    }

    /// Asserts the value is comparable. Does not take a type parameter because it supports
    /// comparisons between heterogeneous types.
    pub fn compareHetero(lhs: Value, op: std.math.CompareOperator, rhs: Value, mod: *Module) bool {
        return compareHeteroAdvanced(lhs, op, rhs, mod, null) catch unreachable;
    }

    pub fn compareHeteroAdvanced(
        lhs: Value,
        op: std.math.CompareOperator,
        rhs: Value,
        mod: *Module,
        opt_sema: ?*Sema,
    ) !bool {
        if (lhs.pointerDecl(mod)) |lhs_decl| {
            if (rhs.pointerDecl(mod)) |rhs_decl| {
                switch (op) {
                    .eq => return lhs_decl == rhs_decl,
                    .neq => return lhs_decl != rhs_decl,
                    else => {},
                }
            } else {
                switch (op) {
                    .eq => return false,
                    .neq => return true,
                    else => {},
                }
            }
        } else if (rhs.pointerDecl(mod)) |_| {
            switch (op) {
                .eq => return false,
                .neq => return true,
                else => {},
            }
        }
        return (try orderAdvanced(lhs, rhs, mod, opt_sema)).compare(op);
    }

    /// Asserts the values are comparable. Both operands have type `ty`.
    /// For vectors, returns true if comparison is true for ALL elements.
    pub fn compareAll(lhs: Value, op: std.math.CompareOperator, rhs: Value, ty: Type, mod: *Module) !bool {
        if (ty.zigTypeTag(mod) == .Vector) {
            const scalar_ty = ty.scalarType(mod);
            for (0..ty.vectorLen(mod)) |i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                if (!compareScalar(lhs_elem, op, rhs_elem, scalar_ty, mod)) {
                    return false;
                }
            }
            return true;
        }
        return compareScalar(lhs, op, rhs, ty, mod);
    }

    /// Asserts the values are comparable. Both operands have type `ty`.
    pub fn compareScalar(
        lhs: Value,
        op: std.math.CompareOperator,
        rhs: Value,
        ty: Type,
        mod: *Module,
    ) bool {
        return switch (op) {
            .eq => lhs.eql(rhs, ty, mod),
            .neq => !lhs.eql(rhs, ty, mod),
            else => compareHetero(lhs, op, rhs, mod),
        };
    }

    /// Asserts the value is comparable.
    /// For vectors, returns true if comparison is true for ALL elements.
    ///
    /// Note that `!compareAllWithZero(.eq, ...) != compareAllWithZero(.neq, ...)`
    pub fn compareAllWithZero(lhs: Value, op: std.math.CompareOperator, mod: *Module) bool {
        return compareAllWithZeroAdvancedExtra(lhs, op, mod, null) catch unreachable;
    }

    pub fn compareAllWithZeroAdvanced(
        lhs: Value,
        op: std.math.CompareOperator,
        sema: *Sema,
    ) Module.CompileError!bool {
        return compareAllWithZeroAdvancedExtra(lhs, op, sema.mod, sema);
    }

    pub fn compareAllWithZeroAdvancedExtra(
        lhs: Value,
        op: std.math.CompareOperator,
        mod: *Module,
        opt_sema: ?*Sema,
    ) Module.CompileError!bool {
        if (lhs.isInf(mod)) {
            switch (op) {
                .neq => return true,
                .eq => return false,
                .gt, .gte => return !lhs.isNegativeInf(mod),
                .lt, .lte => return lhs.isNegativeInf(mod),
            }
        }

        switch (mod.intern_pool.indexToKey(lhs.toIntern())) {
            .float => |float| switch (float.storage) {
                inline else => |x| if (std.math.isNan(x)) return op == .neq,
            },
            .aggregate => |aggregate| return switch (aggregate.storage) {
                .bytes => |bytes| for (bytes) |byte| {
                    if (!std.math.order(byte, 0).compare(op)) break false;
                } else true,
                .elems => |elems| for (elems) |elem| {
                    if (!try elem.toValue().compareAllWithZeroAdvancedExtra(op, mod, opt_sema)) break false;
                } else true,
                .repeated_elem => |elem| elem.toValue().compareAllWithZeroAdvancedExtra(op, mod, opt_sema),
            },
            else => {},
        }
        return (try orderAgainstZeroAdvanced(lhs, mod, opt_sema)).compare(op);
    }

    pub fn eql(a: Value, b: Value, ty: Type, mod: *Module) bool {
        return eqlAdvanced(a, ty, b, ty, mod, null) catch unreachable;
    }

    /// This function is used by hash maps and so treats floating-point NaNs as equal
    /// to each other, and not equal to other floating-point values.
    /// Similarly, it treats `undef` as a distinct value from all other values.
    /// This function has to be able to support implicit coercion of `a` to `ty`. That is,
    /// `ty` will be an exactly correct Type for `b` but it may be a post-coerced Type
    /// for `a`. This function must act *as if* `a` has been coerced to `ty`. This complication
    /// is required in order to make generic function instantiation efficient - specifically
    /// the insertion into the monomorphized function table.
    /// If `null` is provided for `opt_sema` then it is guaranteed no error will be returned.
    pub fn eqlAdvanced(
        a: Value,
        a_ty: Type,
        b: Value,
        ty: Type,
        mod: *Module,
        opt_sema: ?*Sema,
    ) Module.CompileError!bool {
        if (a.ip_index != .none or b.ip_index != .none) return a.ip_index == b.ip_index;

        const target = mod.getTarget();
        const a_tag = a.tag();
        const b_tag = b.tag();
        if (a_tag == b_tag) switch (a_tag) {
            .aggregate => {
                const a_field_vals = a.castTag(.aggregate).?.data;
                const b_field_vals = b.castTag(.aggregate).?.data;
                assert(a_field_vals.len == b_field_vals.len);

                switch (mod.intern_pool.indexToKey(ty.toIntern())) {
                    .anon_struct_type => |anon_struct| {
                        assert(anon_struct.types.len == a_field_vals.len);
                        for (anon_struct.types, 0..) |field_ty, i| {
                            if (!(try eqlAdvanced(a_field_vals[i], field_ty.toType(), b_field_vals[i], field_ty.toType(), mod, opt_sema))) {
                                return false;
                            }
                        }
                        return true;
                    },
                    .struct_type => |struct_type| {
                        const struct_obj = mod.structPtrUnwrap(struct_type.index).?;
                        const fields = struct_obj.fields.values();
                        assert(fields.len == a_field_vals.len);
                        for (fields, 0..) |field, i| {
                            if (!(try eqlAdvanced(a_field_vals[i], field.ty, b_field_vals[i], field.ty, mod, opt_sema))) {
                                return false;
                            }
                        }
                        return true;
                    },
                    else => {},
                }

                const elem_ty = ty.childType(mod);
                for (a_field_vals, 0..) |a_elem, i| {
                    const b_elem = b_field_vals[i];

                    if (!(try eqlAdvanced(a_elem, elem_ty, b_elem, elem_ty, mod, opt_sema))) {
                        return false;
                    }
                }
                return true;
            },
            .@"union" => {
                const a_union = a.castTag(.@"union").?.data;
                const b_union = b.castTag(.@"union").?.data;
                switch (ty.containerLayout(mod)) {
                    .Packed, .Extern => {
                        const tag_ty = ty.unionTagTypeHypothetical(mod);
                        if (!(try eqlAdvanced(a_union.tag, tag_ty, b_union.tag, tag_ty, mod, opt_sema))) {
                            // In this case, we must disregard mismatching tags and compare
                            // based on the in-memory bytes of the payloads.
                            @panic("TODO comptime comparison of extern union values with mismatching tags");
                        }
                    },
                    .Auto => {
                        const tag_ty = ty.unionTagTypeHypothetical(mod);
                        if (!(try eqlAdvanced(a_union.tag, tag_ty, b_union.tag, tag_ty, mod, opt_sema))) {
                            return false;
                        }
                    },
                }
                const active_field_ty = ty.unionFieldType(a_union.tag, mod);
                return eqlAdvanced(a_union.val, active_field_ty, b_union.val, active_field_ty, mod, opt_sema);
            },
            else => {},
        };

        if (a.pointerDecl(mod)) |a_decl| {
            if (b.pointerDecl(mod)) |b_decl| {
                return a_decl == b_decl;
            } else {
                return false;
            }
        } else if (b.pointerDecl(mod)) |_| {
            return false;
        }

        switch (ty.zigTypeTag(mod)) {
            .Type => {
                const a_type = a.toType();
                const b_type = b.toType();
                return a_type.eql(b_type, mod);
            },
            .Enum => {
                const a_val = try a.intFromEnum(ty, mod);
                const b_val = try b.intFromEnum(ty, mod);
                const int_ty = ty.intTagType(mod);
                return eqlAdvanced(a_val, int_ty, b_val, int_ty, mod, opt_sema);
            },
            .Array, .Vector => {
                const len = ty.arrayLen(mod);
                const elem_ty = ty.childType(mod);
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    const a_elem = try elemValue(a, mod, i);
                    const b_elem = try elemValue(b, mod, i);
                    if (!(try eqlAdvanced(a_elem, elem_ty, b_elem, elem_ty, mod, opt_sema))) {
                        return false;
                    }
                }
                return true;
            },
            .Pointer => switch (ty.ptrSize(mod)) {
                .Slice => {
                    const a_len = switch (a_ty.ptrSize(mod)) {
                        .Slice => a.sliceLen(mod),
                        .One => a_ty.childType(mod).arrayLen(mod),
                        else => unreachable,
                    };
                    if (a_len != b.sliceLen(mod)) {
                        return false;
                    }

                    const ptr_ty = ty.slicePtrFieldType(mod);
                    const a_ptr = switch (a_ty.ptrSize(mod)) {
                        .Slice => a.slicePtr(mod),
                        .One => a,
                        else => unreachable,
                    };
                    return try eqlAdvanced(a_ptr, ptr_ty, b.slicePtr(mod), ptr_ty, mod, opt_sema);
                },
                .Many, .C, .One => {},
            },
            .Struct => {
                // A struct can be represented with one of:
                //   .the_one_possible_value,
                //   .aggregate,
                // Note that we already checked above for matching tags, e.g. both .aggregate.
                return (try ty.onePossibleValue(mod)) != null;
            },
            .Union => {
                // Here we have to check for value equality, as-if `a` has been coerced to `ty`.
                if ((try ty.onePossibleValue(mod)) != null) {
                    return true;
                }
                return false;
            },
            .Float => {
                switch (ty.floatBits(target)) {
                    16 => return @bitCast(u16, a.toFloat(f16, mod)) == @bitCast(u16, b.toFloat(f16, mod)),
                    32 => return @bitCast(u32, a.toFloat(f32, mod)) == @bitCast(u32, b.toFloat(f32, mod)),
                    64 => return @bitCast(u64, a.toFloat(f64, mod)) == @bitCast(u64, b.toFloat(f64, mod)),
                    80 => return @bitCast(u80, a.toFloat(f80, mod)) == @bitCast(u80, b.toFloat(f80, mod)),
                    128 => return @bitCast(u128, a.toFloat(f128, mod)) == @bitCast(u128, b.toFloat(f128, mod)),
                    else => unreachable,
                }
            },
            .ComptimeFloat => {
                const a_float = a.toFloat(f128, mod);
                const b_float = b.toFloat(f128, mod);

                const a_nan = std.math.isNan(a_float);
                const b_nan = std.math.isNan(b_float);
                if (a_nan != b_nan) return false;
                if (std.math.signbit(a_float) != std.math.signbit(b_float)) return false;
                if (a_nan) return true;
                return a_float == b_float;
            },
            .Optional,
            .ErrorUnion,
            => unreachable, // handled by InternPool
            else => {},
        }
        return (try orderAdvanced(a, b, mod, opt_sema)).compare(.eq);
    }

    pub fn isComptimeMutablePtr(val: Value, mod: *Module) bool {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .ptr => |ptr| switch (ptr.addr) {
                .mut_decl, .comptime_field => true,
                .eu_payload, .opt_payload => |base_ptr| base_ptr.toValue().isComptimeMutablePtr(mod),
                .elem, .field => |base_index| base_index.base.toValue().isComptimeMutablePtr(mod),
                else => false,
            },
            else => false,
        };
    }

    pub fn canMutateComptimeVarState(val: Value, mod: *Module) bool {
        return val.isComptimeMutablePtr(mod) or switch (val.toIntern()) {
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .error_union => |error_union| switch (error_union.val) {
                    .err_name => false,
                    .payload => |payload| payload.toValue().canMutateComptimeVarState(mod),
                },
                .ptr => |ptr| switch (ptr.addr) {
                    .eu_payload, .opt_payload => |base| base.toValue().canMutateComptimeVarState(mod),
                    else => false,
                },
                .opt => |opt| switch (opt.val) {
                    .none => false,
                    else => |payload| payload.toValue().canMutateComptimeVarState(mod),
                },
                .aggregate => |aggregate| for (aggregate.storage.values()) |elem| {
                    if (elem.toValue().canMutateComptimeVarState(mod)) break true;
                } else false,
                .un => |un| un.val.toValue().canMutateComptimeVarState(mod),
                else => false,
            },
        };
    }

    /// Gets the decl referenced by this pointer.  If the pointer does not point
    /// to a decl, or if it points to some part of a decl (like field_ptr or element_ptr),
    /// this function returns null.
    pub fn pointerDecl(val: Value, mod: *Module) ?Module.Decl.Index {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .variable => |variable| variable.decl,
            .extern_func => |extern_func| extern_func.decl,
            .func => |func| mod.funcPtr(func.index).owner_decl,
            .ptr => |ptr| switch (ptr.addr) {
                .decl => |decl| decl,
                .mut_decl => |mut_decl| mut_decl.decl,
                else => null,
            },
            else => null,
        };
    }

    fn hashInt(int_val: Value, hasher: *std.hash.Wyhash, mod: *Module) void {
        var buffer: BigIntSpace = undefined;
        const big = int_val.toBigInt(&buffer, mod);
        std.hash.autoHash(hasher, big.positive);
        for (big.limbs) |limb| {
            std.hash.autoHash(hasher, limb);
        }
    }

    pub const slice_ptr_index = 0;
    pub const slice_len_index = 1;

    pub fn slicePtr(val: Value, mod: *Module) Value {
        return mod.intern_pool.slicePtr(val.toIntern()).toValue();
    }

    pub fn sliceLen(val: Value, mod: *Module) u64 {
        const ptr = mod.intern_pool.indexToKey(val.toIntern()).ptr;
        return switch (ptr.len) {
            .none => switch (mod.intern_pool.indexToKey(switch (ptr.addr) {
                .decl => |decl| mod.declPtr(decl).ty.toIntern(),
                .mut_decl => |mut_decl| mod.declPtr(mut_decl.decl).ty.toIntern(),
                .comptime_field => |comptime_field| mod.intern_pool.typeOf(comptime_field),
                else => unreachable,
            })) {
                .array_type => |array_type| array_type.len,
                else => 1,
            },
            else => ptr.len.toValue().toUnsignedInt(mod),
        };
    }

    /// Asserts the value is a single-item pointer to an array, or an array,
    /// or an unknown-length pointer, and returns the element value at the index.
    pub fn elemValue(val: Value, mod: *Module, index: usize) Allocator.Error!Value {
        return switch (val.ip_index) {
            .none => switch (val.tag()) {
                .bytes => try mod.intValue(Type.u8, val.castTag(.bytes).?.data[index]),
                .repeated => val.castTag(.repeated).?.data,
                .aggregate => val.castTag(.aggregate).?.data[index],
                .slice => val.castTag(.slice).?.data.ptr.elemValue(mod, index),
                else => unreachable,
            },
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .undef => |ty| (try mod.intern(.{
                    .undef = ty.toType().elemType2(mod).toIntern(),
                })).toValue(),
                .ptr => |ptr| switch (ptr.addr) {
                    .decl => |decl| mod.declPtr(decl).val.elemValue(mod, index),
                    .mut_decl => |mut_decl| (try mod.declPtr(mut_decl.decl).internValue(mod))
                        .toValue().elemValue(mod, index),
                    .int, .eu_payload => unreachable,
                    .opt_payload => |base| base.toValue().elemValue(mod, index),
                    .comptime_field => |field_val| field_val.toValue().elemValue(mod, index),
                    .elem => |elem| elem.base.toValue().elemValue(mod, index + @intCast(usize, elem.index)),
                    .field => |field| if (field.base.toValue().pointerDecl(mod)) |decl_index| {
                        const base_decl = mod.declPtr(decl_index);
                        const field_val = try base_decl.val.fieldValue(mod, @intCast(usize, field.index));
                        return field_val.elemValue(mod, index);
                    } else unreachable,
                },
                .opt => |opt| opt.val.toValue().elemValue(mod, index),
                .aggregate => |aggregate| {
                    const len = mod.intern_pool.aggregateTypeLen(aggregate.ty);
                    if (index < len) return switch (aggregate.storage) {
                        .bytes => |bytes| try mod.intern(.{ .int = .{
                            .ty = .u8_type,
                            .storage = .{ .u64 = bytes[index] },
                        } }),
                        .elems => |elems| elems[index],
                        .repeated_elem => |elem| elem,
                    }.toValue();
                    assert(index == len);
                    return mod.intern_pool.indexToKey(aggregate.ty).array_type.sentinel.toValue();
                },
                else => unreachable,
            },
        };
    }

    pub fn isLazyAlign(val: Value, mod: *Module) bool {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .int => |int| int.storage == .lazy_align,
            else => false,
        };
    }

    pub fn isLazySize(val: Value, mod: *Module) bool {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .int => |int| int.storage == .lazy_size,
            else => false,
        };
    }

    pub fn isRuntimeValue(val: Value, mod: *Module) bool {
        return mod.intern_pool.isRuntimeValue(val.toIntern());
    }

    /// Returns true if a Value is backed by a variable
    pub fn isVariable(val: Value, mod: *Module) bool {
        return val.ip_index != .none and switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .variable => true,
            .ptr => |ptr| switch (ptr.addr) {
                .decl => |decl_index| {
                    const decl = mod.declPtr(decl_index);
                    assert(decl.has_tv);
                    return decl.val.isVariable(mod);
                },
                .mut_decl => |mut_decl| {
                    const decl = mod.declPtr(mut_decl.decl);
                    assert(decl.has_tv);
                    return decl.val.isVariable(mod);
                },
                .int => false,
                .eu_payload, .opt_payload => |base_ptr| base_ptr.toValue().isVariable(mod),
                .comptime_field => |comptime_field| comptime_field.toValue().isVariable(mod),
                .elem, .field => |base_index| base_index.base.toValue().isVariable(mod),
            },
            else => false,
        };
    }

    pub fn isPtrToThreadLocal(val: Value, mod: *Module) bool {
        const backing_decl = mod.intern_pool.getBackingDecl(val.toIntern()).unwrap() orelse return false;
        const variable = mod.declPtr(backing_decl).getOwnedVariable(mod) orelse return false;
        return variable.is_threadlocal;
    }

    // Asserts that the provided start/end are in-bounds.
    pub fn sliceArray(
        val: Value,
        mod: *Module,
        arena: Allocator,
        start: usize,
        end: usize,
    ) error{OutOfMemory}!Value {
        // TODO: write something like getCoercedInts to avoid needing to dupe
        return switch (val.ip_index) {
            .none => switch (val.tag()) {
                .slice => val.castTag(.slice).?.data.ptr.sliceArray(mod, arena, start, end),
                .bytes => Tag.bytes.create(arena, val.castTag(.bytes).?.data[start..end]),
                .repeated => val,
                .aggregate => Tag.aggregate.create(arena, val.castTag(.aggregate).?.data[start..end]),
                else => unreachable,
            },
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .ptr => |ptr| switch (ptr.addr) {
                    .decl => |decl| try mod.declPtr(decl).val.sliceArray(mod, arena, start, end),
                    .mut_decl => |mut_decl| (try mod.declPtr(mut_decl.decl).internValue(mod)).toValue()
                        .sliceArray(mod, arena, start, end),
                    .comptime_field => |comptime_field| comptime_field.toValue()
                        .sliceArray(mod, arena, start, end),
                    .elem => |elem| elem.base.toValue()
                        .sliceArray(mod, arena, start + @intCast(usize, elem.index), end + @intCast(usize, elem.index)),
                    else => unreachable,
                },
                .aggregate => |aggregate| (try mod.intern(.{ .aggregate = .{
                    .ty = switch (mod.intern_pool.indexToKey(mod.intern_pool.typeOf(val.toIntern()))) {
                        .array_type => |array_type| try mod.arrayType(.{
                            .len = @intCast(u32, end - start),
                            .child = array_type.child,
                            .sentinel = if (end == array_type.len) array_type.sentinel else .none,
                        }),
                        .vector_type => |vector_type| try mod.vectorType(.{
                            .len = @intCast(u32, end - start),
                            .child = vector_type.child,
                        }),
                        else => unreachable,
                    }.toIntern(),
                    .storage = switch (aggregate.storage) {
                        .bytes => .{ .bytes = try arena.dupe(u8, mod.intern_pool.indexToKey(val.toIntern()).aggregate.storage.bytes[start..end]) },
                        .elems => .{ .elems = try arena.dupe(InternPool.Index, mod.intern_pool.indexToKey(val.toIntern()).aggregate.storage.elems[start..end]) },
                        .repeated_elem => |elem| .{ .repeated_elem = elem },
                    },
                } })).toValue(),
                else => unreachable,
            },
        };
    }

    pub fn fieldValue(val: Value, mod: *Module, index: usize) !Value {
        return switch (val.ip_index) {
            .none => switch (val.tag()) {
                .aggregate => {
                    const field_values = val.castTag(.aggregate).?.data;
                    return field_values[index];
                },
                .@"union" => {
                    const payload = val.castTag(.@"union").?.data;
                    // TODO assert the tag is correct
                    return payload.val;
                },
                else => unreachable,
            },
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .undef => |ty| (try mod.intern(.{
                    .undef = ty.toType().structFieldType(index, mod).toIntern(),
                })).toValue(),
                .aggregate => |aggregate| switch (aggregate.storage) {
                    .bytes => |bytes| try mod.intern(.{ .int = .{
                        .ty = .u8_type,
                        .storage = .{ .u64 = bytes[index] },
                    } }),
                    .elems => |elems| elems[index],
                    .repeated_elem => |elem| elem,
                }.toValue(),
                // TODO assert the tag is correct
                .un => |un| un.val.toValue(),
                else => unreachable,
            },
        };
    }

    pub fn unionTag(val: Value, mod: *Module) Value {
        if (val.ip_index == .none) return val.castTag(.@"union").?.data.tag;
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .undef, .enum_tag => val,
            .un => |un| un.tag.toValue(),
            else => unreachable,
        };
    }

    /// Returns a pointer to the element value at the index.
    pub fn elemPtr(
        val: Value,
        elem_ptr_ty: Type,
        index: usize,
        mod: *Module,
    ) Allocator.Error!Value {
        const elem_ty = elem_ptr_ty.childType(mod);
        const ptr_val = switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .ptr => |ptr| ptr: {
                switch (ptr.addr) {
                    .elem => |elem| if (mod.intern_pool.typeOf(elem.base).toType().elemType2(mod).eql(elem_ty, mod))
                        return (try mod.intern(.{ .ptr = .{
                            .ty = elem_ptr_ty.toIntern(),
                            .addr = .{ .elem = .{
                                .base = elem.base,
                                .index = elem.index + index,
                            } },
                        } })).toValue(),
                    else => {},
                }
                break :ptr switch (ptr.len) {
                    .none => val,
                    else => val.slicePtr(mod),
                };
            },
            else => val,
        };
        var ptr_ty_key = mod.intern_pool.indexToKey(elem_ptr_ty.toIntern()).ptr_type;
        assert(ptr_ty_key.flags.size != .Slice);
        ptr_ty_key.flags.size = .Many;
        return (try mod.intern(.{ .ptr = .{
            .ty = elem_ptr_ty.toIntern(),
            .addr = .{ .elem = .{
                .base = (try mod.getCoerced(ptr_val, try mod.ptrType(ptr_ty_key))).toIntern(),
                .index = index,
            } },
        } })).toValue();
    }

    pub fn isUndef(val: Value, mod: *Module) bool {
        return val.ip_index != .none and mod.intern_pool.isUndef(val.toIntern());
    }

    /// TODO: check for cases such as array that is not marked undef but all the element
    /// values are marked undef, or struct that is not marked undef but all fields are marked
    /// undef, etc.
    pub fn isUndefDeep(val: Value, mod: *Module) bool {
        return val.isUndef(mod);
    }

    /// Returns true if any value contained in `self` is undefined.
    pub fn anyUndef(val: Value, mod: *Module) !bool {
        if (val.ip_index == .none) return false;
        return switch (val.toIntern()) {
            .undef => true,
            else => switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .undef => true,
                .simple_value => |v| v == .undefined,
                .ptr => |ptr| switch (ptr.len) {
                    .none => false,
                    else => for (0..@intCast(usize, ptr.len.toValue().toUnsignedInt(mod))) |index| {
                        if (try (try val.elemValue(mod, index)).anyUndef(mod)) break true;
                    } else false,
                },
                .aggregate => |aggregate| for (0..aggregate.storage.values().len) |i| {
                    const elem = mod.intern_pool.indexToKey(val.toIntern()).aggregate.storage.values()[i];
                    if (try anyUndef(elem.toValue(), mod)) break true;
                } else false,
                else => false,
            },
        };
    }

    /// Asserts the value is not undefined and not unreachable.
    /// C pointers with an integer value of 0 are also considered null.
    pub fn isNull(val: Value, mod: *Module) bool {
        return switch (val.toIntern()) {
            .undef => unreachable,
            .unreachable_value => unreachable,
            .null_value => true,
            else => return switch (mod.intern_pool.indexToKey(val.toIntern())) {
                .undef => unreachable,
                .ptr => |ptr| switch (ptr.addr) {
                    .int => {
                        var buf: BigIntSpace = undefined;
                        return val.toBigInt(&buf, mod).eqZero();
                    },
                    else => false,
                },
                .opt => |opt| opt.val == .none,
                else => false,
            },
        };
    }

    /// Valid only for error (union) types. Asserts the value is not undefined and not unreachable.
    pub fn getErrorName(val: Value, mod: *const Module) InternPool.OptionalNullTerminatedString {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .err => |err| err.name.toOptional(),
            .error_union => |error_union| switch (error_union.val) {
                .err_name => |err_name| err_name.toOptional(),
                .payload => .none,
            },
            else => unreachable,
        };
    }

    pub fn getErrorInt(val: Value, mod: *const Module) Module.ErrorInt {
        return if (getErrorName(val, mod).unwrap()) |err_name|
            @intCast(Module.ErrorInt, mod.global_error_set.getIndex(err_name).?)
        else
            0;
    }

    /// Assumes the type is an error union. Returns true if and only if the value is
    /// the error union payload, not an error.
    pub fn errorUnionIsPayload(val: Value, mod: *const Module) bool {
        return mod.intern_pool.indexToKey(val.toIntern()).error_union.val == .payload;
    }

    /// Value of the optional, null if optional has no payload.
    pub fn optionalValue(val: Value, mod: *const Module) ?Value {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .opt => |opt| switch (opt.val) {
                .none => null,
                else => |payload| payload.toValue(),
            },
            .ptr => val,
            else => unreachable,
        };
    }

    /// Valid for all types. Asserts the value is not undefined.
    pub fn isFloat(self: Value, mod: *const Module) bool {
        return switch (self.toIntern()) {
            .undef => unreachable,
            else => switch (mod.intern_pool.indexToKey(self.toIntern())) {
                .undef => unreachable,
                .float => true,
                else => false,
            },
        };
    }

    pub fn floatFromInt(val: Value, arena: Allocator, int_ty: Type, float_ty: Type, mod: *Module) !Value {
        return floatFromIntAdvanced(val, arena, int_ty, float_ty, mod, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }

    pub fn floatFromIntAdvanced(val: Value, arena: Allocator, int_ty: Type, float_ty: Type, mod: *Module, opt_sema: ?*Sema) !Value {
        if (int_ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, int_ty.vectorLen(mod));
            const scalar_ty = float_ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try floatFromIntScalar(elem_val, scalar_ty, mod, opt_sema)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatFromIntScalar(val, float_ty, mod, opt_sema);
    }

    pub fn floatFromIntScalar(val: Value, float_ty: Type, mod: *Module, opt_sema: ?*Sema) !Value {
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .undef => (try mod.intern(.{ .undef = float_ty.toIntern() })).toValue(),
            .int => |int| switch (int.storage) {
                .big_int => |big_int| {
                    const float = bigIntToFloat(big_int.limbs, big_int.positive);
                    return mod.floatValue(float_ty, float);
                },
                inline .u64, .i64 => |x| floatFromIntInner(x, float_ty, mod),
                .lazy_align => |ty| if (opt_sema) |sema| {
                    return floatFromIntInner((try ty.toType().abiAlignmentAdvanced(mod, .{ .sema = sema })).scalar, float_ty, mod);
                } else {
                    return floatFromIntInner(ty.toType().abiAlignment(mod), float_ty, mod);
                },
                .lazy_size => |ty| if (opt_sema) |sema| {
                    return floatFromIntInner((try ty.toType().abiSizeAdvanced(mod, .{ .sema = sema })).scalar, float_ty, mod);
                } else {
                    return floatFromIntInner(ty.toType().abiSize(mod), float_ty, mod);
                },
            },
            else => unreachable,
        };
    }

    fn floatFromIntInner(x: anytype, dest_ty: Type, mod: *Module) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (dest_ty.floatBits(target)) {
            16 => .{ .f16 = @floatFromInt(f16, x) },
            32 => .{ .f32 = @floatFromInt(f32, x) },
            64 => .{ .f64 = @floatFromInt(f64, x) },
            80 => .{ .f80 = @floatFromInt(f80, x) },
            128 => .{ .f128 = @floatFromInt(f128, x) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = dest_ty.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    fn calcLimbLenFloat(scalar: anytype) usize {
        if (scalar == 0) {
            return 1;
        }

        const w_value = @fabs(scalar);
        return @divFloor(@intFromFloat(std.math.big.Limb, std.math.log2(w_value)), @typeInfo(std.math.big.Limb).Int.bits) + 1;
    }

    pub const OverflowArithmeticResult = struct {
        overflow_bit: Value,
        wrapped_result: Value,
    };

    /// Supports (vectors of) integers only; asserts neither operand is undefined.
    pub fn intAddSat(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try intAddSatScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intAddSatScalar(lhs, rhs, ty, arena, mod);
    }

    /// Supports integers only; asserts neither operand is undefined.
    pub fn intAddSatScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        assert(!lhs.isUndef(mod));
        assert(!rhs.isUndef(mod));

        const info = ty.intInfo(mod);

        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.addSat(lhs_bigint, rhs_bigint, info.signedness, info.bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// Supports (vectors of) integers only; asserts neither operand is undefined.
    pub fn intSubSat(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try intSubSatScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intSubSatScalar(lhs, rhs, ty, arena, mod);
    }

    /// Supports integers only; asserts neither operand is undefined.
    pub fn intSubSatScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        assert(!lhs.isUndef(mod));
        assert(!rhs.isUndef(mod));

        const info = ty.intInfo(mod);

        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.subSat(lhs_bigint, rhs_bigint, info.signedness, info.bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn intMulWithOverflow(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !OverflowArithmeticResult {
        if (ty.zigTypeTag(mod) == .Vector) {
            const vec_len = ty.vectorLen(mod);
            const overflowed_data = try arena.alloc(InternPool.Index, vec_len);
            const result_data = try arena.alloc(InternPool.Index, vec_len);
            const scalar_ty = ty.scalarType(mod);
            for (overflowed_data, result_data, 0..) |*of, *scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                const of_math_result = try intMulWithOverflowScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod);
                of.* = try of_math_result.overflow_bit.intern(Type.u1, mod);
                scalar.* = try of_math_result.wrapped_result.intern(scalar_ty, mod);
            }
            return OverflowArithmeticResult{
                .overflow_bit = (try mod.intern(.{ .aggregate = .{
                    .ty = (try mod.vectorType(.{ .len = vec_len, .child = .u1_type })).toIntern(),
                    .storage = .{ .elems = overflowed_data },
                } })).toValue(),
                .wrapped_result = (try mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .elems = result_data },
                } })).toValue(),
            };
        }
        return intMulWithOverflowScalar(lhs, rhs, ty, arena, mod);
    }

    pub fn intMulWithOverflowScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !OverflowArithmeticResult {
        const info = ty.intInfo(mod);

        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len + rhs_bigint.limbs.len,
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        var limbs_buffer = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
        );
        result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, arena);

        const overflowed = !result_bigint.toConst().fitsInTwosComp(info.signedness, info.bits);
        if (overflowed) {
            result_bigint.truncate(result_bigint.toConst(), info.signedness, info.bits);
        }

        return OverflowArithmeticResult{
            .overflow_bit = try mod.intValue(Type.u1, @intFromBool(overflowed)),
            .wrapped_result = try mod.intValue_big(ty, result_bigint.toConst()),
        };
    }

    /// Supports both (vectors of) floats and ints; handles undefined scalars.
    pub fn numberMulWrap(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try numberMulWrapScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return numberMulWrapScalar(lhs, rhs, ty, arena, mod);
    }

    /// Supports both floats and ints; handles undefined.
    pub fn numberMulWrapScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return Value.undef;

        if (ty.zigTypeTag(mod) == .ComptimeInt) {
            return intMul(lhs, rhs, ty, undefined, arena, mod);
        }

        if (ty.isAnyFloat()) {
            return floatMul(lhs, rhs, ty, arena, mod);
        }

        const overflow_result = try intMulWithOverflow(lhs, rhs, ty, arena, mod);
        return overflow_result.wrapped_result;
    }

    /// Supports (vectors of) integers only; asserts neither operand is undefined.
    pub fn intMulSat(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try intMulSatScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intMulSatScalar(lhs, rhs, ty, arena, mod);
    }

    /// Supports (vectors of) integers only; asserts neither operand is undefined.
    pub fn intMulSatScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        assert(!lhs.isUndef(mod));
        assert(!rhs.isUndef(mod));

        const info = ty.intInfo(mod);

        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            @max(
                // For the saturate
                std.math.big.int.calcTwosCompLimbCount(info.bits),
                lhs_bigint.limbs.len + rhs_bigint.limbs.len,
            ),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        var limbs_buffer = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
        );
        result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, arena);
        result_bigint.saturate(result_bigint.toConst(), info.signedness, info.bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// Supports both floats and ints; handles undefined.
    pub fn numberMax(lhs: Value, rhs: Value, mod: *Module) Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return undef;
        if (lhs.isNan(mod)) return rhs;
        if (rhs.isNan(mod)) return lhs;

        return switch (order(lhs, rhs, mod)) {
            .lt => rhs,
            .gt, .eq => lhs,
        };
    }

    /// Supports both floats and ints; handles undefined.
    pub fn numberMin(lhs: Value, rhs: Value, mod: *Module) Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return undef;
        if (lhs.isNan(mod)) return rhs;
        if (rhs.isNan(mod)) return lhs;

        return switch (order(lhs, rhs, mod)) {
            .lt => lhs,
            .gt, .eq => rhs,
        };
    }

    /// operands must be (vectors of) integers; handles undefined scalars.
    pub fn bitwiseNot(val: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try bitwiseNotScalar(elem_val, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return bitwiseNotScalar(val, ty, arena, mod);
    }

    /// operands must be integers; handles undefined.
    pub fn bitwiseNotScalar(val: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (val.isUndef(mod)) return (try mod.intern(.{ .undef = ty.toIntern() })).toValue();
        if (ty.toIntern() == .bool_type) return makeBool(!val.toBool());

        const info = ty.intInfo(mod);

        if (info.bits == 0) {
            return val;
        }

        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var val_space: Value.BigIntSpace = undefined;
        const val_bigint = val.toBigInt(&val_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits),
        );

        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.bitNotWrap(val_bigint, info.signedness, info.bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// operands must be (vectors of) integers; handles undefined scalars.
    pub fn bitwiseAnd(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try bitwiseAndScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return bitwiseAndScalar(lhs, rhs, ty, allocator, mod);
    }

    /// operands must be integers; handles undefined.
    pub fn bitwiseAndScalar(lhs: Value, rhs: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return (try mod.intern(.{ .undef = ty.toIntern() })).toValue();
        if (ty.toIntern() == .bool_type) return makeBool(lhs.toBool() and rhs.toBool());

        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            // + 1 for negatives
            @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.bitAnd(lhs_bigint, rhs_bigint);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// operands must be (vectors of) integers; handles undefined scalars.
    pub fn bitwiseNand(lhs: Value, rhs: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try bitwiseNandScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return bitwiseNandScalar(lhs, rhs, ty, arena, mod);
    }

    /// operands must be integers; handles undefined.
    pub fn bitwiseNandScalar(lhs: Value, rhs: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return (try mod.intern(.{ .undef = ty.toIntern() })).toValue();
        if (ty.toIntern() == .bool_type) return makeBool(!(lhs.toBool() and rhs.toBool()));

        const anded = try bitwiseAnd(lhs, rhs, ty, arena, mod);
        const all_ones = if (ty.isSignedInt(mod)) try mod.intValue(ty, -1) else try ty.maxIntScalar(mod, ty);
        return bitwiseXor(anded, all_ones, ty, arena, mod);
    }

    /// operands must be (vectors of) integers; handles undefined scalars.
    pub fn bitwiseOr(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try bitwiseOrScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return bitwiseOrScalar(lhs, rhs, ty, allocator, mod);
    }

    /// operands must be integers; handles undefined.
    pub fn bitwiseOrScalar(lhs: Value, rhs: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return (try mod.intern(.{ .undef = ty.toIntern() })).toValue();
        if (ty.toIntern() == .bool_type) return makeBool(lhs.toBool() or rhs.toBool());

        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.bitOr(lhs_bigint, rhs_bigint);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// operands must be (vectors of) integers; handles undefined scalars.
    pub fn bitwiseXor(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try bitwiseXorScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return bitwiseXorScalar(lhs, rhs, ty, allocator, mod);
    }

    /// operands must be integers; handles undefined.
    pub fn bitwiseXorScalar(lhs: Value, rhs: Value, ty: Type, arena: Allocator, mod: *Module) !Value {
        if (lhs.isUndef(mod) or rhs.isUndef(mod)) return (try mod.intern(.{ .undef = ty.toIntern() })).toValue();
        if (ty.toIntern() == .bool_type) return makeBool(lhs.toBool() != rhs.toBool());

        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try arena.alloc(
            std.math.big.Limb,
            // + 1 for negatives
            @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        result_bigint.bitXor(lhs_bigint, rhs_bigint);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    /// If the value overflowed the type, returns a comptime_int (or vector thereof) instead, setting
    /// overflow_idx to the vector index the overflow was at (or 0 for a scalar).
    pub fn intDiv(lhs: Value, rhs: Value, ty: Type, overflow_idx: *?usize, allocator: Allocator, mod: *Module) !Value {
        var overflow: usize = undefined;
        return intDivInner(lhs, rhs, ty, &overflow, allocator, mod) catch |err| switch (err) {
            error.Overflow => {
                const is_vec = ty.isVector(mod);
                overflow_idx.* = if (is_vec) overflow else 0;
                const safe_ty = if (is_vec) try mod.vectorType(.{
                    .len = ty.vectorLen(mod),
                    .child = .comptime_int_type,
                }) else Type.comptime_int;
                return intDivInner(lhs, rhs, safe_ty, undefined, allocator, mod) catch |err1| switch (err1) {
                    error.Overflow => unreachable,
                    else => |e| return e,
                };
            },
            else => |e| return e,
        };
    }

    fn intDivInner(lhs: Value, rhs: Value, ty: Type, overflow_idx: *usize, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                const val = intDivScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod) catch |err| switch (err) {
                    error.Overflow => {
                        overflow_idx.* = i;
                        return error.Overflow;
                    },
                    else => |e| return e,
                };
                scalar.* = try val.intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intDivScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn intDivScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs_q = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len,
        );
        const limbs_r = try allocator.alloc(
            std.math.big.Limb,
            rhs_bigint.limbs.len,
        );
        const limbs_buffer = try allocator.alloc(
            std.math.big.Limb,
            std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
        );
        var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
        var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
        result_q.divTrunc(&result_r, lhs_bigint, rhs_bigint, limbs_buffer);
        if (ty.toIntern() != .comptime_int_type) {
            const info = ty.intInfo(mod);
            if (!result_q.toConst().fitsInTwosComp(info.signedness, info.bits)) {
                return error.Overflow;
            }
        }
        return mod.intValue_big(ty, result_q.toConst());
    }

    pub fn intDivFloor(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try intDivFloorScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intDivFloorScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn intDivFloorScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs_q = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len,
        );
        const limbs_r = try allocator.alloc(
            std.math.big.Limb,
            rhs_bigint.limbs.len,
        );
        const limbs_buffer = try allocator.alloc(
            std.math.big.Limb,
            std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
        );
        var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
        var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
        result_q.divFloor(&result_r, lhs_bigint, rhs_bigint, limbs_buffer);
        return mod.intValue_big(ty, result_q.toConst());
    }

    pub fn intMod(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try intModScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intModScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn intModScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs_q = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len,
        );
        const limbs_r = try allocator.alloc(
            std.math.big.Limb,
            rhs_bigint.limbs.len,
        );
        const limbs_buffer = try allocator.alloc(
            std.math.big.Limb,
            std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
        );
        var result_q = BigIntMutable{ .limbs = limbs_q, .positive = undefined, .len = undefined };
        var result_r = BigIntMutable{ .limbs = limbs_r, .positive = undefined, .len = undefined };
        result_q.divFloor(&result_r, lhs_bigint, rhs_bigint, limbs_buffer);
        return mod.intValue_big(ty, result_r.toConst());
    }

    /// Returns true if the value is a floating point type and is NaN. Returns false otherwise.
    pub fn isNan(val: Value, mod: *const Module) bool {
        if (val.ip_index == .none) return false;
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .float => |float| switch (float.storage) {
                inline else => |x| std.math.isNan(x),
            },
            else => false,
        };
    }

    /// Returns true if the value is a floating point type and is infinite. Returns false otherwise.
    pub fn isInf(val: Value, mod: *const Module) bool {
        if (val.ip_index == .none) return false;
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .float => |float| switch (float.storage) {
                inline else => |x| std.math.isInf(x),
            },
            else => false,
        };
    }

    pub fn isNegativeInf(val: Value, mod: *const Module) bool {
        if (val.ip_index == .none) return false;
        return switch (mod.intern_pool.indexToKey(val.toIntern())) {
            .float => |float| switch (float.storage) {
                inline else => |x| std.math.isNegativeInf(x),
            },
            else => false,
        };
    }

    pub fn floatRem(lhs: Value, rhs: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatRemScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatRemScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatRemScalar(lhs: Value, rhs: Value, float_type: Type, mod: *Module) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @rem(lhs.toFloat(f16, mod), rhs.toFloat(f16, mod)) },
            32 => .{ .f32 = @rem(lhs.toFloat(f32, mod), rhs.toFloat(f32, mod)) },
            64 => .{ .f64 = @rem(lhs.toFloat(f64, mod), rhs.toFloat(f64, mod)) },
            80 => .{ .f80 = @rem(lhs.toFloat(f80, mod), rhs.toFloat(f80, mod)) },
            128 => .{ .f128 = @rem(lhs.toFloat(f128, mod), rhs.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatMod(lhs: Value, rhs: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatModScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatModScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatModScalar(lhs: Value, rhs: Value, float_type: Type, mod: *Module) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @mod(lhs.toFloat(f16, mod), rhs.toFloat(f16, mod)) },
            32 => .{ .f32 = @mod(lhs.toFloat(f32, mod), rhs.toFloat(f32, mod)) },
            64 => .{ .f64 = @mod(lhs.toFloat(f64, mod), rhs.toFloat(f64, mod)) },
            80 => .{ .f80 = @mod(lhs.toFloat(f80, mod), rhs.toFloat(f80, mod)) },
            128 => .{ .f128 = @mod(lhs.toFloat(f128, mod), rhs.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    /// If the value overflowed the type, returns a comptime_int (or vector thereof) instead, setting
    /// overflow_idx to the vector index the overflow was at (or 0 for a scalar).
    pub fn intMul(lhs: Value, rhs: Value, ty: Type, overflow_idx: *?usize, allocator: Allocator, mod: *Module) !Value {
        var overflow: usize = undefined;
        return intMulInner(lhs, rhs, ty, &overflow, allocator, mod) catch |err| switch (err) {
            error.Overflow => {
                const is_vec = ty.isVector(mod);
                overflow_idx.* = if (is_vec) overflow else 0;
                const safe_ty = if (is_vec) try mod.vectorType(.{
                    .len = ty.vectorLen(mod),
                    .child = .comptime_int_type,
                }) else Type.comptime_int;
                return intMulInner(lhs, rhs, safe_ty, undefined, allocator, mod) catch |err1| switch (err1) {
                    error.Overflow => unreachable,
                    else => |e| return e,
                };
            },
            else => |e| return e,
        };
    }

    fn intMulInner(lhs: Value, rhs: Value, ty: Type, overflow_idx: *usize, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                const val = intMulScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod) catch |err| switch (err) {
                    error.Overflow => {
                        overflow_idx.* = i;
                        return error.Overflow;
                    },
                    else => |e| return e,
                };
                scalar.* = try val.intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intMulScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn intMulScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.toIntern() != .comptime_int_type) {
            const res = try intMulWithOverflowScalar(lhs, rhs, ty, allocator, mod);
            if (res.overflow_bit.compareAllWithZero(.neq, mod)) return error.Overflow;
            return res.wrapped_result;
        }
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        var rhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const rhs_bigint = rhs.toBigInt(&rhs_space, mod);
        const limbs = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len + rhs_bigint.limbs.len,
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
        var limbs_buffer = try allocator.alloc(
            std.math.big.Limb,
            std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
        );
        defer allocator.free(limbs_buffer);
        result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, allocator);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn intTrunc(val: Value, ty: Type, allocator: Allocator, signedness: std.builtin.Signedness, bits: u16, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try intTruncScalar(elem_val, scalar_ty, allocator, signedness, bits, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intTruncScalar(val, ty, allocator, signedness, bits, mod);
    }

    /// This variant may vectorize on `bits`. Asserts that `bits` is a (vector of) `u16`.
    pub fn intTruncBitsAsValue(
        val: Value,
        ty: Type,
        allocator: Allocator,
        signedness: std.builtin.Signedness,
        bits: Value,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                const bits_elem = try bits.elemValue(mod, i);
                scalar.* = try (try intTruncScalar(elem_val, scalar_ty, allocator, signedness, @intCast(u16, bits_elem.toUnsignedInt(mod)), mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return intTruncScalar(val, ty, allocator, signedness, @intCast(u16, bits.toUnsignedInt(mod)), mod);
    }

    pub fn intTruncScalar(
        val: Value,
        ty: Type,
        allocator: Allocator,
        signedness: std.builtin.Signedness,
        bits: u16,
        mod: *Module,
    ) !Value {
        if (bits == 0) return mod.intValue(ty, 0);

        var val_space: Value.BigIntSpace = undefined;
        const val_bigint = val.toBigInt(&val_space, mod);

        const limbs = try allocator.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(bits),
        );
        var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };

        result_bigint.truncate(val_bigint, signedness, bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn shl(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try shlScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return shlScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn shlScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const shift = @intCast(usize, rhs.toUnsignedInt(mod));
        const limbs = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len + (shift / (@sizeOf(std.math.big.Limb) * 8)) + 1,
        );
        var result_bigint = BigIntMutable{
            .limbs = limbs,
            .positive = undefined,
            .len = undefined,
        };
        result_bigint.shiftLeft(lhs_bigint, shift);
        if (ty.toIntern() != .comptime_int_type) {
            const int_info = ty.intInfo(mod);
            result_bigint.truncate(result_bigint.toConst(), int_info.signedness, int_info.bits);
        }

        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn shlWithOverflow(
        lhs: Value,
        rhs: Value,
        ty: Type,
        allocator: Allocator,
        mod: *Module,
    ) !OverflowArithmeticResult {
        if (ty.zigTypeTag(mod) == .Vector) {
            const vec_len = ty.vectorLen(mod);
            const overflowed_data = try allocator.alloc(InternPool.Index, vec_len);
            const result_data = try allocator.alloc(InternPool.Index, vec_len);
            const scalar_ty = ty.scalarType(mod);
            for (overflowed_data, result_data, 0..) |*of, *scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                const of_math_result = try shlWithOverflowScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod);
                of.* = try of_math_result.overflow_bit.intern(Type.u1, mod);
                scalar.* = try of_math_result.wrapped_result.intern(scalar_ty, mod);
            }
            return OverflowArithmeticResult{
                .overflow_bit = (try mod.intern(.{ .aggregate = .{
                    .ty = (try mod.vectorType(.{ .len = vec_len, .child = .u1_type })).toIntern(),
                    .storage = .{ .elems = overflowed_data },
                } })).toValue(),
                .wrapped_result = (try mod.intern(.{ .aggregate = .{
                    .ty = ty.toIntern(),
                    .storage = .{ .elems = result_data },
                } })).toValue(),
            };
        }
        return shlWithOverflowScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn shlWithOverflowScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        allocator: Allocator,
        mod: *Module,
    ) !OverflowArithmeticResult {
        const info = ty.intInfo(mod);
        var lhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const shift = @intCast(usize, rhs.toUnsignedInt(mod));
        const limbs = try allocator.alloc(
            std.math.big.Limb,
            lhs_bigint.limbs.len + (shift / (@sizeOf(std.math.big.Limb) * 8)) + 1,
        );
        var result_bigint = BigIntMutable{
            .limbs = limbs,
            .positive = undefined,
            .len = undefined,
        };
        result_bigint.shiftLeft(lhs_bigint, shift);
        const overflowed = !result_bigint.toConst().fitsInTwosComp(info.signedness, info.bits);
        if (overflowed) {
            result_bigint.truncate(result_bigint.toConst(), info.signedness, info.bits);
        }
        return OverflowArithmeticResult{
            .overflow_bit = try mod.intValue(Type.u1, @intFromBool(overflowed)),
            .wrapped_result = try mod.intValue_big(ty, result_bigint.toConst()),
        };
    }

    pub fn shlSat(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try shlSatScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return shlSatScalar(lhs, rhs, ty, arena, mod);
    }

    pub fn shlSatScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        const info = ty.intInfo(mod);

        var lhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const shift = @intCast(usize, rhs.toUnsignedInt(mod));
        const limbs = try arena.alloc(
            std.math.big.Limb,
            std.math.big.int.calcTwosCompLimbCount(info.bits) + 1,
        );
        var result_bigint = BigIntMutable{
            .limbs = limbs,
            .positive = undefined,
            .len = undefined,
        };
        result_bigint.shiftLeftSat(lhs_bigint, shift, info.signedness, info.bits);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn shlTrunc(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try shlTruncScalar(lhs_elem, rhs_elem, scalar_ty, arena, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return shlTruncScalar(lhs, rhs, ty, arena, mod);
    }

    pub fn shlTruncScalar(
        lhs: Value,
        rhs: Value,
        ty: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        const shifted = try lhs.shl(rhs, ty, arena, mod);
        const int_info = ty.intInfo(mod);
        const truncated = try shifted.intTrunc(ty, arena, int_info.signedness, int_info.bits, mod);
        return truncated;
    }

    pub fn shr(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        if (ty.zigTypeTag(mod) == .Vector) {
            const result_data = try allocator.alloc(InternPool.Index, ty.vectorLen(mod));
            const scalar_ty = ty.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try shrScalar(lhs_elem, rhs_elem, scalar_ty, allocator, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = ty.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return shrScalar(lhs, rhs, ty, allocator, mod);
    }

    pub fn shrScalar(lhs: Value, rhs: Value, ty: Type, allocator: Allocator, mod: *Module) !Value {
        // TODO is this a performance issue? maybe we should try the operation without
        // resorting to BigInt first.
        var lhs_space: Value.BigIntSpace = undefined;
        const lhs_bigint = lhs.toBigInt(&lhs_space, mod);
        const shift = @intCast(usize, rhs.toUnsignedInt(mod));

        const result_limbs = lhs_bigint.limbs.len -| (shift / (@sizeOf(std.math.big.Limb) * 8));
        if (result_limbs == 0) {
            // The shift is enough to remove all the bits from the number, which means the
            // result is 0 or -1 depending on the sign.
            if (lhs_bigint.positive) {
                return mod.intValue(ty, 0);
            } else {
                return mod.intValue(ty, -1);
            }
        }

        const limbs = try allocator.alloc(
            std.math.big.Limb,
            result_limbs,
        );
        var result_bigint = BigIntMutable{
            .limbs = limbs,
            .positive = undefined,
            .len = undefined,
        };
        result_bigint.shiftRight(lhs_bigint, shift);
        return mod.intValue_big(ty, result_bigint.toConst());
    }

    pub fn floatNeg(
        val: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try floatNegScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatNegScalar(val, float_type, mod);
    }

    pub fn floatNegScalar(
        val: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = -val.toFloat(f16, mod) },
            32 => .{ .f32 = -val.toFloat(f32, mod) },
            64 => .{ .f64 = -val.toFloat(f64, mod) },
            80 => .{ .f80 = -val.toFloat(f80, mod) },
            128 => .{ .f128 = -val.toFloat(f128, mod) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatAdd(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatAddScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatAddScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatAddScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = lhs.toFloat(f16, mod) + rhs.toFloat(f16, mod) },
            32 => .{ .f32 = lhs.toFloat(f32, mod) + rhs.toFloat(f32, mod) },
            64 => .{ .f64 = lhs.toFloat(f64, mod) + rhs.toFloat(f64, mod) },
            80 => .{ .f80 = lhs.toFloat(f80, mod) + rhs.toFloat(f80, mod) },
            128 => .{ .f128 = lhs.toFloat(f128, mod) + rhs.toFloat(f128, mod) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatSub(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatSubScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatSubScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatSubScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = lhs.toFloat(f16, mod) - rhs.toFloat(f16, mod) },
            32 => .{ .f32 = lhs.toFloat(f32, mod) - rhs.toFloat(f32, mod) },
            64 => .{ .f64 = lhs.toFloat(f64, mod) - rhs.toFloat(f64, mod) },
            80 => .{ .f80 = lhs.toFloat(f80, mod) - rhs.toFloat(f80, mod) },
            128 => .{ .f128 = lhs.toFloat(f128, mod) - rhs.toFloat(f128, mod) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatDiv(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatDivScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatDivScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatDivScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = lhs.toFloat(f16, mod) / rhs.toFloat(f16, mod) },
            32 => .{ .f32 = lhs.toFloat(f32, mod) / rhs.toFloat(f32, mod) },
            64 => .{ .f64 = lhs.toFloat(f64, mod) / rhs.toFloat(f64, mod) },
            80 => .{ .f80 = lhs.toFloat(f80, mod) / rhs.toFloat(f80, mod) },
            128 => .{ .f128 = lhs.toFloat(f128, mod) / rhs.toFloat(f128, mod) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatDivFloor(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatDivFloorScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatDivFloorScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatDivFloorScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @divFloor(lhs.toFloat(f16, mod), rhs.toFloat(f16, mod)) },
            32 => .{ .f32 = @divFloor(lhs.toFloat(f32, mod), rhs.toFloat(f32, mod)) },
            64 => .{ .f64 = @divFloor(lhs.toFloat(f64, mod), rhs.toFloat(f64, mod)) },
            80 => .{ .f80 = @divFloor(lhs.toFloat(f80, mod), rhs.toFloat(f80, mod)) },
            128 => .{ .f128 = @divFloor(lhs.toFloat(f128, mod), rhs.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatDivTrunc(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatDivTruncScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatDivTruncScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatDivTruncScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @divTrunc(lhs.toFloat(f16, mod), rhs.toFloat(f16, mod)) },
            32 => .{ .f32 = @divTrunc(lhs.toFloat(f32, mod), rhs.toFloat(f32, mod)) },
            64 => .{ .f64 = @divTrunc(lhs.toFloat(f64, mod), rhs.toFloat(f64, mod)) },
            80 => .{ .f80 = @divTrunc(lhs.toFloat(f80, mod), rhs.toFloat(f80, mod)) },
            128 => .{ .f128 = @divTrunc(lhs.toFloat(f128, mod), rhs.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floatMul(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const lhs_elem = try lhs.elemValue(mod, i);
                const rhs_elem = try rhs.elemValue(mod, i);
                scalar.* = try (try floatMulScalar(lhs_elem, rhs_elem, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floatMulScalar(lhs, rhs, float_type, mod);
    }

    pub fn floatMulScalar(
        lhs: Value,
        rhs: Value,
        float_type: Type,
        mod: *Module,
    ) !Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = lhs.toFloat(f16, mod) * rhs.toFloat(f16, mod) },
            32 => .{ .f32 = lhs.toFloat(f32, mod) * rhs.toFloat(f32, mod) },
            64 => .{ .f64 = lhs.toFloat(f64, mod) * rhs.toFloat(f64, mod) },
            80 => .{ .f80 = lhs.toFloat(f80, mod) * rhs.toFloat(f80, mod) },
            128 => .{ .f128 = lhs.toFloat(f128, mod) * rhs.toFloat(f128, mod) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn sqrt(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try sqrtScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return sqrtScalar(val, float_type, mod);
    }

    pub fn sqrtScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @sqrt(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @sqrt(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @sqrt(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @sqrt(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @sqrt(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn sin(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try sinScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return sinScalar(val, float_type, mod);
    }

    pub fn sinScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @sin(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @sin(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @sin(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @sin(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @sin(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn cos(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try cosScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return cosScalar(val, float_type, mod);
    }

    pub fn cosScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @cos(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @cos(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @cos(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @cos(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @cos(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn tan(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try tanScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return tanScalar(val, float_type, mod);
    }

    pub fn tanScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @tan(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @tan(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @tan(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @tan(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @tan(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn exp(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try expScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return expScalar(val, float_type, mod);
    }

    pub fn expScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @exp(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @exp(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @exp(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @exp(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @exp(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn exp2(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try exp2Scalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return exp2Scalar(val, float_type, mod);
    }

    pub fn exp2Scalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @exp2(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @exp2(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @exp2(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @exp2(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @exp2(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn log(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try logScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return logScalar(val, float_type, mod);
    }

    pub fn logScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @log(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @log(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @log(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @log(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @log(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn log2(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try log2Scalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return log2Scalar(val, float_type, mod);
    }

    pub fn log2Scalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @log2(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @log2(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @log2(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @log2(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @log2(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn log10(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try log10Scalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return log10Scalar(val, float_type, mod);
    }

    pub fn log10Scalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @log10(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @log10(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @log10(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @log10(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @log10(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn fabs(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try fabsScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return fabsScalar(val, float_type, mod);
    }

    pub fn fabsScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @fabs(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @fabs(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @fabs(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @fabs(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @fabs(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn floor(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try floorScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return floorScalar(val, float_type, mod);
    }

    pub fn floorScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @floor(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @floor(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @floor(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @floor(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @floor(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn ceil(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try ceilScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return ceilScalar(val, float_type, mod);
    }

    pub fn ceilScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @ceil(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @ceil(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @ceil(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @ceil(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @ceil(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn round(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try roundScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return roundScalar(val, float_type, mod);
    }

    pub fn roundScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @round(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @round(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @round(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @round(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @round(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn trunc(val: Value, float_type: Type, arena: Allocator, mod: *Module) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const elem_val = try val.elemValue(mod, i);
                scalar.* = try (try truncScalar(elem_val, scalar_ty, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return truncScalar(val, float_type, mod);
    }

    pub fn truncScalar(val: Value, float_type: Type, mod: *Module) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @trunc(val.toFloat(f16, mod)) },
            32 => .{ .f32 = @trunc(val.toFloat(f32, mod)) },
            64 => .{ .f64 = @trunc(val.toFloat(f64, mod)) },
            80 => .{ .f80 = @trunc(val.toFloat(f80, mod)) },
            128 => .{ .f128 = @trunc(val.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    pub fn mulAdd(
        float_type: Type,
        mulend1: Value,
        mulend2: Value,
        addend: Value,
        arena: Allocator,
        mod: *Module,
    ) !Value {
        if (float_type.zigTypeTag(mod) == .Vector) {
            const result_data = try arena.alloc(InternPool.Index, float_type.vectorLen(mod));
            const scalar_ty = float_type.scalarType(mod);
            for (result_data, 0..) |*scalar, i| {
                const mulend1_elem = try mulend1.elemValue(mod, i);
                const mulend2_elem = try mulend2.elemValue(mod, i);
                const addend_elem = try addend.elemValue(mod, i);
                scalar.* = try (try mulAddScalar(scalar_ty, mulend1_elem, mulend2_elem, addend_elem, mod)).intern(scalar_ty, mod);
            }
            return (try mod.intern(.{ .aggregate = .{
                .ty = float_type.toIntern(),
                .storage = .{ .elems = result_data },
            } })).toValue();
        }
        return mulAddScalar(float_type, mulend1, mulend2, addend, mod);
    }

    pub fn mulAddScalar(
        float_type: Type,
        mulend1: Value,
        mulend2: Value,
        addend: Value,
        mod: *Module,
    ) Allocator.Error!Value {
        const target = mod.getTarget();
        const storage: InternPool.Key.Float.Storage = switch (float_type.floatBits(target)) {
            16 => .{ .f16 = @mulAdd(f16, mulend1.toFloat(f16, mod), mulend2.toFloat(f16, mod), addend.toFloat(f16, mod)) },
            32 => .{ .f32 = @mulAdd(f32, mulend1.toFloat(f32, mod), mulend2.toFloat(f32, mod), addend.toFloat(f32, mod)) },
            64 => .{ .f64 = @mulAdd(f64, mulend1.toFloat(f64, mod), mulend2.toFloat(f64, mod), addend.toFloat(f64, mod)) },
            80 => .{ .f80 = @mulAdd(f80, mulend1.toFloat(f80, mod), mulend2.toFloat(f80, mod), addend.toFloat(f80, mod)) },
            128 => .{ .f128 = @mulAdd(f128, mulend1.toFloat(f128, mod), mulend2.toFloat(f128, mod), addend.toFloat(f128, mod)) },
            else => unreachable,
        };
        return (try mod.intern(.{ .float = .{
            .ty = float_type.toIntern(),
            .storage = storage,
        } })).toValue();
    }

    /// If the value is represented in-memory as a series of bytes that all
    /// have the same value, return that byte value, otherwise null.
    pub fn hasRepeatedByteRepr(val: Value, ty: Type, mod: *Module) !?Value {
        const abi_size = std.math.cast(usize, ty.abiSize(mod)) orelse return null;
        assert(abi_size >= 1);
        const byte_buffer = try mod.gpa.alloc(u8, abi_size);
        defer mod.gpa.free(byte_buffer);

        writeToMemory(val, ty, mod, byte_buffer) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReinterpretDeclRef => return null,
            // TODO: The writeToMemory function was originally created for the purpose
            // of comptime pointer casting. However, it is now additionally being used
            // for checking the actual memory layout that will be generated by machine
            // code late in compilation. So, this error handling is too aggressive and
            // causes some false negatives, causing less-than-ideal code generation.
            error.IllDefinedMemoryLayout => return null,
            error.Unimplemented => return null,
        };
        const first_byte = byte_buffer[0];
        for (byte_buffer[1..]) |byte| {
            if (byte != first_byte) return null;
        }
        return try mod.intValue(Type.u8, first_byte);
    }

    pub fn isGenericPoison(val: Value) bool {
        return val.toIntern() == .generic_poison;
    }

    /// For an integer (comptime or fixed-width) `val`, returns the comptime-known bounds of the value.
    /// If `val` is not undef, the bounds are both `val`.
    /// If `val` is undef and has a fixed-width type, the bounds are the bounds of the type.
    /// If `val` is undef and is a `comptime_int`, returns null.
    pub fn intValueBounds(val: Value, mod: *Module) !?[2]Value {
        if (!val.isUndef(mod)) return .{ val, val };
        const ty = mod.intern_pool.typeOf(val.toIntern());
        if (ty == .comptime_int_type) return null;
        return .{
            try ty.toType().minInt(mod, ty.toType()),
            try ty.toType().maxInt(mod, ty.toType()),
        };
    }

    /// This type is not copyable since it may contain pointers to its inner data.
    pub const Payload = struct {
        tag: Tag,

        pub const Slice = struct {
            base: Payload,
            data: struct {
                ptr: Value,
                len: Value,
            },
        };

        pub const Bytes = struct {
            base: Payload,
            /// Includes the sentinel, if any.
            data: []const u8,
        };

        pub const SubValue = struct {
            base: Payload,
            data: Value,
        };

        pub const Aggregate = struct {
            base: Payload,
            /// Field values. The types are according to the struct or array type.
            /// The length is provided here so that copying a Value does not depend on the Type.
            data: []Value,
        };

        pub const Union = struct {
            pub const base_tag = Tag.@"union";

            base: Payload = .{ .tag = base_tag },
            data: Data,

            pub const Data = struct {
                tag: Value,
                val: Value,
            };
        };
    };

    pub const BigIntSpace = InternPool.Key.Int.Storage.BigIntSpace;

    pub const zero_usize: Value = .{ .ip_index = .zero_usize, .legacy = undefined };
    pub const zero_u8: Value = .{ .ip_index = .zero_u8, .legacy = undefined };
    pub const zero_comptime_int: Value = .{ .ip_index = .zero, .legacy = undefined };
    pub const one_comptime_int: Value = .{ .ip_index = .one, .legacy = undefined };
    pub const negative_one_comptime_int: Value = .{ .ip_index = .negative_one, .legacy = undefined };
    pub const undef: Value = .{ .ip_index = .undef, .legacy = undefined };
    pub const @"void": Value = .{ .ip_index = .void_value, .legacy = undefined };
    pub const @"null": Value = .{ .ip_index = .null_value, .legacy = undefined };
    pub const @"false": Value = .{ .ip_index = .bool_false, .legacy = undefined };
    pub const @"true": Value = .{ .ip_index = .bool_true, .legacy = undefined };
    pub const @"unreachable": Value = .{ .ip_index = .unreachable_value, .legacy = undefined };

    pub const generic_poison: Value = .{ .ip_index = .generic_poison, .legacy = undefined };
    pub const generic_poison_type: Value = .{ .ip_index = .generic_poison_type, .legacy = undefined };
    pub const empty_struct: Value = .{ .ip_index = .empty_struct, .legacy = undefined };

    pub fn makeBool(x: bool) Value {
        return if (x) Value.true else Value.false;
    }

    pub const RuntimeIndex = InternPool.RuntimeIndex;

    /// This function is used in the debugger pretty formatters in tools/ to fetch the
    /// Tag to Payload mapping to facilitate fancy debug printing for this type.
    fn dbHelper(self: *Value, tag_to_payload_map: *map: {
        const tags = @typeInfo(Tag).Enum.fields;
        var fields: [tags.len]std.builtin.Type.StructField = undefined;
        for (&fields, tags) |*field, t| field.* = .{
            .name = t.name,
            .type = *@field(Tag, t.name).Type(),
            .default_value = null,
            .is_comptime = false,
            .alignment = 0,
        };
        break :map @Type(.{ .Struct = .{
            .layout = .Extern,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }) void {
        _ = self;
        _ = tag_to_payload_map;
    }

    comptime {
        if (builtin.mode == .Debug) {
            _ = &dbHelper;
        }
    }
};
