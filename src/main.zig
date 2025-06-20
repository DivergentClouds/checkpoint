const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

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
    defer args.deinit(allocator);

    if (args.options.help) {
        try printHelp(args.arg0, std.io.getStdOut());
        return;
    }

    // optional_file is only null when args.options.help is true
    try interpret(
        args.optional_file.?,
        args.options.bytes,
        args.options.log,
        allocator,
    );
}

const Instruction = packed struct(u8) {
    load_checkpoint: bool,
    set_checkpoint: bool,

    output_bit: bool,

    flip_bit: bool,

    decrement_mp: bool,
    increment_mp: bool,
    decrement_id: bool,
    increment_id: bool,

    fn increment_offset(instruction: Instruction) bool {
        return instruction.increment_id and instruction.decrement_id;
    }

    fn decrement_offset(instruction: Instruction) bool {
        return instruction.increment_mp and instruction.decrement_mp;
    }

    fn swap_mode(instruction: Instruction) bool {
        return instruction.increment_offset() and instruction.decrement_offset();
    }

    const conditional: Instruction = .{
        .increment_id = false,
        .decrement_id = false,
        .increment_mp = false,
        .decrement_mp = false,

        .flip_bit = false,

        .output_bit = false,

        .set_checkpoint = false,
        .load_checkpoint = false,
    };

    /// returns null on Eof
    fn read(reader: anytype) !?Instruction {
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        return @bitCast(byte);
    }

    pub fn format(
        instruction: Instruction,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll("instruction:");
        if (instruction.swap_mode()) {
            try writer.writeAll(" swap");
        } else if (instruction.increment_offset()) {
            try writer.writeAll(" offset+");
        } else if (instruction.decrement_offset()) {
            try writer.writeAll(" offset-");
        } else {
            if (instruction.increment_id) {
                try writer.writeAll(" id+");
            } else if (instruction.decrement_id) {
                try writer.writeAll(" id-");
            }

            if (instruction.increment_mp) {
                try writer.writeAll(" mp+");
            } else if (instruction.decrement_id) {
                try writer.writeAll(" mp-");
            }
        }

        if (instruction.flip_bit) {
            try writer.writeAll(" flip");
        }

        if (instruction.output_bit) {
            try writer.writeAll(" output");
        }

        if (instruction.set_checkpoint) {
            try writer.writeAll(" save");
        }

        if (instruction.load_checkpoint) {
            try writer.writeAll(" load");
        }

        if (instruction == conditional) {
            try writer.writeAll(" cond");
        }
    }
};

const Register = struct {
    ptr: isize,
    checkpoint_id: isize,
    checkpoint_offset: isize,
    checkpoints: std.AutoHashMap(isize, isize),

    fn init(allocator: std.mem.Allocator) Register {
        return .{
            .ptr = 0,
            .checkpoint_id = 0,
            .checkpoint_offset = 0,
            .checkpoints = .init(allocator),
        };
    }

    fn deinit(counter: *Register) void {
        counter.checkpoints.deinit();
    }
};

const Mode = enum {
    pc,
    mp,

    fn getRegister(mode: Mode, pc: *Register, mp: *Register) *Register {
        return switch (mode) {
            .pc => pc,
            .mp => mp,
        };
    }
};

fn increment(value: isize) error{Overflow}!isize {
    return try std.math.add(isize, value, 1);
}

fn decrement(value: isize) error{Overflow}!isize {
    return try std.math.sub(isize, value, 1);
}

