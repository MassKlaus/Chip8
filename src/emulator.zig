const std = @import("std");
const Emulator = @This();

const Timer = struct {
    counter: u8 = 0,
    last_tick: ?std.time.Instant = null,
};

memory: [1024 * 4]u8 align(16) = [1]u8{0} ** (1024 * 4),
memory_s: []u8 align(16) = undefined,
registers: [16]u8 = [1]u8{0} ** 16,
display: [DISPLAY_HEIGHT * DISPLAY_WIDTH]u8 = [1]u8{' '} ** (DISPLAY_HEIGHT * DISPLAY_WIDTH),

delay_timer: Timer = .{},
sound_timer: Timer = .{},

memory_index: u16 = 0,
execute_cursor: u16 = 0,

// NOT A MEMORY STACK BUT RATHER A RETURN ADDRESS STACK!!!!
stack: [STACK_SIZE]u16 = [1]u16{0} ** (STACK_SIZE),
stack_write_pointer: u8 = 0,

const DISPLAY_HEIGHT = 32;
const DISPLAY_WIDTH = 64;
const STACK_SIZE: u16 = 16;
const ETI_PROGRAM_START: u16 = 0x600;
const PROGRAM_START: u16 = 0x200;

const Instruction = struct {
    code: u16,
    nnn: u16,
    n: u8,
    x: u8,
    y: u8,
    kk: u8,
};

const FONT_SET: [80]u8 = [_]u8{
    // "0"
    0xF0, 0x90, 0x90, 0x90, 0xF0,
    // "1"
    0x20, 0x60, 0x20, 0x20, 0x70,
    // "2"
    0xF0, 0x10, 0xF0, 0x80, 0xF0,
    // "3"
    0xF0, 0x10, 0xF0, 0x10, 0xF0,
    // "4"
    0x90, 0x90, 0xF0, 0x10, 0x10,
    // "5"
    0xF0, 0x80, 0xF0, 0x10, 0xF0,
    // "6"
    0xF0, 0x80, 0xF0, 0x90, 0xF0,
    // "7"
    0xF0, 0x10, 0x20, 0x40, 0x40,
    // "8"
    0xF0, 0x90, 0xF0, 0x90, 0xF0,
    // "9"
    0xF0, 0x90, 0xF0, 0x10, 0xF0,
    // "A"
    0xF0, 0x90, 0xF0, 0x90, 0x90,
    // "B"
    0xE0, 0x90, 0xE0, 0x90, 0xE0,
    // "C"
    0xF0, 0x80, 0x80, 0x80, 0xF0,
    // "D"
    0xE0, 0x90, 0x90, 0x90, 0xE0,
    // "E"
    0xF0, 0x80, 0xF0, 0x80, 0xF0,
    // "F"
    0xF0, 0x80, 0xF0, 0x80, 0x80,
};
const FONT_MEMORY_LOCATION = 0x50;
const FONT_SPRITE_SIZE = 5;

pub fn init(program_bytes: []const u8) !Emulator {
    // decide if program is ETI or STANDARD
    const start = PROGRAM_START;

    var emu: Emulator = .{
        .execute_cursor = start,
    };

    // initialize some values
    const program = emu.memory[start..];
    std.mem.copyForwards(u8, emu.memory[FONT_MEMORY_LOCATION..0xA0], &FONT_SET);
    std.mem.copyForwards(u8, program, program_bytes);
    emu.memory_s = &emu.memory;

    // for (emu.memory, emu.memory_s) |i, b| {
    //     std.debug.assert(i == b);
    // }

    return emu;
}

fn tickTimer(timer: *Timer, now: std.time.Instant) void {
    if (timer.counter == 0) return;

    if (timer.last_tick) |tick| {
        if (now.since(tick) > @divFloor(std.time.ns_per_s, 60)) {
            timer.counter -= 1;
            timer.last_tick = now;
        }
    }
}

fn handleTimers(self: *Emulator) !void {
    const now = try std.time.Instant.now();

    tickTimer(&self.delay_timer, now);
    tickTimer(&self.sound_timer, now);
}

fn handleInput(self: *Emulator) !void {
    _ = self;
}

const INSTRUCTION_STEP = 2;

const HIGH_BYTE_UPPER_BITS_FILTER: u16 = 0b1111_0000_0000_0000;
const HIGH_BYTE_LOWER_BITS_FILTER: u16 = 0b0000_1111_0000_0000;
const LOW_BYTE_UPPER_BITS_FILTER: u16 = 0b0000_0000_1111_0000;
const LOW_BYTE_LOWER_BITS_FILTER: u16 = 0b0000_0000_0000_1111;

const NNN_FILTER: u16 = HIGH_BYTE_LOWER_BITS_FILTER | LOW_BYTE_UPPER_BITS_FILTER | LOW_BYTE_LOWER_BITS_FILTER;
const N_FILTER: u16 = LOW_BYTE_LOWER_BITS_FILTER;
const X_FILTER: u16 = HIGH_BYTE_LOWER_BITS_FILTER;
const X_SHIFT: u16 = 8;
const Y_FILTER: u16 = LOW_BYTE_UPPER_BITS_FILTER;
const Y_SHIFT: u16 = 4;
const KK_FILTER: u16 = LOW_BYTE_LOWER_BITS_FILTER | LOW_BYTE_UPPER_BITS_FILTER;

