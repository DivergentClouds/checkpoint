const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var code_file: ?std.fs.File = null;
    defer if (code_file) |file|
        file.close();

    var byte_output = false;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const arg0 = args.next() orelse
        return error.NoArgsGiven;

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) {
            for (arg[1..]) |byte| {
                switch (byte) {
                    'b' => byte_output = true,
                    else => {
                        try printUsage(arg0);
                        return error.BadFlags;
                    },
                }
            }
        } else if (code_file == null) {
            code_file = try std.fs.cwd().openFile(arg, .{});
        } else {
            try printUsage(arg0);
            return error.TooManyCodeFiles;
        }
    }

    if (code_file) |code| {
        try interpret(code, byte_output, allocator);
    } else {
        try printUsage(arg0);
        return error.NoCodeFileGiven;
    }
}

fn printUsage(arg0: []const u8) !void {
    const stderr = std.io.getStdErr();

    try stderr.writer().print(
        \\usage: {s} <code file> [-ab]
        \\
        \\flags:
        \\  -b        print output as bytes
        \\
    , .{arg0});
    return error.BadArgCount;
}

const ActiveCommands = struct {
    increment_id: bool,
    decrement_id: bool,
    increment_mp: bool,
    decrement_mp: bool,

    increment_offset: bool = false,
    decrement_offset: bool = false,

    swap_mode: bool = false,

    flip_bit: bool,
    output_bit: bool,
    set_checkpoint: bool,
    get_checkpoint: bool,

    fn init(byte: u8) ActiveCommands {
        var result = ActiveCommands{
            .increment_id = byte & 0b1000_0000 != 0,
            .decrement_id = byte & 0b0100_0000 != 0,
            .increment_mp = byte & 0b0010_0000 != 0,
            .decrement_mp = byte & 0b0001_0000 != 0,

            .flip_bit = byte & 0b0000_1000 != 0,
            .output_bit = byte & 0b0000_0100 != 0,
            .set_checkpoint = byte & 0b0000_0010 != 0,
            .get_checkpoint = byte & 0b0000_0001 != 0,
        };

        result.parseOpposites();

        return result;
    }

    fn parseOpposites(self: *ActiveCommands) void {
        self.swap_mode = self.increment_id and self.decrement_id and
            self.increment_mp and self.decrement_mp;

        if (!self.swap_mode) {
            self.increment_offset = self.increment_id and self.decrement_id;
            self.decrement_offset = self.increment_mp and self.decrement_mp;
        }
    }
};

const Mode = enum {
    pc,
    mp,
};

fn interpret(code_file: std.fs.File, byte_output: bool, allocator: std.mem.Allocator) !void {
    const code_reader = code_file.reader();
    const stdout = std.io.getStdOut().writer();

    // only used when byte_output is true,
    var output_byte: u8 = 0;

    var output_bits_sent: u3 = 0;
    var did_output: bool = false;

    defer if (output_bits_sent > 0)
        stdout.writeByte(output_byte) catch {}; // can't return error in defer

    defer if (!byte_output and did_output)
        stdout.writeByte('\n') catch {};

    var pc_checkpoints = std.AutoArrayHashMap(isize, isize).init(allocator);
    defer pc_checkpoints.deinit();

    var mp_checkpoints = std.AutoArrayHashMap(isize, isize).init(allocator);
    defer mp_checkpoints.deinit();

    var memory = std.AutoArrayHashMap(usize, u1).init(allocator);
    defer memory.deinit();

    var memory_pointer: usize = 0;

    var checkpoint_id: isize = 0;
    var checkpoint_offset: isize = 0;
    var checkpoint_mode: Mode = .pc;

    var active_commands: ActiveCommands = undefined;

    while (code_reader.readByte() catch null) |byte| {
        active_commands = ActiveCommands.init(byte);

        if (active_commands.swap_mode) {
            if (checkpoint_mode == .pc) {
                checkpoint_mode = .mp;
            } else {
                checkpoint_mode = .pc;
            }
        } else if (active_commands.increment_offset) {
            checkpoint_offset += 1;
        } else if (active_commands.decrement_offset) {
            checkpoint_offset -= 1;
        } else {
            if (active_commands.increment_id) {
                checkpoint_id += 1;
            } else if (active_commands.decrement_id) {
                checkpoint_id -= 1;
            }

            if (active_commands.increment_mp) {
                memory_pointer += 1;
            } else if (active_commands.decrement_mp) {
                if (memory_pointer == 0) return;

                memory_pointer -= 1;
            }
        }

        if (active_commands.flip_bit) {
            const entry = try memory.getOrPut(memory_pointer);

            if (entry.found_existing) {
                entry.value_ptr.* = ~entry.value_ptr.*;
            } else {
                entry.value_ptr.* = 1;
            }
        }
        if (active_commands.output_bit) {
            if (byte_output) {
                output_byte <<= 1;
                output_byte |= memory.get(memory_pointer) orelse 0;

                if (output_bits_sent == 7) {
                    try stdout.writeByte(output_byte);
                }

                output_bits_sent +%= 1;
            } else {
                try stdout.print("{d}", .{
                    memory.get(memory_pointer) orelse 0,
                });

                if (output_bits_sent == 7)
                    try stdout.writeByte(' ');

                output_bits_sent +%= 1;
            }
            did_output = true;
        }
        if (active_commands.set_checkpoint) {
            if (checkpoint_mode == .pc) {
                try pc_checkpoints.put(
                    checkpoint_id,
                    // position is after the currently executing commands
                    @as(i64, @intCast(try code_file.getPos())) + checkpoint_offset,
                );
            } else {
                try mp_checkpoints.put(
                    checkpoint_id,
                    @as(i64, @intCast(memory_pointer)) + checkpoint_offset,
                );
            }
        }
        if (active_commands.get_checkpoint) {
            if ((memory.get(memory_pointer) orelse 0) == 1) {
                if (checkpoint_mode == .pc) {
                    const checkpoint = pc_checkpoints.get(checkpoint_id) orelse
                        return error.ReadFromUndefinedCheckpoint;

                    if (checkpoint < 0)
                        return;

                    // no need to add 1 since that was done when setting
                    try code_file.seekTo(@intCast(checkpoint));
                } else {
                    const checkpoint = mp_checkpoints.get(checkpoint_id) orelse
                        return error.ReadFromUndefinedCheckpoint;

                    if (checkpoint < 0)
                        return;

                    memory_pointer = @intCast(checkpoint);
                }
            }
        }
    }
}
