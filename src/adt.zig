const adt_root = @This();

const std = @import("std");
const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque = null,
    is_comptime: bool = false,
    alignment: ?usize = null,
};
const UnionField = struct {
    name: [:0]const u8,
    type: type,
    alignment: ?usize = null,
};

fn getUnionFields(comptime U: type) []const UnionField {
    comptime {
        const info = @typeInfo(U).@"union";
        var fields: [info.field_names.len]UnionField = undefined;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, ty, attr, i| {
            fields[i] = .{
                .name = name,
                .type = ty,
                .alignment = attr.@"align",
            };
        }
        const frozen = fields;
        return &frozen;
    }
}

fn containsUnion(fields: []const UnionField, name: []const u8) bool {
    @setEvalBranchQuota(@max(1000, fields.len * 10));
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

pub fn toUnion(comptime fields: []const UnionField) type {
    comptime {
        @setEvalBranchQuota(@max(2000, fields.len * 20));
        var names: [fields.len][:0]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attrs: [fields.len]std.builtin.Type.Union.FieldAttributes = undefined;
        var values: [fields.len]u16 = undefined;

        for (fields, 0..) |f, i| {
            names[i] = f.name;
            types[i] = f.type;
            attrs[i] = .{ .@"align" = f.alignment };
            values[i] = @intCast(i);
        }

        const Tag = @Enum(u16, .exhaustive, &names, &values);
        return @Union(.auto, Tag, &names, &types, &attrs);
    }
}

pub fn toStruct(comptime fields: []const StructField) type {
    comptime {
        @setEvalBranchQuota(@max(2000, fields.len * 20));
        var names: [fields.len][:0]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attrs: [fields.len]std.builtin.Type.Struct.FieldAttributes = undefined;

        for (fields, 0..) |f, i| {
            names[i] = f.name;
            types[i] = f.type;
            attrs[i] = .{
                .@"comptime" = f.is_comptime,
                .@"align" = f.alignment,
                .default_value_ptr = f.default_value_ptr,
            };
        }

        return @Struct(.auto, null, &names, &types, &attrs);
    }
}

pub fn Set(comptime Universe: ?type) type {
    return struct {
        pub const universe = Universe orelse @as(type, union(enum) {});

        pub fn cardinality(comptime U: type) usize {
            return @typeInfo(U).@"union".field_names.len;
        }

        pub fn enumToUnion(comptime E: type, comptime T: type) type {
            comptime {
                const info = @typeInfo(E);
                if (info != .@"enum") @compileError("enumToUnion expects an enum type, got: " ++ @typeName(E));
                const len = info.@"enum".field_names.len;
                var names: [len][:0]const u8 = undefined;
                var types: [len]type = undefined;
                var attrs: [len]std.builtin.Type.Union.FieldAttributes = undefined;
                for (info.@"enum".field_names, 0..) |name, i| {
                    names[i] = name;
                    types[i] = T;
                    attrs[i] = .{ .@"align" = @alignOf(T) };
                }
                return @Union(.auto, E, &names, &types, &attrs);
            }
        }

        pub fn join(comptime A: type, comptime B: type) type {
            comptime {
                const fa = getUnionFields(A);
                const fb = getUnionFields(B);
                @setEvalBranchQuota(@max(1000, fa.len * fb.len * 10));
                var merged: [fa.len + fb.len]UnionField = undefined;
                @memcpy(merged[0..fa.len], fa);
                var index = fa.len;
                for (fb) |f| {
                    if (!containsUnion(fa, f.name)) {
                        merged[index] = f;
                        index += 1;
                    }
                }
                return adt_root.toUnion(merged[0..index]);
            }
        }

        pub fn intersection(comptime A: type, comptime B: type) type {
            comptime {
                const fa = getUnionFields(A);
                const fb = getUnionFields(B);
                @setEvalBranchQuota(@max(1000, fa.len * fb.len * 10));
                var merged: [fa.len]UnionField = undefined;
                var index: usize = 0;
                for (fa) |a| {
                    for (fb) |b| {
                        if (std.mem.eql(u8, a.name, b.name)) {
                            if (a.type != b.type) @compileError("Variant '" ++ a.name ++ "' has mismatching types: " ++ @typeName(a.type) ++ " vs " ++ @typeName(b.type));
                            merged[index] = a;
                            index += 1;
                        }
                    }
                }
                return adt_root.toUnion(merged[0..index]);
            }
        }

        pub fn difference(comptime A: type, comptime B: type) type {
            comptime {
                const fa = getUnionFields(A);
                const fb = getUnionFields(B);
                @setEvalBranchQuota(@max(1000, fa.len * fb.len * 10));
                var merged: [fa.len]UnionField = undefined;
                var index: usize = 0;
                for (fa) |f| {
                    if (!containsUnion(fb, f.name)) {
                        merged[index] = f;
                        index += 1;
                    }
                }
                return adt_root.toUnion(merged[0..index]);
            }
        }

        pub fn symmetricDifference(comptime A: type, comptime B: type) type {
            return join(difference(A, B), difference(B, A));
        }

        pub fn unionToStruct(comptime U: type) type {
            comptime {
                const info = @typeInfo(U);
                if (info != .@"union") @compileError("unionToStruct expects a union type, got: " ++ @typeName(U));
                const fields = getUnionFields(U);
                var struct_fields: [fields.len]StructField = undefined;
                for (fields, 0..) |f, i| {
                    const is_optional = @typeInfo(f.type) == .optional;
                    const default_ptr: ?*const anyopaque = if (is_optional) @ptrCast(&@as(f.type, null)) else null;
                    struct_fields[i] = .{
                        .name = f.name,
                        .type = f.type,
                        .default_value_ptr = default_ptr,
                        .is_comptime = false,
                        .alignment = @alignOf(f.type),
                    };
                }
                return adt_root.toStruct(&struct_fields);
            }
        }

        pub fn cartesianProduct(comptime E1: type, comptime E2: type, comptime options: struct { separator: []const u8 = "-" }) type {
            comptime {
                const info1 = @typeInfo(E1);
                const info2 = @typeInfo(E2);
                if (info1 != .@"enum" or info2 != .@"enum") @compileError("cartesianProduct expects two enum types");
                const len1 = info1.@"enum".field_names.len;
                const len2 = info2.@"enum".field_names.len;
                const total = len1 * len2;
                var names: [total][:0]const u8 = undefined;
                var values: [total]u16 = undefined;
                var index: usize = 0;
                for (info1.@"enum".field_names) |name1| {
                    for (info2.@"enum".field_names) |name2| {
                        names[index] = name1 ++ options.separator ++ name2;
                        values[index] = @intCast(index);
                        index += 1;
                    }
                }
                return @Enum(u16, .exhaustive, &names, &values);
            }
        }

        pub fn isSubset(comptime A: type, comptime B: type) bool {
            comptime {
                const fa = getUnionFields(A);
                const fb = getUnionFields(B);
                for (fa) |a| {
                    var found = false;
                    for (fb) |b| {
                        if (std.mem.eql(u8, a.name, b.name)) {
                            if (a.type != b.type) return false;
                            found = true;
                            break;
                        }
                    }
                    if (!found) return false;
                }
                return true;
            }
        }

        pub fn isEqual(comptime A: type, comptime B: type) bool {
            return comptime isSubset(A, B) and isSubset(B, A);
        }

        pub fn isDisjoint(comptime A: type, comptime B: type) bool {
            comptime {
                const fa = getUnionFields(A);
                const fb = getUnionFields(B);
                for (fa) |a| if (containsUnion(fb, a.name)) return false;
                return true;
            }
        }

        pub fn complement(comptime A: type) type {
            return difference(universe, A);
        }

        pub fn isUniverse(comptime A: type) bool {
            return comptime isSubset(universe, A) and isSubset(A, universe);
        }
    };
}

test "union algebra: join, intersection, difference, symmetricDifference" {
    const t = std.testing;
    const S = Set(null);

    const A = union(enum) { x: u32, y: []const u8, z: bool };
    const B = union(enum) { x: u32, w: f32 };

    const Joined = S.join(A, B);
    try t.expect(@hasField(Joined, "x"));
    try t.expect(@hasField(Joined, "y"));
    try t.expect(@hasField(Joined, "z"));
    try t.expect(@hasField(Joined, "w"));

    const Inter = S.intersection(A, B);
    try t.expect(@hasField(Inter, "x"));
    try t.expect(!@hasField(Inter, "y"));
    try t.expect(!@hasField(Inter, "w"));

    const Diff = S.difference(A, B);
    try t.expect(@hasField(Diff, "y"));
    try t.expect(@hasField(Diff, "z"));
    try t.expect(!@hasField(Diff, "x"));

    const SymDiff = S.symmetricDifference(A, B);
    try t.expect(@hasField(SymDiff, "y"));
    try t.expect(@hasField(SymDiff, "z"));
    try t.expect(@hasField(SymDiff, "w"));
    try t.expect(!@hasField(SymDiff, "x"));
}

test "pipeline: enum -> enumToUnion -> join -> unionToStruct" {
    const t = std.testing;
    const S = Set(null);

    const Ops = enum { install, delete };
    const Mirrors = enum { ziglang, mach };

    const OpMirror = S.cartesianProduct(Ops, Mirrors, .{ .separator = "_" });
    const WithArg = S.enumToUnion(OpMirror, []const u8);
    const NoArg = S.enumToUnion(enum { help, version }, void);

    const Command = S.join(NoArg, WithArg);
    try t.expect(@hasField(Command, "help"));
    try t.expect(@hasField(Command, "version"));
    try t.expect(@hasField(Command, "install_ziglang"));
    try t.expect(@hasField(Command, "delete_mach"));

    const Schema = S.unionToStruct(S.enumToUnion(OpMirror, ?[]const u8));
    try t.expect(@hasField(Schema, "install_ziglang"));
    try t.expect(@hasField(Schema, "delete_mach"));
    const row = Schema{};
    try t.expect(row.install_ziglang == null);
}

test "set predicates on unions" {
    const t = std.testing;
    const S = Set(null);

    const A = union(enum) { x: u32, y: bool };
    const B = union(enum) { x: u32, y: bool, z: f32 };
    const C = union(enum) { z: f32 };

    try t.expect(comptime S.isSubset(A, B));
    try t.expect(!comptime S.isSubset(B, A));
    try t.expect(comptime S.isEqual(A, union(enum) { x: u32, y: bool }));
    try t.expect(comptime S.isDisjoint(A, C));
    try t.expect(!comptime S.isDisjoint(A, B));
}

test "cartesianProduct separator" {
    const t = std.testing;
    const S = Set(null);

    const E1 = enum { btn, inp };
    const E2 = enum { hvr, act };

    const Dash = S.cartesianProduct(E1, E2, .{});
    try t.expect(@hasField(Dash, "btn-hvr"));
    try t.expect(@hasField(Dash, "inp-act"));

    const Under = S.cartesianProduct(E1, E2, .{ .separator = "_" });
    try t.expect(@hasField(Under, "btn_hvr"));
    try t.expect(@hasField(Under, "inp_act"));
}

test "unionToStruct optional defaults" {
    const t = std.testing;
    const S = Set(null);

    const U = union(enum) { required: u32, optional: ?u32 };
    const Str = S.unionToStruct(U);
    const inst = Str{ .required = 42 };
    try t.expect(inst.required == 42);
    try t.expect(inst.optional == null);
}