const VF = 0xF;

fn printDisplay(self: *Emulator, writer: anytype) void {
    for (0..DISPLAY_HEIGHT) |y| {
        const data = self.display[y * DISPLAY_WIDTH .. ((y + 1) * DISPLAY_WIDTH)];

        _ = writer.write(data) catch unreachable;
        _ = writer.write("-\n") catch unreachable;
    }
    _ = writer.write("-" ** DISPLAY_WIDTH ++ "\n") catch unreachable;
}

fn clearDisplay(writer: anytype) void {
    _ = writer.write("\x1B[2J\x1B[H") catch unreachable;
}

pub fn executeLoop(self: *Emulator) void {
    std.log.info("HELLO", .{});

    var timer = std.time.Timer.start() catch @panic("No time");
    var writer = std.io.getStdOut().writer();
    var randomizer = std.Random.DefaultPrng.init(0);
    var random = randomizer.random();

    while (self.currentInstruction()) |instruction_bytes| : (self.advanceCursor()) {
        if (findInstruction(instruction_bytes)) |instruction| {
            switch (instruction.code) {
                0x00E0 => {
                    clearDisplay(writer);
                },
                0x00EE => {
                    self.execute_cursor = (self.popAddress() catch unreachable);
                },
                0x1000...0x1FFF => {
                    self.execute_cursor = instruction.nnn - INSTRUCTION_STEP;
                },
                0x2000...0x2FFF => {
                    self.pushAddress() catch unreachable;
                    self.execute_cursor = instruction.nnn;
                },
                0x3000...0x3FFF => {
                    if (self.registers[instruction.x] == instruction.kk) {
                        self.advanceCursor();
                    }
                },
                0x4000...0x4FFF => {
                    if (self.registers[instruction.x] != instruction.kk) {
                        self.advanceCursor();
                    }
                },
                0x5000...0x5FF0 => {
                    if (self.registers[instruction.x] == self.registers[instruction.x]) {
                        self.advanceCursor();
                    }
                },
                0x6000...0x6FFF => {
                    self.registers[instruction.x] = instruction.kk;
                },
                0x7000...0x7FFF => {
                    self.registers[instruction.x] += instruction.kk;
                },
                0x8000...0x8FF0 => {
                    switch (instruction.n) {
                        0x0 => self.registers[instruction.x] = self.registers[instruction.y],
                        0x1 => self.registers[instruction.x] |= self.registers[instruction.y],
                        0x2 => self.registers[instruction.x] &= self.registers[instruction.y],
                        0x3 => self.registers[instruction.x] ^= self.registers[instruction.y],
                        0x4 => {
                            const a = self.registers[instruction.x];
                            const b = self.registers[instruction.y];
                            self.registers[VF] = 0;

                            self.registers[instruction.x] += self.registers[instruction.y];
                            if (a > std.math.maxInt(u8) - b) {
                                self.registers[VF] = 1;
                            }
                        },
                        0x5 => {
                            const a = self.registers[instruction.x];
                            const b = self.registers[instruction.y];
                            self.registers[VF] = 0;

                            self.registers[instruction.x] -= self.registers[instruction.y];

                            if (a > b) {
                                self.registers[VF] = 1;
                            }
                        },
                        0x6 => {
                            self.registers[VF] = self.registers[instruction.x] & 1;
                            self.registers[instruction.x] = self.registers[instruction.x] >> 1;
                        },
                        0x7 => {
                            const a = self.registers[instruction.x];
                            const b = self.registers[instruction.y];
                            self.registers[VF] = 0;

                            self.registers[instruction.y] -= self.registers[instruction.x];

                            if (b > a) {
                                self.registers[VF] = 1;
                            }
                        },
                        0xE => {
                            self.registers[VF] = self.registers[instruction.x] & (1 << 7);
                            self.registers[instruction.x] = self.registers[instruction.x] << 1;
                        },
                        else => unreachable,
                    }
                },
                0x9000...0x9FFF => {
                    if (self.registers[instruction.x] != self.registers[instruction.y]) {
                        self.advanceCursor();
                    }
                },
                0xA000...0xAFFF => {
                    self.memory_index = instruction.nnn;
                },
                0xB000...0xBFFF => {
                    self.execute_cursor = self.registers[0] + instruction.nnn;
                },
                0xC000...0xCFFF => {
                    self.registers[instruction.x] = random.int(u8) & instruction.kk;
                },
                0xE09E...0xEF9E => {
                    switch (instruction.kk) {
                        0x9E => {
                            // TODO{metty}: WHEN WE READ INPUT
                            std.log.info("Have yet to support input", .{});
                        },
                        0xA1 => {
                            // TODO{metty}: WHEN WE READ INPUT
                            std.log.info("Have yet to support input", .{});
                        },
                        else => unreachable,
                    }
                },
                0xF000...0xFFFF => {
                    switch (instruction.kk) {
                        0x07 => {
                            self.registers[instruction.x] = self.delay_timer.counter;
                        },
                        0x0A => {
                            // TODO{metty}: WHEN WE READ INPUT
                            self.execute_cursor -= INSTRUCTION_STEP;
                            std.log.info("Waiting for input", .{});
                        },
                        0x15 => {
                            self.delay_timer.counter = self.registers[instruction.x];
                        },
                        0x18 => {
                            self.sound_timer.counter = self.registers[instruction.x];
                        },
                        0x1E => {
                            self.memory_index += self.registers[instruction.x];
                        },
                        0x29 => {
                            self.memory_index = FONT_MEMORY_LOCATION + (self.registers[instruction.x] * FONT_SPRITE_SIZE);
                        },
                        0x33 => {
                            const number = self.registers[instruction.x];
                            const hundreds = @divFloor(number, 100);
                            const tens = @divFloor(number - hundreds, 10);
                            const ones = number - (hundreds + tens);

                            self.memory[self.memory_index + 0] = hundreds;
                            self.memory[self.memory_index + 1] = tens;
                            self.memory[self.memory_index + 2] = ones;
                        },
                        0x55 => {
                            for (0..instruction.x + 1) |i| {
                                self.memory[self.memory_index + i] = self.registers[i];
                            }
                        },
                        0x65 => {
                            for (0..instruction.x + 1) |i| {
                                self.registers[i] = self.memory[self.memory_index + i];
                            }
                        },
                        else => unreachable,
                    }
                },
                0xD000...0xDFFF => {
                    const data = self.memory[self.memory_index..(self.memory_index + instruction.n)];

                    const vx = self.registers[instruction.x] % DISPLAY_WIDTH;
                    const vy = self.registers[instruction.y] % DISPLAY_HEIGHT;

                    self.registers[VF] = 0;

                    for (data, 0..) |byte, count| {
                        if ((vy + count) >= DISPLAY_HEIGHT) {
                            break;
                        }

                        const y = (vy + count) * DISPLAY_WIDTH;

                        inline for (0..8) |offset| {
                            const bit = byte & (1 << (7 - offset));

                            if (bit != 0) {
                                if (vx + offset >= DISPLAY_WIDTH) {
                                    break;
                                }

                                const x = vx + offset;

                                const position = x + y;
                                const value = self.display[position];

                                if (value == '#') {
                                    self.registers[VF] = 1;
                                    self.display[position] = ' ';
                                } else {
                                    self.display[position] = '#';
                                }
                            }
                        }
                    }

                    clearDisplay(writer);
                    self.printDisplay(&writer);
                },
                else => {
                    std.log.info("{} {}", .{ instruction_bytes, self.execute_cursor });
                    unreachable;
                },
            }
        } else |err| {
            std.log.err("Illegal Instruction Found {}.", .{err});
        }

        self.handleTimers() catch |err| {
            std.log.err("We failed to get the current time stamp {}.", .{err});
        };
        const time = timer.read();

        if (time < std.time.ns_per_s / 700) {
            std.Thread.sleep((std.time.ns_per_s / 700) - time);
        }
        timer.reset();
    } else {
        std.log.info("Reached the end of the program.", .{});
    }
}

