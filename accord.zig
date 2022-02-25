const std = @import("std");

const StringList = std.ArrayListUnmanaged([]const u8);
pub const Flag = void;
pub const PositionalData = struct {
    items: [][]const u8,
    separator_index: usize,

    pub fn beforeSeparator(self: PositionalData) [][]const u8 {
        return self.items[0..self.separator_index];
    }

    pub fn afterSeparator(self: PositionalData) [][]const u8 {
        return self.items[self.separator_index..];
    }

    pub fn deinit(self: PositionalData, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

const log = std.log.scoped(.accord);

pub const Option = struct {
    short: u8,
    long: []const u8,
    type: type,
    default: *const anyopaque,
    settings: *const anyopaque,

    pub fn getDefault(comptime self: Option) *const ValueType(self.type) {
        return @ptrCast(*const ValueType(self.type), self.default);
    }

    pub fn getSettings(comptime self: Option) *const OptionSettings(self.type) {
        return @ptrCast(*const OptionSettings(self.type), self.settings);
    }
};

fn ValueType(comptime T: type) type {
    return switch (T) {
        void => bool,
        else => T,
    };
}

// TODO: rework this to work similar to value parsing, so I can call into it multiple times to make
//       optional/array parsing more sane
pub fn OptionSettings(comptime T: type) type {
    comptime var info = @typeInfo(T);
    comptime var field_count = 0;
    comptime var fields: [3]std.builtin.TypeInfo.StructField = undefined;
    while (info == .Optional) {
        info = @typeInfo(info.Optional.child);
    }
    if (info == .Array) {
        info = @typeInfo(info.Array.child);
        // TODO: make them work!
        if (info == .Array) @compileError("Multidimensional arrays not yet supported!");
        while (info == .Optional) {
            info = @typeInfo(info.Optional.child);
        }
        const value: []const u8 = ",";
        fields[field_count] = StructField("delimiter", []const u8, &value);
        field_count += 1;
    }
    if (info == .Enum) {
        info = @typeInfo(info.Enum.tag_type);
        const EnumSetting = enum { name, value, both };
        fields[field_count] = StructField("enum_parsing", EnumSetting, &EnumSetting.name);
        field_count += 1;
    }

    if (info == .Int) {
        fields[field_count] = StructField("radix", u8, &@as(u8, 0));
        field_count += 1;
    } else if (info == .Float) {
        fields[field_count] = StructField("hex", bool, &false);
        field_count += 1;
    }

    return if (field_count == 0)
        struct { padding_so_i_can_make_a_non_zero_sized_pointer: u1 = 0 }
    else
        @Type(std.builtin.TypeInfo{ .Struct = .{
            .layout = .Auto,
            .fields = fields[0..field_count],
            .decls = &.{},
            .is_tuple = false,
        } });
}

pub fn option(
    comptime short: u8,
    comptime long: []const u8,
    comptime T: type,
    comptime default: T,
    comptime settings: OptionSettings(T),
) Option {
    if (short == 0 and long.len == 0) @compileError("Must have either a short or long name, cannot have neither!");
    return .{
        .short = short,
        .long = long,
        .type = T,
        .default = if (T == void) &false else &default,
        .settings = &settings,
    };
}

fn StructField(
    comptime name: []const u8,
    comptime T: type,
    comptime default: ?*const T,
) std.builtin.TypeInfo.StructField {
    return .{
        .name = name,
        .field_type = T,
        .default_value = default,
        .is_comptime = false,
        .alignment = @alignOf(T),
    };
}

fn OptionStruct(comptime options: []const Option) type {
    const TypeInfo = std.builtin.TypeInfo;
    comptime var struct_fields: [options.len + 1]TypeInfo.StructField = undefined;

    for (options) |opt, i| {
        struct_fields[i] = StructField(
            if (opt.long.len > 0) opt.long else &[1]u8{opt.short},
            ValueType(opt.type),
            opt.getDefault(),
        );
    }

    struct_fields[options.len] = StructField(
        "positionals",
        PositionalData,
        null,
    );

    // struct_fields[options.len + 1] = StructField(
    //     "positional_separator_index",
    //     usize,
    //     null,
    // );

    const struct_info = TypeInfo{ .Struct = .{
        .layout = .Auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } };
    return @Type(struct_info);
}

const Error = error{
    UnrecognizedOption,
    OptionMissingValue,
    OptionUnexpectedValue,
};

// TODO: think about how to rework this so I don't have to pass around unecessary arguments, it's fine for now though
const ParseFunctions = struct {
    pub fn runParseFunction(comptime T: type, comptime default: T, comptime settings: anytype, string: []const u8) Error!T {
        const info = @typeInfo(T);
        if (@hasDecl(ParseFunctions, @typeName(T)))
            return @field(ParseFunctions, @typeName(T))(T, default, settings, string)
        else if (@hasDecl(ParseFunctions, @tagName(info)))
            return @field(ParseFunctions, @tagName(info))(T, default, settings, string);

        @compileError("Unsupported type '" ++ @typeName(T) ++ "'");
    }

    pub fn @"[]const u8"(comptime T: type, comptime _: T, comptime _: anytype, string: []const u8) T {
        return string;
    }

    pub fn @"bool"(comptime T: type, comptime _: T, comptime _: anytype, string: []const u8) Error!T {
        return if (std.ascii.eqlIgnoreCase(string, "true"))
            true
        else if (std.ascii.eqlIgnoreCase(string, "false"))
            false
        else
            error.OptionUnexpectedValue;
    }

    pub fn Int(comptime T: type, comptime _: T, comptime settings: anytype, string: []const u8) Error!T {
        return std.fmt.parseInt(T, string, settings.radix) catch error.OptionUnexpectedValue;
    }

    pub fn Float(comptime T: type, comptime _: T, comptime settings: anytype, string: []const u8) Error!T {
        return if (settings.hex)
            std.fmt.parseHexFloat(T, string) catch error.OptionUnexpectedValue
        else
            std.fmt.parseFloat(T, string) catch error.OptionUnexpectedValue;
    }

    pub fn Optional(comptime T: type, comptime default: T, comptime settings: anytype, string: []const u8) Error!T {
        const d = default orelse @as(@typeInfo(T).Optional.child, undefined);
        return if (std.ascii.eqlIgnoreCase(string, "null"))
            null
        else
            // try is necessary here otherwise there are type errors
            try runParseFunction(@typeInfo(T).Optional.child, d, settings, string);
    }

    pub fn Array(comptime T: type, comptime default: T, comptime settings: anytype, string: []const u8) Error!T {
        const info = @typeInfo(T);
        const ChildT = info.Array.child;
        var result: T = default;
        var iterator = std.mem.split(u8, string, settings.delimiter);
        comptime var i: usize = 0; // iterate with i instead of iterator so default can be indexed
        inline while (i < result.len) : (i += 1) {
            const token = iterator.next() orelse break;
            result[i] = try runParseFunction(
                ChildT,
                default[i],
                settings,
                token,
            );
        }

        return result;
    }

    pub fn Enum(comptime T: type, comptime default: T, comptime settings: anytype, string: []const u8) Error!T {
        _ = settings;
        const info = @typeInfo(T);
        const TagT = info.Enum.tag_type;
        return switch (settings.enum_parsing) {
            .name => std.meta.stringToEnum(T, string) orelse error.OptionUnexpectedValue,
            .value => std.meta.intToEnum(T, runParseFunction(
                TagT,
                @enumToInt(default),
                settings,
                string,
            ) catch return error.OptionUnexpectedValue) catch error.OptionUnexpectedValue,
            .both => std.meta.intToEnum(T, runParseFunction(
                TagT,
                @enumToInt(default),
                settings,
                string,
            ) catch {
                return std.meta.stringToEnum(T, string) orelse error.OptionUnexpectedValue;
            }) catch error.OptionUnexpectedValue,
        };
    }
};

fn parseValue(comptime opt: Option, string: []const u8) Error!ValueType(opt.type) {
    return ParseFunctions.runParseFunction(
        opt.type,
        comptime opt.getDefault().*,
        comptime opt.getSettings(),
        string,
    );
}

pub fn parse(comptime options: []const Option, allocator: std.mem.Allocator, arg_iterator: anytype) !OptionStruct(options) {
    const OptValues = OptionStruct(options);
    var result = OptValues{ .positionals = undefined };
    var positional_list = StringList{};
    errdefer positional_list.deinit(allocator);

    const Parser = struct {
        pub fn common(comptime long_name: bool, arg_name: []const u8, value_string: ?[]const u8, values: *OptValues, iterator: anytype) Error!void {
            inline for (options) |opt| {
                const opt_name = if (long_name) opt.long else &[1]u8{opt.short};
                if (std.mem.eql(u8, arg_name, opt_name)) {
                    const field_name = if (opt.long.len > 0) opt.long else &[1]u8{opt.short};
                    if (opt.type == void) {
                        if (value_string != null and value_string.?.len > 0) {
                            if (long_name) {
                                log.err("Option '{s}' does not take an argument!", .{opt_name});
                                return error.OptionUnexpectedValue;
                            } else {
                                @field(values, field_name) = true;
                                const next_name = &[1]u8{value_string.?[0]};
                                const next_value_string = if (value_string.?[1..].len > 0)
                                    value_string.?[1..]
                                else
                                    null;
                                try common(false, next_name, next_value_string, values, iterator);
                            }
                        } else @field(values, field_name) = true;
                    } else {
                        const vs = value_string orelse (iterator.next() orelse {
                            log.err("Option '{s}' missing argument!", .{opt_name});
                            return error.OptionMissingValue;
                        });
                        @field(values, field_name) = parseValue(opt, vs) catch {
                            log.err("Could not parse value '{s}' for option '{s}!", .{ vs, opt_name });
                            return error.OptionUnexpectedValue;
                        };
                    }
                    break;
                }
            } else {
                log.err("Unrecognized {s} option '{s}'!", .{
                    if (long_name) "long" else "short",
                    arg_name,
                });
                return error.UnrecognizedOption;
            }
        }

        pub fn long(arg: []const u8, values: *OptValues, iterator: anytype) Error!void {
            const index = std.mem.indexOf(u8, arg, "=");
            var arg_name: []const u8 = undefined;
            var value_string: ?[]const u8 = undefined;
            if (index) |i| {
                arg_name = arg[2..i];
                value_string = arg[i + 1 ..];
            } else {
                arg_name = arg[2..];
            }

            try common(true, arg_name, value_string, values, iterator);
        }

        pub fn short(arg: []const u8, values: *OptValues, iterator: anytype) Error!void {
            const arg_name = &[1]u8{arg[1]};
            const value_string = if (arg.len > 2)
                arg[2..]
            else
                null;

            try common(false, arg_name, value_string, values, iterator);
        }
    };

    var all_positional = false;
    while (arg_iterator.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--") and !all_positional) {
            if (arg.len == 2) {
                all_positional = true;
                result.positionals.separator_index = positional_list.items.len;
            } else try Parser.long(arg, &result, arg_iterator);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !all_positional) {
            try Parser.short(arg, &result, arg_iterator);
        } else {
            try positional_list.append(allocator, arg);
        }
    }

    positional_list.shrinkAndFree(allocator, positional_list.items.len);
    result.positionals.items = positional_list.items;
    if (!all_positional)
        result.positionals.separator_index = result.positionals.items.len;

    return result;
}

fn SliceIterator(comptime T: type) type {
    return struct {
        slice: []const T,
        index: usize,

        const Self = @This();

        pub fn init(slice: []const T) Self {
            return Self{ .slice = slice, .index = 0 };
        }

        pub fn next(self: *Self) ?T {
            var result: ?T = null;
            if (self.index < self.slice.len) {
                result = self.slice[self.index];
                self.index += 1;
            }
            return result;
        }
    };
}

const TestEnum = enum(u2) { a, b, c, d };

test "argument parsing" {
    const allocator = std.testing.allocator;
    // zig fmt: off
    const args = [_][]const u8{
        "positional1",
        "-a", "test arg",
        "-b",
        "positional2",
        "-cd", "FaLSE",
        "-eff0000",
        "--longf=c",
        "--longg", "1",
        "positional3",
        "-h1,d,0",
        "-iNUlL",
        "-j", "nULl",
        "-kNULL|10|d",
        "-lnull",
        "positional4",
        "-m0b00110010",
        "-n", "1.2e4",
        "-o0x10p+10",
        "positional5",
        "-p0x10p-10",
        "-q", "bingusDELIMITERbungusDELIMITERbongoDELIMITERbingo",
        "--",
        "-r",
        "positional6",
        
    };
    // zig fmt: on
    var args_iterator = SliceIterator([]const u8).init(args[0..]);
    const options = try parse(&.{
        option('a', "longa", []const u8, "", .{}),
        option('b', "", Flag, {}, .{}),
        option('c', "longc", Flag, {}, .{}),
        option('d', "", bool, true, .{}),
        option('e', "", u32, 0, .{ .radix = 16 }),
        option('f', "", TestEnum, .a, .{}),
        option('f', "longf", TestEnum, .a, .{}),
        option('g', "longg", TestEnum, .a, .{ .enum_parsing = .value }),
        option('h', "", [3]TestEnum, .{ .a, .a, .a }, .{ .enum_parsing = .both }),
        option('i', "", ?TestEnum, .a, .{}),
        option('j', "", ?[3]TestEnum, .{ .a, .a, .a }, .{}),
        option('k', "", [3]?TestEnum, .{ .a, .a, .a }, .{ .enum_parsing = .both, .delimiter = "|", .radix = 2 }),
        option('l', "", ?[3]?TestEnum, .{ .a, .a, .a }, .{}),
        option('m', "", u8, 0, .{}),
        option('n', "", f32, 0.0, .{}),
        option('o', "", f64, 0.0, .{ .hex = true }),
        option('p', "", f128, 0.0, .{ .hex = true }),
        option('q', "", [4][]const u8, .{ "", "", "", "" }, .{ .delimiter = "DELIMITER" }),
        option('r', "", Flag, {}, .{}),
    }, allocator, &args_iterator);
    defer options.positionals.deinit(allocator);

    try std.testing.expectEqualStrings("test arg", options.longa);
    try std.testing.expect(options.b);
    try std.testing.expect(options.longc);
    try std.testing.expect(!options.d);
    try std.testing.expectEqual(options.e, 0xff0000);
    try std.testing.expectEqual(options.longf, .c);
    try std.testing.expectEqual(options.longg, .b);
    try std.testing.expectEqualSlices(TestEnum, &.{ .b, .d, .a }, options.h[0..]);
    try std.testing.expectEqual(options.i, null);
    try std.testing.expectEqual(options.j, null);
    try std.testing.expectEqualSlices(?TestEnum, &.{ null, .c, .d }, options.k[0..]);
    try std.testing.expectEqual(options.l, null);
    try std.testing.expectEqual(options.m, 50);
    try std.testing.expectEqual(options.n, 12000);
    try std.testing.expectEqual(options.o, 16384.0);
    try std.testing.expectEqual(options.p, 0.015625);
    const expected_q = [_][]const u8{ "bingus", "bungus", "bongo", "bingo" };
    for (expected_q) |string, i| {
        try std.testing.expectEqualStrings(string, options.q[i]);
    }
    const expected_positionals = [_][]const u8{
        "positional1",
        "positional2",
        "positional3",
        "positional4",
        "positional5",
        "-r",
        "positional6",
    };
    for (expected_positionals) |string, i| {
        try std.testing.expectEqualStrings(string, options.positionals.items[i]);
    }
    for (expected_positionals[0..options.positionals.separator_index]) |string, i| {
        try std.testing.expectEqualStrings(
            string,
            options.positionals.beforeSeparator()[i],
        );
    }
    for (expected_positionals[options.positionals.separator_index..]) |string, i| {
        try std.testing.expectEqualStrings(
            string,
            options.positionals.afterSeparator()[i],
        );
    }
    try std.testing.expectEqual(options.r, false);
}
