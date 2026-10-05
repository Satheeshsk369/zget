const std = @import("std");
const adt = @import("adt.zig");

pub const Set = adt.Set(null);

pub fn Group(comptime E: type, comptime Payload: type, comptime label: ?[]const u8) type {
    return struct {
        pub const Type = E;
        pub const Union = Set.enumToUnion(E, Payload);
        pub const argLabel = label;
    };
}

pub const A = enum(u3) {
    help,
    version,
    env,
    current,
    clean,

    pub fn info(self: @This()) []const u8 {
        return switch (self) {
            .help => "Print this message",
            .version => "Print zigup tool version",
            .env => "Print configuration and environment paths",
            .current => "Show currently active Zig version and path",
            .clean => "Clean cached indexes and temporary downloads",
        };
    }
};

pub const C = enum(u3) {
    install,
    delete,
    list,
    set,
    run,
    update,

    pub fn info(self: @This()) []const u8 {
        return switch (self) {
            .install => "Download and install a version (--set to activate)",
            .delete => "Delete an installed version",
            .list => "List local installs (or remote versions if mirror is specified)",
            .set => "Set an installed version as the default",
            .run => "Run a specific installed Zig version",
            .update => "Update zigup tool (optionally to a specific version)",
        };
    }
};

pub const GroupA = Group(A, void, null);
pub const GroupC = Group(C, []const u8, "<TAG>");
pub const Command = Set.join(GroupA.Union, GroupC.Union);
pub const Entry = struct { verb: []const u8, argLabel: ?[]const u8, description: []const u8 };

fn appendEntries(comptime G: type, comptime out: []Entry, comptime start: usize) usize {
    var i = start;
    const info = @typeInfo(G.Type).@"enum";
    for (info.field_names, info.field_values) |name, value| {
        const v: G.Type = @enumFromInt(value);
        const label = if (std.mem.eql(u8, name, "list"))
            "<MIRROR>"
        else if (std.mem.eql(u8, name, "run"))
            "<TAG> [ARGS...]"
        else if (std.mem.eql(u8, name, "update"))
            "[TAG]"
        else
            G.argLabel;
        out[i] = .{ .verb = name, .argLabel = label, .description = v.info() };
        i += 1;
    }
    return i;
}

pub const commands: []const Entry = blk: {
    const n = @typeInfo(A).@"enum".field_names.len +
        @typeInfo(C).@"enum".field_names.len;
    var out: [n]Entry = undefined;
    var i: usize = 0;
    i = appendEntries(GroupA, &out, i);
    i = appendEntries(GroupC, &out, i);
    const frozen = out;
    break :blk &frozen;
};
