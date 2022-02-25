# accord

## Features
- Automatically generate and fill a struct based on input parameters
- Short and long options
- Short options work with both `-a -b -c -d 12` and `-abcd12`
- Long options work with both `--option long` and `--option=long`
- Everything after a standalone `--` will be considered a positional argument
- Positional arguments stored in an unmanaged ArrayList in the returned struct
- Types:
    - Strings (`[]const u8`)
    - Signed and unsigend integers
    - Floats and hex floats
    - Booleans (*must* have `true` or `false` as the value)
    - Flags with no arguments via `void` (or the `accord.Flag` alias for readability)
    - Enums by name, value, or both
    - Optionals of any of these types (except `void`)
    - Array of any of these types (except `void`)
        - If you don't fill out every array value, the rest will be filled with the defaults
    - Optional array, array of optionals, and optional array of optionals
- Type settings:
    - Integers have a `radix` u8 setting, defaults to 0.
        - A radix of 0 means assume base 10 unless the value starts with:
            - `0b` = binary
            - `0o` = octal
            - `0x` = hex
    - Floats have a `hex` bool setting, defaults to false. Allows you to parse hexadecimal floating point values.
    - Enums have an `enum_parsing` enum setting with the values `name`, `value`, and `both`, defaults to `name`. Enums also have the integer `radix` setting.
        - `name` means it will try to match the value with the names of the fields in the enum.
        - `value` means it will try to match the values of the fields.
        - `both` means it will first try to match the field values, and if that fails it will try to match the field names.
    - Arrays have a `delimiter` string setting, defaults to `","`. It will also inherit any settings from it's child type (e.g. an array of enums would also have the `enum_parsing` and `radix` settings available)
        - Separator between array values.

## Example
```zig
const allocator = std.heap.page_allocator;
var args_iterator = std.process.args().init();
const options = try accord.parse(&.{
    accord.option('s', "string", []const u8, "default", .{}),
    accord.option('c', "color", u32, 0x000000, .{ .radix = 16 }),
    accord.option('f', "float", f32, 0.0, .{}),
    accord.option('a', "", accord.Flag, {}, .{}), // option without long option
    accord.option(0, "option", accord.Flag, {}, .{}), // option without short option
    accord.option('i', "intarray", [2]?u32, .{ 0, 0 }, .{ .delimiter = "|" }),
}, allocator, &args_iterator);
defer options.positionals.deinit(allocator);
```
The above example called as

`command positional1 -s"some string" --color ff0000 positional2 -f 1.2e4 -a positional3 --intarray="null|23" -- --option`

would result in the following value:
```zig
{
    .string = "some string",
    .color = 0xff0000,
    .float = 12000.0,
    .a = true,
    .option = false,
    .intarray = [2]u32{ null, 23 },
    .positionals = {  "command", "positional1", "positional2", "positional3", "--option" }
}
```
