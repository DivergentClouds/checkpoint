const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args: Args = try .parse(allocator);
    defer args.deinit();

    if (args.options.help) {
        try printHelp(args.arg0, std.io.getStdOut());
    }
}

const Instruction = packed struct(u8) {
    increment_id: bool,
    decrement_id: bool,
    increment_mp: bool,
    decrement_mp: bool,

    flip_bit: bool,
    output_bit: bool,

    set_checkpoint: bool,
    load_checkpoint: bool,

    fn increment_offset(instruction: Instruction) bool {
        return instruction.increment_id and instruction.decrement_id;
    }

    fn decrement_offset(instruction: Instruction) bool {
        return instruction.increment_mp and instruction.decrement_mp;
    }

    fn swap_mode(instruction: Instruction) bool {
        return instruction.increment_offset() and instruction.decrement_offset();
    }

    /// returns null on Eof
    fn read(reader: anytype) !?Instruction {
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        return @bitCast(byte);
    }
};

const Register = struct { // could use a better name
    ptr: usize,
    id: isize,
    offset: isize,
    checkpoints: std.AutoHashMap(isize, isize),

    fn init(allocator: std.mem.Allocator) Register {
        return .{
            .ptr = 0,
            .id = 0,
            .offset = 0,
            .checkpoints = .init(allocator),
        };
    }

    fn deinit(counter: Register) void {
        counter.checkpoints.deinit();
    }
};

fn interpret(
    code_file: std.fs.File,
    allocator: std.mem.Allocator,
) !void {
    var pc: Register = .init(allocator);
    defer pc.deinit();

    var mp: Register = .init(allocator);
    defer mp.deinit();

    var buffered_code = std.io.bufferedReader(code_file.reader());
    const code = buffered_code.reader();

    while (try Instruction.read(code)) |instruction| {
        if (instruction.swap_mode()) {
            //
        } else if (instruction.increment_offset()) {
            //
        } else if (instruction.decrement_offset()) {
            //
        } else {
            if (instruction.increment_id) {
                //
            } else if (instruction.decrement_id) {
                //
            }

            if (instruction.increment_mp) {
                //
            } else if (instruction.decrement_mp) {
                //
            }
        }

        if (instruction.flip_bit) {
            //
        }

        if (instruction.output_bit) {
            //
        }

        if (instruction.set_checkpoint) {
            //
        }

        if (instruction.load_checkpoint) {
            //
        }
    }
}

const Args = struct {
    arg0: []const u8,
    optional_file: ?std.fs.File,
    options: Options,

    const Options = struct {
        /// if true, bits are printed in groups of 8 as characters.
        /// if false, bits are printed one at a time as either a '1' or a '0'
        bytes: bool,
        /// if true, each command executed is logged in textual form
        log: bool,
        /// print help and exit
        help: bool,

        const none: Options = .{
            .bytes = false,
            .log = false,
            .help = false,
        };
    };

    /// result is owned by the caller and must be deinitialized after use
    fn parse(allocator: std.mem.Allocator) !Args {
        var args = try std.process.argsWithAllocator(allocator);
        defer args.deinit();

        const arg0 = args.next() orelse
            return error.NoArg0;

        var optional_filename: ?[]const u8 = null;
        var options: Args.Options = .none;

        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                if (std.mem.eql(u8, arg[2..], "bytes"))
                    options.bytes = true
                else if (std.mem.eql(u8, arg[2..], "log"))
                    options.log = true
                else if (std.mem.eql(u8, arg[2..], "help"))
                    options.help = true
                else
                    return error.UnknownOption;
            } else if (arg.len >= 2 and arg[0] == '-') {
                for (arg[1..]) |flag| {
                    switch (flag) {
                        'b' => options.bytes = true,
                        'l' => options.log = true,
                        'h' => options.help = true,
                        else => return error.UnknownFlag,
                    }
                }
            } else if (optional_filename == null) {
                optional_filename = arg;
            } else return error.TooManyFiles;
        }

        if (optional_filename == null and !options.help) {
            try printHelp(arg0, std.io.getStdErr());
            return error.NoFileSpecified;
        }
        const optional_file = if (optional_filename) |filename|
            try std.fs.cwd().openFile(filename, .{})
        else
            null;

        return .{
            .arg0 = try allocator.dupe(u8, arg0),
            .optional_file = optional_file,
            .options = options,
        };
    }

    fn deinit(args: Args, allocator: std.mem.Allocator) void {
        allocator.free(args);

        if (args.optional_file) |file| {
            file.close();
        }
    }
};

fn printHelp(arg0: []const u8, output: std.fs.File) !void {
    try output.writer().print(
        \\usage: {s} <file> [options]
        \\
        \\options:
        \\  -b  --bytes     group output into bytes and print as characters
        \\  -l  --log       print each instruction as it is run
        \\  -h  --help      print help and exit
        \\
    , .{arg0});
}
