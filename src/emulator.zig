const std = @import("std");
const Emulator = @This();

const Timer = struct {
    counter: u8 = 0,
    last_tick: ?std.time.Instant = null,
};

memory: [1024 * 4]u8 = [1]u8{0} ** (1024 * 4),
registers: [16]u8 = [1]u8{0} ** 16,

delay_timer: Timer = .{},
sound_timer: Timer = .{},

memory_index: u16 = 0,
execute_cursor: u16 = 0,

// NOT A MEMORY STACK BUT RATHER A RETURN ADDRESS STACK!!!!
stack_core: [STACK_SIZE]u16 = [1]u16{0} ** (STACK_SIZE),
stack_write_pointer: u8 = 0,

const STACK_SIZE: u16 = 16;
const ETI_PROGRAM_START: u16 = 0x600;
const PROGRAM_START: u16 = 0x200;

const Instruction = struct {
    type: InstructionsType,
    nnn: u16,
    n: u8,
    x: u8,
    y: u8,
    kk: u8,
};

const InstructionsType = enum(u16) {
    // SYS_ADDR = 0x0000, // Ignored by modern interpreters
    CLS = 0x00E0,
    RET = 0x00EE,
    JP_ADDR = 0x1000,
    CALL_ADDR = 0x2000,
    SE_VX_KK = 0x3000,
    SNE_VX_KK = 0x4000,
    SE_VX_VY = 0x5000,
    LD_VX_KK = 0x6000,
    ADD_VX_KK = 0x7000,
    LD_VX_VY = 0x8000,
    OR_VX_VY = 0x8001,
    AND_VX_VY = 0x8002,
    XOR_VX_VY = 0x8003,
    ADD_VX_VY = 0x8004,
    SUB_VX_VY = 0x8005,
    SHR_VX = 0x8006,
    SUBN_VX_VY = 0x8007,
    SHL_VX = 0x800E,
    SNE_VX_VY = 0x9000,
    LD_I_ADDR = 0xA000,
    JP_V0_ADDR = 0xB000,
    RND_VX_KK = 0xC000,
    DRW_VX_VY_N = 0xD000,
    SKP_VX = 0xE09E,
    SKNP_VX = 0xE0A1,
    LD_VX_DT = 0xF007,
    LD_VX_K = 0xF00A,
    LD_DT_VX = 0xF015,
    LD_ST_VX = 0xF018,
    ADD_I_VX = 0xF01E,
    LD_F_VX = 0xF029,
    LD_BCD_VX = 0xF033,
    LD_MEM_I_VX = 0xF055,
    LD_VX_MEM_I = 0xF065,
};

const REVERSE_INST = [_]InstructionsType{
    .LD_VX_MEM_I,
    .LD_MEM_I_VX,
    .LD_BCD_VX,
    .LD_F_VX,
    .ADD_I_VX,
    .LD_ST_VX,
    .LD_DT_VX,
    .LD_VX_K,
    .LD_VX_DT,
    .SKNP_VX,
    .SKP_VX,
    .DRW_VX_VY_N,
    .RND_VX_KK,
    .JP_V0_ADDR,
    .LD_I_ADDR,
    .SNE_VX_VY,
    .SHL_VX,
    .SUBN_VX_VY,
    .SHR_VX,
    .SUB_VX_VY,
    .ADD_VX_VY,
    .XOR_VX_VY,
    .AND_VX_VY,
    .OR_VX_VY,
    .LD_VX_VY,
    .ADD_VX_KK,
    .LD_VX_KK,
    .SE_VX_VY,
    .SNE_VX_KK,
    .SE_VX_KK,
    .CALL_ADDR,
    .JP_ADDR,
    .RET,
    .CLS,
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

pub fn init(program_bytes: []const u8) !Emulator {
    // decide if program is ETI or STANDARD
    const start = PROGRAM_START;

    var emu: Emulator = .{
        .execute_cursor = start,
    };

    // initialize some values
    const program = emu.memory[emu.execute_cursor..];
    std.mem.copyForwards(u8, &emu.memory, &FONT_SET);
    std.mem.copyForwards(u8, program, program_bytes);

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

pub fn executeLoop(self: *Emulator) void {
    std.log.info("HELLO", .{});

    var timer = std.time.Timer.start() catch @panic("No time");
    while (self.next()) |instruction_bytes| {
        timer.reset();
        if (findInstruction(instruction_bytes)) |instruction| {
            switch (instruction.type) {
                .CLS => {
                    std.log.info("Supposed to clear screen", .{});
                },
                .JP_ADDR => {
                    self.execute_cursor = instruction.nnn;
                },
                .LD_VX_K => {
                    self.execute_cursor -= INSTRUCTION_STEP;
                    std.log.info("Waiting for input", .{});
                },
                .LD_VX_KK => {
                    self.registers[instruction.x] = instruction.kk;
                },
                .ADD_VX_KK => {
                    self.registers[instruction.x] += instruction.kk;
                },
                .LD_I_ADDR => {
                    self.memory_index = instruction.nnn;
                },
                .DRW_VX_VY_N => {
                    std.log.info("Supposed to draw to screen", .{});
                },
                else => {},
            }
        } else |err| {
            std.log.err("Illegal Instruction Found {}.", .{err});
        }

        self.handleTimers() catch |err| {
            std.log.err("We failed to get the current time stamp {}.", .{err});
        };

        std.Thread.sleep((std.time.ns_per_s / 950) - timer.read());
    } else {
        std.log.info("Reached the end of the program.", .{});
    }
}

fn next(self: *Emulator) ?u16 {
    const upper: u16 = self.memory[self.execute_cursor];
    self.execute_cursor += 1;
    const lower: u16 = self.memory[self.execute_cursor];
    self.execute_cursor += 1;

    const instruction = (upper << 8) | lower;
    return instruction;
}

fn findInstruction(instruction: u16) !Instruction {
    const nnn = instruction & NNN_FILTER;
    const n: u8 = @intCast(instruction & N_FILTER);
    const x: u8 = @intCast((instruction & X_FILTER) >> X_SHIFT);
    const y: u8 = @intCast((instruction & Y_FILTER) >> Y_SHIFT);
    const kk: u8 = @intCast(instruction & KK_FILTER);

    inline for (REVERSE_INST) |field| {
        const instruction_enum: u16 = @intFromEnum(field);
        const instruction_byte: u16 = (instruction_enum & instruction);

        if (instruction_byte == instruction_enum) {
            const instructionsType: InstructionsType = @enumFromInt(instruction_enum);

            return .{
                .type = instructionsType,
                .nnn = nnn,
                .n = n,
                .x = x,
                .y = y,
                .kk = kk,
            };
        }
    }

    return error.InvalidInstruction;
}

fn pushAddress(self: *Emulator, address: u16) !void {
    if (self.stack_write_pointer == STACK_SIZE + 1) {
        return error.StackOverflow;
    }

    self.stack[self.stack_write_pointer] = address;
    self.stack_write_pointer += 1;
}

fn popAddress(self: *Emulator) !u16 {
    if (self.stack_write_pointer == 1) {
        return error.EmptyStack;
    }

    defer self.stack_write_pointer -= 1;
    return self.stack[self.stack_write_pointer - 1];
}

fn peekAddress(self: *Emulator) ?u8 {
    if (self.stack_write_pointer == 1) {
        return error.EmptyStack;
    }

    return self.stack[self.stack_write_pointer - 1];
}