const Output = struct {
    byte_mode: bool,

    byte: u8,
    bits_sent: u3,

    printed: bool,

    fn init(byte_mode: bool) Output {
        return .{
            .byte_mode = byte_mode,
            .byte = 0,
            .bits_sent = 0,
            .printed = false,
        };
    }

    fn send(output: *Output, bit: u1, stdout: anytype) !void {
        if (output.byte_mode) {
            output.byte <<= 1;
            output.byte |= bit;
            output.bits_sent +%= 1;

            // if 8 bits have been sent (an overflow occured)
            if (output.bits_sent == 0) {
                try stdout.writeByte(output.byte);
                output.printed = true;
                output.byte = 0;
            }
        } else {
            try stdout.print("{d} ", .{bit});
            output.printed = true;
        }
    }

    fn flush(output: Output, stdout: anytype) !void {
        if (output.printed and !output.byte_mode) {
            // put a newline after the final bit printed
            try stdout.writeByte('\n');
        } else if (output.bits_sent != 0) {
            try stdout.writeByte(output.byte);
        }
    }
};

fn interpret(
    code_file: std.fs.File,
    byte_output: bool,
    log_instructions: bool,
    allocator: std.mem.Allocator,
) !void {
    // 0x1000 bits should be plenty to start with
    var tape: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, 0x1000);
    defer tape.deinit(allocator);

    const stdout = std.io.getStdOut().writer();

    var output: Output = .init(byte_output);
    defer output.flush(stdout) catch {};

    var pc: Register = .init(allocator);
    defer pc.deinit();

    var mp: Register = .init(allocator);
    defer mp.deinit();

    var mode: Mode = .pc;

    var skip_instruction: bool = false;

    var buffered_code = std.io.bufferedReader(code_file.reader());
    const code = buffered_code.reader();

    while (try Instruction.read(code)) |instruction| {
        if (log_instructions)
            try stdout.print("{s}{}\n", .{
                if (skip_instruction)
                    "skipped - "
                else
                    "",
                instruction,
            });

        if (skip_instruction) {
            skip_instruction = false;
            continue;
        }

        if (instruction == Instruction.conditional) {
            if (tape.isSet(@intCast(mp.ptr))) {
                skip_instruction = true;
            }
            continue;
        }

        if (instruction.swap_mode()) {
            mode = switch (mode) {
                .pc => .mp,
                .mp => .pc,
            };
        } else if (instruction.increment_offset()) {
            const register = mode.getRegister(&pc, &mp);

            register.checkpoint_offset = try increment(register.checkpoint_offset);
        } else if (instruction.decrement_offset()) {
            const register = mode.getRegister(&pc, &mp);

            register.checkpoint_offset = try decrement(register.checkpoint_offset);
        } else {
            const register = mode.getRegister(&pc, &mp);

            if (instruction.increment_id) {
                register.checkpoint_id = try increment(register.checkpoint_id);
            } else if (instruction.decrement_id) {
                register.checkpoint_id = try decrement(register.checkpoint_id);
            }

            if (instruction.increment_mp) {
                mp.ptr = try increment(mp.ptr);
            } else if (instruction.decrement_mp) {
                mp.ptr = decrement(mp.ptr) catch |err| switch (err) {
                    error.Overflow => return,
                };
            }
        }
        const register = mode.getRegister(&pc, &mp);

        if (instruction.flip_bit) {
            if (tape.bit_length < mp.ptr) {
                // leave plenty of room after mp.ptr to avoid reallocating as much
                try tape.resize(allocator, @intCast(mp.ptr +| 0x1000), false);
            }
            tape.toggle(@intCast(mp.ptr));
        }

        if (instruction.output_bit) {
            try output.send(
                @intFromBool(tape.isSet(@intCast(mp.ptr))),
                stdout,
            );
        }

        if (instruction.set_checkpoint) {
            try register.checkpoints.put(
                register.checkpoint_id,
                try std.math.add(isize, register.ptr, register.checkpoint_offset),
            );
        }
        if (instruction.load_checkpoint) {
            register.ptr = register.checkpoints.get(register.checkpoint_id) orelse
                return error.UndefinedCheckpoint;

            if (register.ptr < 0)
                return;

            if (mode == .pc) {
                try code_file.seekTo(@intCast(pc.ptr));
                // flush the buffer of code from old location
                buffered_code.end = buffered_code.start;
            }
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
        allocator.free(args.arg0);

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