fn currentInstruction(self: *Emulator) ?u16 {
    const upper: u16 = self.memory_s[self.execute_cursor];
    const lower: u16 = self.memory_s[self.execute_cursor + 1];

    std.log.info("{} {}", .{ self.execute_cursor, self.execute_cursor + 1 });
    std.debug.assert(self.memory[self.execute_cursor] == self.memory_s[self.execute_cursor]);
    std.debug.assert(self.memory[self.execute_cursor + 1] == self.memory_s[self.execute_cursor + 1]);

    const oldinstruction = (upper << 8) | lower;

    return oldinstruction;
}

fn advanceCursor(self: *Emulator) void {
    self.execute_cursor += INSTRUCTION_STEP;
}

fn findInstruction(instruction: u16) !Instruction {
    const nnn = instruction & NNN_FILTER;
    const n: u8 = @intCast(instruction & N_FILTER);
    const x: u8 = @intCast((instruction & X_FILTER) >> X_SHIFT);
    const y: u8 = @intCast((instruction & Y_FILTER) >> Y_SHIFT);
    const kk: u8 = @intCast(instruction & KK_FILTER);

    return .{
        .code = instruction,
        .nnn = nnn,
        .n = n,
        .x = x,
        .y = y,
        .kk = kk,
    };
}

fn pushAddress(self: *Emulator) !void {
    if (self.stack_write_pointer == STACK_SIZE + 1) {
        return error.StackOverflow;
    }

    self.stack[self.stack_write_pointer] = self.execute_cursor;
    self.stack_write_pointer += 1;
}

fn popAddress(self: *Emulator) !u16 {
    if (self.stack_write_pointer == 0) {
        return error.EmptyStack;
    }

    defer self.stack_write_pointer -= 1;
    return self.stack[self.stack_write_pointer - 1];
}

fn peekAddress(self: *Emulator) ?u8 {
    if (self.stack_write_pointer == 0) {
        return error.EmptyStack;
    }

    return self.stack[self.stack_write_pointer - 1];
}
