const std = @import("std");
const Bus = @import("bus.zig").Bus;
const Interrupt = @import("bus.zig").Interrupt;

/// SM83 CPU (Sharp LR35902)
/// A modified Z80 used in the GameBoy
pub const Cpu = struct {
    // 8-bit registers
    a: u8 = 0,
    f: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,

    // 16-bit registers
    sp: u16 = 0,
    pc: u16 = 0,

    // CPU state
    ime: bool = false, // Interrupt Master Enable
    ime_scheduled: bool = false, // EI schedules IME for next instruction
    halted: bool = false,
    stopped: bool = false,

    // Memory bus reference
    bus: *Bus,

    // Cycle counter (T-cycles)
    cycles: u64 = 0,

    const Self = @This();

    // Flag bit positions
    const FLAG_Z: u8 = 0x80; // Zero
    const FLAG_N: u8 = 0x40; // Subtract
    const FLAG_H: u8 = 0x20; // Half Carry
    const FLAG_C: u8 = 0x10; // Carry

    pub fn init(bus: *Bus) Self {
        var cpu = Self{
            .bus = bus,
        };
        // Post-boot ROM state
        cpu.a = 0x01;
        cpu.f = 0xB0;
        cpu.b = 0x00;
        cpu.c = 0x13;
        cpu.d = 0x00;
        cpu.e = 0xD8;
        cpu.h = 0x01;
        cpu.l = 0x4D;
        cpu.sp = 0xFFFE;
        cpu.pc = 0x0100; // Entry point after boot ROM
        return cpu;
    }

    // 16-bit register pairs
    pub fn af(self: *Self) u16 {
        return (@as(u16, self.a) << 8) | (self.f & 0xF0);
    }

    pub fn setAf(self: *Self, value: u16) void {
        self.a = @truncate(value >> 8);
        self.f = @truncate(value & 0xF0);
    }

    pub fn bc(self: *Self) u16 {
        return (@as(u16, self.b) << 8) | self.c;
    }

    pub fn setBc(self: *Self, value: u16) void {
        self.b = @truncate(value >> 8);
        self.c = @truncate(value);
    }

    pub fn de(self: *Self) u16 {
        return (@as(u16, self.d) << 8) | self.e;
    }

    pub fn setDe(self: *Self, value: u16) void {
        self.d = @truncate(value >> 8);
        self.e = @truncate(value);
    }

    pub fn hl(self: *Self) u16 {
        return (@as(u16, self.h) << 8) | self.l;
    }

    pub fn setHl(self: *Self, value: u16) void {
        self.h = @truncate(value >> 8);
        self.l = @truncate(value);
    }

    // Flag helpers
    fn getFlag(self: *Self, flag: u8) bool {
        return (self.f & flag) != 0;
    }

    fn setFlag(self: *Self, flag: u8, value: bool) void {
        if (value) {
            self.f |= flag;
        } else {
            self.f &= ~flag;
        }
    }

    fn setFlags(self: *Self, z: ?bool, n: ?bool, h: ?bool, c: ?bool) void {
        if (z) |v| self.setFlag(FLAG_Z, v);
        if (n) |v| self.setFlag(FLAG_N, v);
        if (h) |v| self.setFlag(FLAG_H, v);
        if (c) |v| self.setFlag(FLAG_C, v);
    }

    // Memory access
    fn read(self: *Self, addr: u16) u8 {
        return self.bus.read(addr);
    }

    fn write(self: *Self, addr: u16, value: u8) void {
        self.bus.write(addr, value);
    }

    fn readPc(self: *Self) u8 {
        const value = self.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    fn readPc16(self: *Self) u16 {
        const lo = self.readPc();
        const hi = self.readPc();
        return (@as(u16, hi) << 8) | lo;
    }

    // Stack operations
    fn push(self: *Self, value: u16) void {
        self.sp -%= 1;
        self.write(self.sp, @truncate(value >> 8));
        self.sp -%= 1;
        self.write(self.sp, @truncate(value));
    }

    fn pop(self: *Self) u16 {
        const lo = self.read(self.sp);
        self.sp +%= 1;
        const hi = self.read(self.sp);
        self.sp +%= 1;
        return (@as(u16, hi) << 8) | lo;
    }

    /// Execute one instruction and return T-cycles consumed
    pub fn step(self: *Self) u32 {
        // Handle scheduled IME
        if (self.ime_scheduled) {
            self.ime_scheduled = false;
            self.ime = true;
        }

        // Check for interrupts
        if (self.ime) {
            const int_cycles = self.handleInterrupts();
            if (int_cycles > 0) {
                return int_cycles;
            }
        }

        // If halted, just consume 4 cycles
        if (self.halted) {
            // Check if any interrupt would wake us
            const if_reg = self.bus.getIF();
            const ie_reg = self.bus.ie;
            if ((if_reg & ie_reg & 0x1F) != 0) {
                self.halted = false;
            } else {
                return 4;
            }
        }

        const opcode = self.readPc();
        return self.execute(opcode);
    }

    fn handleInterrupts(self: *Self) u32 {
        const if_reg = self.bus.getIF();
        const ie_reg = self.bus.ie;
        const pending = if_reg & ie_reg & 0x1F;

        if (pending == 0) return 0;

        self.ime = false;
        self.halted = false;

        // Find highest priority interrupt
        const int_bit: u8 = @ctz(pending);
        const int_flag: u8 = @as(u8, 1) << @intCast(int_bit);

        // Clear interrupt flag
        self.bus.setIF(if_reg & ~int_flag);

        // Push PC and jump to handler
        self.push(self.pc);

        const handlers = [_]u16{ 0x0040, 0x0048, 0x0050, 0x0058, 0x0060 };
        self.pc = handlers[int_bit];

        return 20; // Interrupt handling takes 20 cycles
    }

    fn execute(self: *Self, opcode: u8) u32 {
        return switch (opcode) {
            // NOP
            0x00 => 4,

            // LD BC,nn
            0x01 => blk: {
                const value = self.readPc16();
                self.setBc(value);
                break :blk 12;
            },

            // LD (BC),A
            0x02 => blk: {
                self.write(self.bc(), self.a);
                break :blk 8;
            },

            // INC BC
            0x03 => blk: {
                self.setBc(self.bc() +% 1);
                break :blk 8;
            },

            // INC B
            0x04 => blk: {
                self.b = self.inc(self.b);
                break :blk 4;
            },

            // DEC B
            0x05 => blk: {
                self.b = self.dec(self.b);
                break :blk 4;
            },

            // LD B,n
            0x06 => blk: {
                self.b = self.readPc();
                break :blk 8;
            },

            // RLCA
            0x07 => blk: {
                const carry = (self.a >> 7) & 1;
                self.a = (self.a << 1) | carry;
                self.setFlags(false, false, false, carry == 1);
                break :blk 4;
            },

            // LD (nn),SP
            0x08 => blk: {
                const addr = self.readPc16();
                self.write(addr, @truncate(self.sp));
                self.write(addr +% 1, @truncate(self.sp >> 8));
                break :blk 20;
            },

            // ADD HL,BC
            0x09 => blk: {
                self.addHl(self.bc());
                break :blk 8;
            },

            // LD A,(BC)
            0x0A => blk: {
                self.a = self.read(self.bc());
                break :blk 8;
            },

            // DEC BC
            0x0B => blk: {
                self.setBc(self.bc() -% 1);
                break :blk 8;
            },

            // INC C
            0x0C => blk: {
                self.c = self.inc(self.c);
                break :blk 4;
            },

            // DEC C
            0x0D => blk: {
                self.c = self.dec(self.c);
                break :blk 4;
            },

            // LD C,n
            0x0E => blk: {
                self.c = self.readPc();
                break :blk 8;
            },

            // RRCA
            0x0F => blk: {
                const carry = self.a & 1;
                self.a = (self.a >> 1) | (carry << 7);
                self.setFlags(false, false, false, carry == 1);
                break :blk 4;
            },

            // STOP
            0x10 => blk: {
                _ = self.readPc(); // Skip byte after STOP
                self.stopped = true;
                break :blk 4;
            },

            // LD DE,nn
            0x11 => blk: {
                const value = self.readPc16();
                self.setDe(value);
                break :blk 12;
            },

            // LD (DE),A
            0x12 => blk: {
                self.write(self.de(), self.a);
                break :blk 8;
            },

            // INC DE
            0x13 => blk: {
                self.setDe(self.de() +% 1);
                break :blk 8;
            },

            // INC D
            0x14 => blk: {
                self.d = self.inc(self.d);
                break :blk 4;
            },

            // DEC D
            0x15 => blk: {
                self.d = self.dec(self.d);
                break :blk 4;
            },

            // LD D,n
            0x16 => blk: {
                self.d = self.readPc();
                break :blk 8;
            },

            // RLA
            0x17 => blk: {
                const old_carry: u8 = if (self.getFlag(FLAG_C)) 1 else 0;
                const new_carry = (self.a >> 7) & 1;
                self.a = (self.a << 1) | old_carry;
                self.setFlags(false, false, false, new_carry == 1);
                break :blk 4;
            },

            // JR n
            0x18 => blk: {
                const offset: i8 = @bitCast(self.readPc());
                const pc_i32: i32 = @intCast(self.pc);
                const new_pc: i32 = pc_i32 +% offset;
                self.pc = @intCast(@as(u32, @bitCast(new_pc)) & 0xFFFF);
                break :blk 12;
            },

            // ADD HL,DE
            0x19 => blk: {
                self.addHl(self.de());
                break :blk 8;
            },

            // LD A,(DE)
            0x1A => blk: {
                self.a = self.read(self.de());
                break :blk 8;
            },

            // DEC DE
            0x1B => blk: {
                self.setDe(self.de() -% 1);
                break :blk 8;
            },

            // INC E
            0x1C => blk: {
                self.e = self.inc(self.e);
                break :blk 4;
            },

            // DEC E
            0x1D => blk: {
                self.e = self.dec(self.e);
                break :blk 4;
            },

            // LD E,n
            0x1E => blk: {
                self.e = self.readPc();
                break :blk 8;
            },

            // RRA
            0x1F => blk: {
                const old_carry: u8 = if (self.getFlag(FLAG_C)) 0x80 else 0;
                const new_carry = self.a & 1;
                self.a = (self.a >> 1) | old_carry;
                self.setFlags(false, false, false, new_carry == 1);
                break :blk 4;
            },

            // JR NZ,n
            0x20 => self.jr(!self.getFlag(FLAG_Z)),

            // LD HL,nn
            0x21 => blk: {
                const value = self.readPc16();
                self.setHl(value);
                break :blk 12;
            },

            // LD (HL+),A
            0x22 => blk: {
                self.write(self.hl(), self.a);
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },

            // INC HL
            0x23 => blk: {
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },

            // INC H
            0x24 => blk: {
                self.h = self.inc(self.h);
                break :blk 4;
            },

            // DEC H
            0x25 => blk: {
                self.h = self.dec(self.h);
                break :blk 4;
            },

            // LD H,n
            0x26 => blk: {
                self.h = self.readPc();
                break :blk 8;
            },

            // DAA
            0x27 => blk: {
                self.daa();
                break :blk 4;
            },

            // JR Z,n
            0x28 => self.jr(self.getFlag(FLAG_Z)),

            // ADD HL,HL
            0x29 => blk: {
                self.addHl(self.hl());
                break :blk 8;
            },

            // LD A,(HL+)
            0x2A => blk: {
                self.a = self.read(self.hl());
                self.setHl(self.hl() +% 1);
                break :blk 8;
            },

            // DEC HL
            0x2B => blk: {
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },

            // INC L
            0x2C => blk: {
                self.l = self.inc(self.l);
                break :blk 4;
            },

            // DEC L
            0x2D => blk: {
                self.l = self.dec(self.l);
                break :blk 4;
            },

            // LD L,n
            0x2E => blk: {
                self.l = self.readPc();
                break :blk 8;
            },

            // CPL
            0x2F => blk: {
                self.a = ~self.a;
                self.setFlags(null, true, true, null);
                break :blk 4;
            },

            // JR NC,n
            0x30 => self.jr(!self.getFlag(FLAG_C)),

            // LD SP,nn
            0x31 => blk: {
                self.sp = self.readPc16();
                break :blk 12;
            },

            // LD (HL-),A
            0x32 => blk: {
                self.write(self.hl(), self.a);
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },

            // INC SP
            0x33 => blk: {
                self.sp +%= 1;
                break :blk 8;
            },

            // INC (HL)
            0x34 => blk: {
                const value = self.inc(self.read(self.hl()));
                self.write(self.hl(), value);
                break :blk 12;
            },

            // DEC (HL)
            0x35 => blk: {
                const value = self.dec(self.read(self.hl()));
                self.write(self.hl(), value);
                break :blk 12;
            },

            // LD (HL),n
            0x36 => blk: {
                self.write(self.hl(), self.readPc());
                break :blk 12;
            },

            // SCF
            0x37 => blk: {
                self.setFlags(null, false, false, true);
                break :blk 4;
            },

            // JR C,n
            0x38 => self.jr(self.getFlag(FLAG_C)),

            // ADD HL,SP
            0x39 => blk: {
                self.addHl(self.sp);
                break :blk 8;
            },

            // LD A,(HL-)
            0x3A => blk: {
                self.a = self.read(self.hl());
                self.setHl(self.hl() -% 1);
                break :blk 8;
            },

            // DEC SP
            0x3B => blk: {
                self.sp -%= 1;
                break :blk 8;
            },

            // INC A
            0x3C => blk: {
                self.a = self.inc(self.a);
                break :blk 4;
            },

            // DEC A
            0x3D => blk: {
                self.a = self.dec(self.a);
                break :blk 4;
            },

            // LD A,n
            0x3E => blk: {
                self.a = self.readPc();
                break :blk 8;
            },

            // CCF
            0x3F => blk: {
                self.setFlags(null, false, false, !self.getFlag(FLAG_C));
                break :blk 4;
            },

            // LD B,r and LD B,(HL)
            0x40 => 4, // LD B,B
            0x41 => blk: {
                self.b = self.c;
                break :blk 4;
            },
            0x42 => blk: {
                self.b = self.d;
                break :blk 4;
            },
            0x43 => blk: {
                self.b = self.e;
                break :blk 4;
            },
            0x44 => blk: {
                self.b = self.h;
                break :blk 4;
            },
            0x45 => blk: {
                self.b = self.l;
                break :blk 4;
            },
            0x46 => blk: {
                self.b = self.read(self.hl());
                break :blk 8;
            },
            0x47 => blk: {
                self.b = self.a;
                break :blk 4;
            },

            // LD C,r and LD C,(HL)
            0x48 => blk: {
                self.c = self.b;
                break :blk 4;
            },
            0x49 => 4, // LD C,C
            0x4A => blk: {
                self.c = self.d;
                break :blk 4;
            },
            0x4B => blk: {
                self.c = self.e;
                break :blk 4;
            },
            0x4C => blk: {
                self.c = self.h;
                break :blk 4;
            },
            0x4D => blk: {
                self.c = self.l;
                break :blk 4;
            },
            0x4E => blk: {
                self.c = self.read(self.hl());
                break :blk 8;
            },
            0x4F => blk: {
                self.c = self.a;
                break :blk 4;
            },

            // LD D,r and LD D,(HL)
            0x50 => blk: {
                self.d = self.b;
                break :blk 4;
            },
            0x51 => blk: {
                self.d = self.c;
                break :blk 4;
            },
            0x52 => 4, // LD D,D
            0x53 => blk: {
                self.d = self.e;
                break :blk 4;
            },
            0x54 => blk: {
                self.d = self.h;
                break :blk 4;
            },
            0x55 => blk: {
                self.d = self.l;
                break :blk 4;
            },
            0x56 => blk: {
                self.d = self.read(self.hl());
                break :blk 8;
            },
            0x57 => blk: {
                self.d = self.a;
                break :blk 4;
            },

            // LD E,r and LD E,(HL)
            0x58 => blk: {
                self.e = self.b;
                break :blk 4;
            },
            0x59 => blk: {
                self.e = self.c;
                break :blk 4;
            },
            0x5A => blk: {
                self.e = self.d;
                break :blk 4;
            },
            0x5B => 4, // LD E,E
            0x5C => blk: {
                self.e = self.h;
                break :blk 4;
            },
            0x5D => blk: {
                self.e = self.l;
                break :blk 4;
            },
            0x5E => blk: {
                self.e = self.read(self.hl());
                break :blk 8;
            },
            0x5F => blk: {
                self.e = self.a;
                break :blk 4;
            },

            // LD H,r and LD H,(HL)
            0x60 => blk: {
                self.h = self.b;
                break :blk 4;
            },
            0x61 => blk: {
                self.h = self.c;
                break :blk 4;
            },
            0x62 => blk: {
                self.h = self.d;
                break :blk 4;
            },
            0x63 => blk: {
                self.h = self.e;
                break :blk 4;
            },
            0x64 => 4, // LD H,H
            0x65 => blk: {
                self.h = self.l;
                break :blk 4;
            },
            0x66 => blk: {
                self.h = self.read(self.hl());
                break :blk 8;
            },
            0x67 => blk: {
                self.h = self.a;
                break :blk 4;
            },

            // LD L,r and LD L,(HL)
            0x68 => blk: {
                self.l = self.b;
                break :blk 4;
            },
            0x69 => blk: {
                self.l = self.c;
                break :blk 4;
            },
            0x6A => blk: {
                self.l = self.d;
                break :blk 4;
            },
            0x6B => blk: {
                self.l = self.e;
                break :blk 4;
            },
            0x6C => blk: {
                self.l = self.h;
                break :blk 4;
            },
            0x6D => 4, // LD L,L
            0x6E => blk: {
                self.l = self.read(self.hl());
                break :blk 8;
            },
            0x6F => blk: {
                self.l = self.a;
                break :blk 4;
            },

            // LD (HL),r
            0x70 => blk: {
                self.write(self.hl(), self.b);
                break :blk 8;
            },
            0x71 => blk: {
                self.write(self.hl(), self.c);
                break :blk 8;
            },
            0x72 => blk: {
                self.write(self.hl(), self.d);
                break :blk 8;
            },
            0x73 => blk: {
                self.write(self.hl(), self.e);
                break :blk 8;
            },
            0x74 => blk: {
                self.write(self.hl(), self.h);
                break :blk 8;
            },
            0x75 => blk: {
                self.write(self.hl(), self.l);
                break :blk 8;
            },

            // HALT
            0x76 => blk: {
                self.halted = true;
                break :blk 4;
            },

            0x77 => blk: {
                self.write(self.hl(), self.a);
                break :blk 8;
            },

            // LD A,r and LD A,(HL)
            0x78 => blk: {
                self.a = self.b;
                break :blk 4;
            },
            0x79 => blk: {
                self.a = self.c;
                break :blk 4;
            },
            0x7A => blk: {
                self.a = self.d;
                break :blk 4;
            },
            0x7B => blk: {
                self.a = self.e;
                break :blk 4;
            },
            0x7C => blk: {
                self.a = self.h;
                break :blk 4;
            },
            0x7D => blk: {
                self.a = self.l;
                break :blk 4;
            },
            0x7E => blk: {
                self.a = self.read(self.hl());
                break :blk 8;
            },
            0x7F => 4, // LD A,A

            // ADD A,r
            0x80 => blk: {
                self.add(self.b, false);
                break :blk 4;
            },
            0x81 => blk: {
                self.add(self.c, false);
                break :blk 4;
            },
            0x82 => blk: {
                self.add(self.d, false);
                break :blk 4;
            },
            0x83 => blk: {
                self.add(self.e, false);
                break :blk 4;
            },
            0x84 => blk: {
                self.add(self.h, false);
                break :blk 4;
            },
            0x85 => blk: {
                self.add(self.l, false);
                break :blk 4;
            },
            0x86 => blk: {
                self.add(self.read(self.hl()), false);
                break :blk 8;
            },
            0x87 => blk: {
                self.add(self.a, false);
                break :blk 4;
            },

            // ADC A,r
            0x88 => blk: {
                self.add(self.b, true);
                break :blk 4;
            },
            0x89 => blk: {
                self.add(self.c, true);
                break :blk 4;
            },
            0x8A => blk: {
                self.add(self.d, true);
                break :blk 4;
            },
            0x8B => blk: {
                self.add(self.e, true);
                break :blk 4;
            },
            0x8C => blk: {
                self.add(self.h, true);
                break :blk 4;
            },
            0x8D => blk: {
                self.add(self.l, true);
                break :blk 4;
            },
            0x8E => blk: {
                self.add(self.read(self.hl()), true);
                break :blk 8;
            },
            0x8F => blk: {
                self.add(self.a, true);
                break :blk 4;
            },

            // SUB A,r
            0x90 => blk: {
                self.sub(self.b, false);
                break :blk 4;
            },
            0x91 => blk: {
                self.sub(self.c, false);
                break :blk 4;
            },
            0x92 => blk: {
                self.sub(self.d, false);
                break :blk 4;
            },
            0x93 => blk: {
                self.sub(self.e, false);
                break :blk 4;
            },
            0x94 => blk: {
                self.sub(self.h, false);
                break :blk 4;
            },
            0x95 => blk: {
                self.sub(self.l, false);
                break :blk 4;
            },
            0x96 => blk: {
                self.sub(self.read(self.hl()), false);
                break :blk 8;
            },
            0x97 => blk: {
                self.sub(self.a, false);
                break :blk 4;
            },

            // SBC A,r
            0x98 => blk: {
                self.sub(self.b, true);
                break :blk 4;
            },
            0x99 => blk: {
                self.sub(self.c, true);
                break :blk 4;
            },
            0x9A => blk: {
                self.sub(self.d, true);
                break :blk 4;
            },
            0x9B => blk: {
                self.sub(self.e, true);
                break :blk 4;
            },
            0x9C => blk: {
                self.sub(self.h, true);
                break :blk 4;
            },
            0x9D => blk: {
                self.sub(self.l, true);
                break :blk 4;
            },
            0x9E => blk: {
                self.sub(self.read(self.hl()), true);
                break :blk 8;
            },
            0x9F => blk: {
                self.sub(self.a, true);
                break :blk 4;
            },

            // AND A,r
            0xA0 => blk: {
                self.andA(self.b);
                break :blk 4;
            },
            0xA1 => blk: {
                self.andA(self.c);
                break :blk 4;
            },
            0xA2 => blk: {
                self.andA(self.d);
                break :blk 4;
            },
            0xA3 => blk: {
                self.andA(self.e);
                break :blk 4;
            },
            0xA4 => blk: {
                self.andA(self.h);
                break :blk 4;
            },
            0xA5 => blk: {
                self.andA(self.l);
                break :blk 4;
            },
            0xA6 => blk: {
                self.andA(self.read(self.hl()));
                break :blk 8;
            },
            0xA7 => blk: {
                self.andA(self.a);
                break :blk 4;
            },

            // XOR A,r
            0xA8 => blk: {
                self.xorA(self.b);
                break :blk 4;
            },
            0xA9 => blk: {
                self.xorA(self.c);
                break :blk 4;
            },
            0xAA => blk: {
                self.xorA(self.d);
                break :blk 4;
            },
            0xAB => blk: {
                self.xorA(self.e);
                break :blk 4;
            },
            0xAC => blk: {
                self.xorA(self.h);
                break :blk 4;
            },
            0xAD => blk: {
                self.xorA(self.l);
                break :blk 4;
            },
            0xAE => blk: {
                self.xorA(self.read(self.hl()));
                break :blk 8;
            },
            0xAF => blk: {
                self.xorA(self.a);
                break :blk 4;
            },

            // OR A,r
            0xB0 => blk: {
                self.orA(self.b);
                break :blk 4;
            },
            0xB1 => blk: {
                self.orA(self.c);
                break :blk 4;
            },
            0xB2 => blk: {
                self.orA(self.d);
                break :blk 4;
            },
            0xB3 => blk: {
                self.orA(self.e);
                break :blk 4;
            },
            0xB4 => blk: {
                self.orA(self.h);
                break :blk 4;
            },
            0xB5 => blk: {
                self.orA(self.l);
                break :blk 4;
            },
            0xB6 => blk: {
                self.orA(self.read(self.hl()));
                break :blk 8;
            },
            0xB7 => blk: {
                self.orA(self.a);
                break :blk 4;
            },

            // CP A,r
            0xB8 => blk: {
                self.cp(self.b);
                break :blk 4;
            },
            0xB9 => blk: {
                self.cp(self.c);
                break :blk 4;
            },
            0xBA => blk: {
                self.cp(self.d);
                break :blk 4;
            },
            0xBB => blk: {
                self.cp(self.e);
                break :blk 4;
            },
            0xBC => blk: {
                self.cp(self.h);
                break :blk 4;
            },
            0xBD => blk: {
                self.cp(self.l);
                break :blk 4;
            },
            0xBE => blk: {
                self.cp(self.read(self.hl()));
                break :blk 8;
            },
            0xBF => blk: {
                self.cp(self.a);
                break :blk 4;
            },

            // RET NZ
            0xC0 => self.ret(!self.getFlag(FLAG_Z)),

            // POP BC
            0xC1 => blk: {
                self.setBc(self.pop());
                break :blk 12;
            },

            // JP NZ,nn
            0xC2 => self.jp(!self.getFlag(FLAG_Z)),

            // JP nn
            0xC3 => blk: {
                self.pc = self.readPc16();
                break :blk 16;
            },

            // CALL NZ,nn
            0xC4 => self.call(!self.getFlag(FLAG_Z)),

            // PUSH BC
            0xC5 => blk: {
                self.push(self.bc());
                break :blk 16;
            },

            // ADD A,n
            0xC6 => blk: {
                self.add(self.readPc(), false);
                break :blk 8;
            },

            // RST 00
            0xC7 => blk: {
                self.rst(0x00);
                break :blk 16;
            },

            // RET Z
            0xC8 => self.ret(self.getFlag(FLAG_Z)),

            // RET
            0xC9 => blk: {
                self.pc = self.pop();
                break :blk 16;
            },

            // JP Z,nn
            0xCA => self.jp(self.getFlag(FLAG_Z)),

            // CB prefix
            0xCB => self.executeCb(),

            // CALL Z,nn
            0xCC => self.call(self.getFlag(FLAG_Z)),

            // CALL nn
            0xCD => blk: {
                const addr = self.readPc16();
                self.push(self.pc);
                self.pc = addr;
                break :blk 24;
            },

            // ADC A,n
            0xCE => blk: {
                self.add(self.readPc(), true);
                break :blk 8;
            },

            // RST 08
            0xCF => blk: {
                self.rst(0x08);
                break :blk 16;
            },

            // RET NC
            0xD0 => self.ret(!self.getFlag(FLAG_C)),

            // POP DE
            0xD1 => blk: {
                self.setDe(self.pop());
                break :blk 12;
            },

            // JP NC,nn
            0xD2 => self.jp(!self.getFlag(FLAG_C)),

            // Invalid
            0xD3 => blk: {
                self.invalidOp(0xD3);
                break :blk 4;
            },

            // CALL NC,nn
            0xD4 => self.call(!self.getFlag(FLAG_C)),

            // PUSH DE
            0xD5 => blk: {
                self.push(self.de());
                break :blk 16;
            },

            // SUB A,n
            0xD6 => blk: {
                self.sub(self.readPc(), false);
                break :blk 8;
            },

            // RST 10
            0xD7 => blk: {
                self.rst(0x10);
                break :blk 16;
            },

            // RET C
            0xD8 => self.ret(self.getFlag(FLAG_C)),

            // RETI
            0xD9 => blk: {
                self.pc = self.pop();
                self.ime = true;
                break :blk 16;
            },

            // JP C,nn
            0xDA => self.jp(self.getFlag(FLAG_C)),

            // Invalid
            0xDB => blk: {
                self.invalidOp(0xDB);
                break :blk 4;
            },

            // CALL C,nn
            0xDC => self.call(self.getFlag(FLAG_C)),

            // Invalid
            0xDD => blk: {
                self.invalidOp(0xDD);
                break :blk 4;
            },

            // SBC A,n
            0xDE => blk: {
                self.sub(self.readPc(), true);
                break :blk 8;
            },

            // RST 18
            0xDF => blk: {
                self.rst(0x18);
                break :blk 16;
            },

            // LDH (n),A
            0xE0 => blk: {
                const offset = self.readPc();
                self.write(0xFF00 | @as(u16, offset), self.a);
                break :blk 12;
            },

            // POP HL
            0xE1 => blk: {
                self.setHl(self.pop());
                break :blk 12;
            },

            // LD (C),A
            0xE2 => blk: {
                self.write(0xFF00 | @as(u16, self.c), self.a);
                break :blk 8;
            },

            // Invalid
            0xE3 => blk: {
                self.invalidOp(0xE3);
                break :blk 4;
            },

            // Invalid
            0xE4 => blk: {
                self.invalidOp(0xE4);
                break :blk 4;
            },

            // PUSH HL
            0xE5 => blk: {
                self.push(self.hl());
                break :blk 16;
            },

            // AND A,n
            0xE6 => blk: {
                self.andA(self.readPc());
                break :blk 8;
            },

            // RST 20
            0xE7 => blk: {
                self.rst(0x20);
                break :blk 16;
            },

            // ADD SP,n
            0xE8 => blk: {
                const offset: i8 = @bitCast(self.readPc());
                const result = self.addSp(offset);
                self.sp = result;
                break :blk 16;
            },

            // JP HL
            0xE9 => blk: {
                self.pc = self.hl();
                break :blk 4;
            },

            // LD (nn),A
            0xEA => blk: {
                const addr = self.readPc16();
                self.write(addr, self.a);
                break :blk 16;
            },

            // Invalid
            0xEB => blk: {
                self.invalidOp(0xEB);
                break :blk 4;
            },

            // Invalid
            0xEC => blk: {
                self.invalidOp(0xEC);
                break :blk 4;
            },

            // Invalid
            0xED => blk: {
                self.invalidOp(0xED);
                break :blk 4;
            },

            // XOR A,n
            0xEE => blk: {
                self.xorA(self.readPc());
                break :blk 8;
            },

            // RST 28
            0xEF => blk: {
                self.rst(0x28);
                break :blk 16;
            },

            // LDH A,(n)
            0xF0 => blk: {
                const offset = self.readPc();
                self.a = self.read(0xFF00 | @as(u16, offset));
                break :blk 12;
            },

            // POP AF
            0xF1 => blk: {
                self.setAf(self.pop());
                break :blk 12;
            },

            // LD A,(C)
            0xF2 => blk: {
                self.a = self.read(0xFF00 | @as(u16, self.c));
                break :blk 8;
            },

            // DI
            0xF3 => blk: {
                self.ime = false;
                break :blk 4;
            },

            // Invalid
            0xF4 => blk: {
                self.invalidOp(0xF4);
                break :blk 4;
            },

            // PUSH AF
            0xF5 => blk: {
                self.push(self.af());
                break :blk 16;
            },

            // OR A,n
            0xF6 => blk: {
                self.orA(self.readPc());
                break :blk 8;
            },

            // RST 30
            0xF7 => blk: {
                self.rst(0x30);
                break :blk 16;
            },

            // LD HL,SP+n
            0xF8 => blk: {
                const offset: i8 = @bitCast(self.readPc());
                const result = self.addSp(offset);
                self.setHl(result);
                break :blk 12;
            },

            // LD SP,HL
            0xF9 => blk: {
                self.sp = self.hl();
                break :blk 8;
            },

            // LD A,(nn)
            0xFA => blk: {
                const addr = self.readPc16();
                self.a = self.read(addr);
                break :blk 16;
            },

            // EI
            0xFB => blk: {
                self.ime_scheduled = true;
                break :blk 4;
            },

            // Invalid
            0xFC => blk: {
                self.invalidOp(0xFC);
                break :blk 4;
            },

            // Invalid
            0xFD => blk: {
                self.invalidOp(0xFD);
                break :blk 4;
            },

            // CP A,n
            0xFE => blk: {
                self.cp(self.readPc());
                break :blk 8;
            },

            // RST 38
            0xFF => blk: {
                self.rst(0x38);
                break :blk 16;
            },
        };
    }

    fn executeCb(self: *Self) u32 {
        const opcode = self.readPc();
        const op = (opcode >> 6) & 0x03;
        const bit_num = (opcode >> 3) & 0x07;
        const reg = opcode & 0x07;

        // Get operand value
        var value = switch (reg) {
            0 => self.b,
            1 => self.c,
            2 => self.d,
            3 => self.e,
            4 => self.h,
            5 => self.l,
            6 => self.read(self.hl()),
            7 => self.a,
            else => unreachable,
        };

        const is_mem = reg == 6;
        var cycles: u32 = if (is_mem) 16 else 8;

        switch (op) {
            0 => {
                // Rotate/shift operations
                value = switch (bit_num) {
                    0 => self.rlc(value), // RLC
                    1 => self.rrc(value), // RRC
                    2 => self.rl(value), // RL
                    3 => self.rr(value), // RR
                    4 => self.sla(value), // SLA
                    5 => self.sra(value), // SRA
                    6 => self.swap(value), // SWAP
                    7 => self.srl(value), // SRL
                    else => unreachable,
                };
            },
            1 => {
                // BIT
                self.bit(bit_num, value);
                if (is_mem) cycles = 12;
                return cycles;
            },
            2 => {
                // RES
                value = value & ~(@as(u8, 1) << @intCast(bit_num));
            },
            3 => {
                // SET
                value = value | (@as(u8, 1) << @intCast(bit_num));
            },
            else => unreachable,
        }

        // Store result
        switch (reg) {
            0 => self.b = value,
            1 => self.c = value,
            2 => self.d = value,
            3 => self.e = value,
            4 => self.h = value,
            5 => self.l = value,
            6 => self.write(self.hl(), value),
            7 => self.a = value,
            else => unreachable,
        }

        return cycles;
    }

    // ALU operations
    fn inc(self: *Self, value: u8) u8 {
        const result = value +% 1;
        self.setFlags(result == 0, false, (value & 0x0F) == 0x0F, null);
        return result;
    }

    fn dec(self: *Self, value: u8) u8 {
        const result = value -% 1;
        self.setFlags(result == 0, true, (value & 0x0F) == 0, null);
        return result;
    }

    fn add(self: *Self, value: u8, with_carry: bool) void {
        const carry: u8 = if (with_carry and self.getFlag(FLAG_C)) 1 else 0;
        const result = @as(u16, self.a) + @as(u16, value) + @as(u16, carry);
        const half = (self.a & 0x0F) + (value & 0x0F) + carry;
        self.a = @truncate(result);
        self.setFlags(self.a == 0, false, half > 0x0F, result > 0xFF);
    }

    fn sub(self: *Self, value: u8, with_carry: bool) void {
        const carry: u8 = if (with_carry and self.getFlag(FLAG_C)) 1 else 0;
        const result = @as(i16, self.a) - @as(i16, value) - @as(i16, carry);
        const half = @as(i16, self.a & 0x0F) - @as(i16, value & 0x0F) - @as(i16, carry);
        self.a = @truncate(@as(u16, @bitCast(result)));
        self.setFlags(self.a == 0, true, half < 0, result < 0);
    }

    fn andA(self: *Self, value: u8) void {
        self.a &= value;
        self.setFlags(self.a == 0, false, true, false);
    }

    fn xorA(self: *Self, value: u8) void {
        self.a ^= value;
        self.setFlags(self.a == 0, false, false, false);
    }

    fn orA(self: *Self, value: u8) void {
        self.a |= value;
        self.setFlags(self.a == 0, false, false, false);
    }

    fn cp(self: *Self, value: u8) void {
        const result = @as(i16, self.a) - @as(i16, value);
        const half = @as(i16, self.a & 0x0F) - @as(i16, value & 0x0F);
        self.setFlags(self.a == value, true, half < 0, result < 0);
    }

    fn addHl(self: *Self, value: u16) void {
        const hl_val = self.hl();
        const result = @as(u32, hl_val) + @as(u32, value);
        const half = (hl_val & 0x0FFF) + (value & 0x0FFF);
        self.setHl(@truncate(result));
        self.setFlags(null, false, half > 0x0FFF, result > 0xFFFF);
    }

    fn addSp(self: *Self, offset: i8) u16 {
        const sp_signed: i32 = @intCast(self.sp);
        const result: u16 = @bitCast(@as(i16, @truncate(sp_signed + offset)));

        // Flags are set based on low byte addition
        const sp_lo: u8 = @truncate(self.sp);
        const off_u8: u8 = @bitCast(offset);
        const half = (sp_lo & 0x0F) + (off_u8 & 0x0F) > 0x0F;
        const carry = @as(u16, sp_lo) + @as(u16, off_u8) > 0xFF;

        self.setFlags(false, false, half, carry);
        return result;
    }

    // Rotate/shift operations
    fn rlc(self: *Self, value: u8) u8 {
        const carry = (value >> 7) & 1;
        const result = (value << 1) | carry;
        self.setFlags(result == 0, false, false, carry == 1);
        return result;
    }

    fn rrc(self: *Self, value: u8) u8 {
        const carry = value & 1;
        const result = (value >> 1) | (carry << 7);
        self.setFlags(result == 0, false, false, carry == 1);
        return result;
    }

    fn rl(self: *Self, value: u8) u8 {
        const old_carry: u8 = if (self.getFlag(FLAG_C)) 1 else 0;
        const new_carry = (value >> 7) & 1;
        const result = (value << 1) | old_carry;
        self.setFlags(result == 0, false, false, new_carry == 1);
        return result;
    }

    fn rr(self: *Self, value: u8) u8 {
        const old_carry: u8 = if (self.getFlag(FLAG_C)) 0x80 else 0;
        const new_carry = value & 1;
        const result = (value >> 1) | old_carry;
        self.setFlags(result == 0, false, false, new_carry == 1);
        return result;
    }

    fn sla(self: *Self, value: u8) u8 {
        const carry = (value >> 7) & 1;
        const result = value << 1;
        self.setFlags(result == 0, false, false, carry == 1);
        return result;
    }

    fn sra(self: *Self, value: u8) u8 {
        const carry = value & 1;
        const result = (value >> 1) | (value & 0x80);
        self.setFlags(result == 0, false, false, carry == 1);
        return result;
    }

    fn srl(self: *Self, value: u8) u8 {
        const carry = value & 1;
        const result = value >> 1;
        self.setFlags(result == 0, false, false, carry == 1);
        return result;
    }

    fn swap(self: *Self, value: u8) u8 {
        const result = ((value & 0x0F) << 4) | ((value & 0xF0) >> 4);
        self.setFlags(result == 0, false, false, false);
        return result;
    }

    fn bit(self: *Self, b: u8, value: u8) void {
        const mask = @as(u8, 1) << @intCast(b);
        self.setFlags((value & mask) == 0, false, true, null);
    }

    // DAA - Decimal Adjust Accumulator
    fn daa(self: *Self) void {
        var adjust: u8 = 0;
        var carry = false;

        if (self.getFlag(FLAG_N)) {
            // After subtraction
            if (self.getFlag(FLAG_C)) {
                adjust = 0x60;
                carry = true;
            }
            if (self.getFlag(FLAG_H)) {
                adjust |= 0x06;
            }
            self.a -%= adjust;
        } else {
            // After addition
            if (self.getFlag(FLAG_C) or self.a > 0x99) {
                adjust = 0x60;
                carry = true;
            }
            if (self.getFlag(FLAG_H) or (self.a & 0x0F) > 0x09) {
                adjust |= 0x06;
            }
            self.a +%= adjust;
        }

        self.setFlags(self.a == 0, null, false, carry);
    }

    // Jump/call helpers
    fn jr(self: *Self, condition: bool) u32 {
        const offset: i8 = @bitCast(self.readPc());
        if (condition) {
            const pc_i32: i32 = @intCast(self.pc);
            const new_pc: i32 = pc_i32 +% offset;
            self.pc = @intCast(@as(u32, @bitCast(new_pc)) & 0xFFFF);
            return 12;
        }
        return 8;
    }

    fn jp(self: *Self, condition: bool) u32 {
        const addr = self.readPc16();
        if (condition) {
            self.pc = addr;
            return 16;
        }
        return 12;
    }

    fn call(self: *Self, condition: bool) u32 {
        const addr = self.readPc16();
        if (condition) {
            self.push(self.pc);
            self.pc = addr;
            return 24;
        }
        return 12;
    }

    fn ret(self: *Self, condition: bool) u32 {
        if (condition) {
            self.pc = self.pop();
            return 20;
        }
        return 8;
    }

    fn rst(self: *Self, addr: u16) void {
        self.push(self.pc);
        self.pc = addr;
    }

    fn invalidOp(self: *Self, opcode: u8) void {
        _ = opcode;
        // Invalid opcodes lock up the CPU
        self.stopped = true;
    }
};

test "cpu initialization" {
    var bus = Bus.init();
    var cpu = Cpu.init(&bus);
    try std.testing.expectEqual(@as(u16, 0x0100), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x01), cpu.a);
}

test "cpu inc/dec" {
    var bus = Bus.init();
    var cpu = Cpu.init(&bus);

    cpu.b = 0x00;
    cpu.b = cpu.inc(cpu.b);
    try std.testing.expectEqual(@as(u8, 0x01), cpu.b);
    try std.testing.expect(!cpu.getFlag(Cpu.FLAG_Z));

    cpu.b = 0xFF;
    cpu.b = cpu.inc(cpu.b);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.b);
    try std.testing.expect(cpu.getFlag(Cpu.FLAG_Z));
}

test "cpu add" {
    var bus = Bus.init();
    var cpu = Cpu.init(&bus);

    cpu.a = 0x10;
    cpu.add(0x20, false);
    try std.testing.expectEqual(@as(u8, 0x30), cpu.a);
    try std.testing.expect(!cpu.getFlag(Cpu.FLAG_C));

    cpu.a = 0xFF;
    cpu.add(0x01, false);
    try std.testing.expectEqual(@as(u8, 0x00), cpu.a);
    try std.testing.expect(cpu.getFlag(Cpu.FLAG_Z));
    try std.testing.expect(cpu.getFlag(Cpu.FLAG_C));
}
