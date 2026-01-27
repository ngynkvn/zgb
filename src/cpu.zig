const std = @import("std");

const Bus = @import("bus.zig").Bus;
const Interrupt = @import("bus.zig").Interrupt;

/// SM83 CPU (Sharp LR35902)
/// A modified Z80 used in the GameBoy
pub const Cpu = struct {
    // 8-bit registers
    af: u16 = 0,
    bc: u16 = 0,
    de: u16 = 0,
    hl: u16 = 0,

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
        cpu.af = 0x01B0;
        cpu.bc = 0x0013;
        cpu.de = 0x00D8;
        cpu.hl = 0x014D;
        cpu.sp = 0xFFFE;
        cpu.pc = 0x0100; // Entry point after boot ROM
        return cpu;
    }

    // Register enums
    // Standard 8-bit register encoding in opcodes (3 bits)
    pub const Register8 = enum { b, c, d, e, h, l, hl_ind, a };
    pub const Register16 = enum(u2) { bc, de, hl, sp };
    pub const Register16Stack = enum(u2) { bc, de, hl, af }; // For PUSH/POP

    // Extended register enum that includes F (for internal use)
    pub const Reg8 = enum { a, f, b, c, d, e, h, l };

    pub const PtrType = union(enum) {
        r8: Reg8,
        r16: Register16,
        r16stk: Register16Stack,

        pub fn Ptr(comptime self: PtrType) type {
            return switch (self) {
                .r8 => *u8,
                .r16, .r16stk => *u16,
            };
        }
    };

    pub inline fn ptr(self: *Self, comptime reg: PtrType) reg.Ptr() {
        return switch (reg) {
            .r8 => |r| self.r8(r),
            .r16 => |r| self.r16(r),
            .r16stk => |r| self.r16stk(r),
        };
    }

    /// Get pointer to 8-bit register (little-endian: high byte at index 1)
    pub inline fn r8(self: *Self, comptime reg: Reg8) *u8 {
        return switch (reg) {
            .a => &std.mem.asBytes(&self.af)[1],
            .f => &std.mem.asBytes(&self.af)[0],
            .b => &std.mem.asBytes(&self.bc)[1],
            .c => &std.mem.asBytes(&self.bc)[0],
            .d => &std.mem.asBytes(&self.de)[1],
            .e => &std.mem.asBytes(&self.de)[0],
            .h => &std.mem.asBytes(&self.hl)[1],
            .l => &std.mem.asBytes(&self.hl)[0],
        };
    }

    /// Get pointer to 16-bit register pair
    pub inline fn r16(self: *Self, reg: Register16) *u16 {
        return switch (reg) {
            .bc => &self.bc,
            .de => &self.de,
            .hl => &self.hl,
            .sp => &self.sp,
        };
    }

    /// Get pointer to 16-bit register pair (stack variant: AF instead of SP)
    pub inline fn r16stk(self: *Self, reg: Register16Stack) *u16 {
        return switch (reg) {
            .bc => &self.bc,
            .de => &self.de,
            .hl => &self.hl,
            .af => &self.af,
        };
    }

    // Maps 3-bit register field in opcodes to Reg8 (null = (HL) indirect)
    const REG_DECODE: [8]?Reg8 = .{ .b, .c, .d, .e, .h, .l, null, .a };

    /// Read from register or (HL) based on 3-bit opcode field
    inline fn readR8Idx(self: *Self, idx: u3) u8 {
        return switch (idx) {
            6 => self.read(self.hl),
            inline else => |i| self.r8(REG_DECODE[i].?).*,
        };
    }

    /// Write to register or (HL) based on 3-bit opcode field
    inline fn writeR8Idx(self: *Self, idx: u3, value: u8) void {
        switch (idx) {
            6 => self.write(self.hl, value),
            inline else => |i| self.r8(REG_DECODE[i].?).* = value,
        }
    }

    /// Dispatch ALU operation by 3-bit op field
    inline fn aluDispatch(self: *Self, op: u3, val: u8) void {
        switch (op) {
            0 => self.add(val, false), // ADD
            1 => self.add(val, true), // ADC
            2 => self.sub(val, false), // SUB
            3 => self.sub(val, true), // SBC
            4 => self.andA(val),
            5 => self.xorA(val),
            6 => self.orA(val),
            7 => self.cp(val),
        }
    }

    // Flag helpers
    fn getFlag(self: *Self, flag: u8) bool {
        return (self.r8(.f).* & flag) != 0;
    }

    fn setFlag(self: *Self, flag: u8, value: bool) void {
        if (value) {
            self.r8(.f).* |= flag;
        } else {
            self.r8(.f).* &= ~flag;
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

            // LD r16,nn (BC, DE, HL, SP)
            // Pattern: 00_pp_0001
            0x01, 0x11, 0x21, 0x31 => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                self.r16(@enumFromInt(rp)).* = self.readPc16();
                return 12;
            },

            // LD (BC),A
            0x02 => {
                self.write(self.bc, self.r8(.a).*);
                return 8;
            },

            // INC r16 (BC, DE, HL, SP)
            // Pattern: 00_pp_0011
            0x03, 0x13, 0x23, 0x33 => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                self.r16(@enumFromInt(rp)).* +%= 1;
                return 8;
            },

            // INC B
            0x04 => {
                const b = self.r8(.b);
                b.* = self.inc(b.*);
                return 4;
            },

            // DEC B
            0x05 => {
                const b = self.r8(.b);
                b.* = self.dec(b.*);
                return 4;
            },

            // LD B,n
            0x06 => {
                const b = self.r8(.b);
                b.* = self.readPc();
                return 8;
            },

            // RLCA
            0x07 => {
                const a = self.r8(.a);
                const v, const overflow = @shlWithOverflow(a.*, 1);
                a.* = (v << 1) | overflow;
                self.setFlags(false, false, false, overflow == 1);
                return 4;
            },

            // LD (nn),SP
            0x08 => {
                const addr = self.readPc16();
                self.write(addr, @truncate(self.sp));
                self.write(addr +% 1, @truncate(self.sp >> 8));
                return 20;
            },

            // ADD HL,r16 (BC, DE, HL, SP)
            // Pattern: 00_pp_1001
            0x09, 0x19, 0x29, 0x39 => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                self.addHl(self.r16(@enumFromInt(rp)).*);
                return 8;
            },

            // LD A,(BC)
            0x0A => {
                self.r8(.a).* = self.read(self.bc);
                return 8;
            },

            // DEC r16 (BC, DE, HL, SP)
            // Pattern: 00_pp_1011
            0x0B, 0x1B, 0x2B, 0x3B => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                self.r16(@enumFromInt(rp)).* -%= 1;
                return 8;
            },

            // INC C
            0x0C => {
                const c = self.r8(.c);
                c.* = self.inc(c.*);
                return 4;
            },

            // DEC C
            0x0D => {
                const c = self.r8(.c);
                c.* = self.dec(c.*);
                return 4;
            },

            // LD C,n
            0x0E => {
                const c = self.r8(.c);
                c.* = self.readPc();
                return 8;
            },

            // RRCA
            0x0F => {
                const a = self.r8(.a);
                const carry = a.* & 1;
                a.* = (a.* >> 1) | (carry << 7);
                self.setFlags(false, false, false, carry == 1);
                return 4;
            },

            // STOP
            0x10 => {
                _ = self.readPc(); // Skip byte after STOP
                self.stopped = true;
                return 4;
            },

            // LD (DE),A
            0x12 => {
                self.write(self.de, self.r8(.a).*);
                return 8;
            },

            // INC D
            0x14 => {
                const d = self.r8(.d);
                d.* = self.inc(d.*);
                return 4;
            },

            // DEC D
            0x15 => {
                const d = self.r8(.d);
                d.* = self.dec(d.*);
                return 4;
            },

            // LD D,n
            0x16 => {
                const d = self.r8(.d);
                d.* = self.readPc();
                return 8;
            },

            // RLA
            0x17 => {
                const old_carry: u8 = if (self.getFlag(FLAG_C)) 1 else 0;
                const a = self.r8(.a);
                const new_carry = (a.* >> 7) & 1;
                a.* = (a.* << 1) | old_carry;
                self.setFlags(false, false, false, new_carry == 1);
                return 4;
            },

            // JR n
            0x18 => {
                const offset: i8 = @bitCast(self.readPc());
                const pc_i32: i32 = @intCast(self.pc);
                const new_pc: i32 = pc_i32 +% offset;
                self.pc = @intCast(@as(u32, @bitCast(new_pc)) & 0xFFFF);
                return 12;
            },

            // LD A,(DE)
            0x1A => {
                self.r8(.a).* = self.read(self.de);
                return 8;
            },

            // INC E
            0x1C => {
                const e = self.r8(.e);
                e.* = self.inc(e.*);
                return 4;
            },

            // DEC E
            0x1D => {
                const e = self.r8(.e);
                e.* = self.dec(e.*);
                return 4;
            },

            // LD E,n
            0x1E => {
                const e = self.r8(.e);
                e.* = self.readPc();
                return 8;
            },

            // RRA
            0x1F => {
                const old_carry: u8 = if (self.getFlag(FLAG_C)) 0x80 else 0;
                const a = self.r8(.a);
                const new_carry = a.* & 1;
                a.* = (a.* >> 1) | old_carry;
                self.setFlags(false, false, false, new_carry == 1);
                return 4;
            },

            // JR NZ,n
            0x20 => self.jr(!self.getFlag(FLAG_Z)),

            // LD (HL+),A
            0x22 => {
                self.write(self.hl, self.r8(.a).*);
                self.hl = self.hl +% 1;
                return 8;
            },

            // INC H
            0x24 => {
                const h = self.r8(.h);
                h.* = self.inc(h.*);
                return 4;
            },

            // DEC H
            0x25 => {
                const h = self.r8(.h);
                h.* = self.dec(h.*);
                return 4;
            },

            // LD H,n
            0x26 => {
                const h = self.r8(.h);
                h.* = self.readPc();
                return 8;
            },

            // DAA
            0x27 => {
                self.daa();
                return 4;
            },

            // JR Z,n
            0x28 => self.jr(self.getFlag(FLAG_Z)),

            // LD A,(HL+)
            0x2A => {
                self.r8(.a).* = self.read(self.hl);
                self.hl +%= 1;
                return 8;
            },

            // INC L
            0x2C => {
                const l = self.r8(.l);
                l.* = self.inc(l.*);
                return 4;
            },

            // DEC L
            0x2D => {
                const l = self.r8(.l);
                l.* = self.dec(l.*);
                return 4;
            },

            // LD L,n
            0x2E => {
                self.r8(.l).* = self.readPc();
                return 8;
            },

            // CPL
            0x2F => {
                self.r8(.a).* = ~self.r8(.a).*;
                self.setFlags(null, true, true, null);
                return 4;
            },

            // JR NC,n
            0x30 => self.jr(!self.getFlag(FLAG_C)),

            // LD (HL-),A
            0x32 => {
                self.write(self.hl, self.r8(.a).*);
                self.hl = self.hl -% 1;
                return 8;
            },

            // INC (HL)
            0x34 => {
                const value = self.inc(self.read(self.hl));
                self.write(self.hl, value);
                return 12;
            },

            // DEC (HL)
            0x35 => {
                const value = self.dec(self.read(self.hl));
                self.write(self.hl, value);
                return 12;
            },

            // LD (HL),n
            0x36 => {
                self.write(self.hl, self.readPc());
                return 12;
            },

            // SCF
            0x37 => {
                self.setFlags(null, false, false, true);
                return 4;
            },

            // JR C,n
            0x38 => self.jr(self.getFlag(FLAG_C)),

            // LD A,(HL-)
            0x3A => {
                self.r8(.a).* = self.read(self.hl);
                self.hl -%= 1;
                return 8;
            },

            // INC A
            0x3C => {
                self.r8(.a).* = self.inc(self.r8(.a).*);
                return 4;
            },

            // DEC A
            0x3D => {
                self.r8(.a).* = self.dec(self.r8(.a).*);
                return 4;
            },

            // LD A,n
            0x3E => {
                self.r8(.a).* = self.readPc();
                return 8;
            },

            // CCF
            0x3F => {
                self.setFlags(null, false, false, !self.getFlag(FLAG_C));
                return 4;
            },

            // LD r,r' block (0x40-0x7F) - except 0x76 (HALT)
            // Opcode encodes: dst in bits 5-3, src in bits 2-0
            0x40...0x75, 0x77...0x7F => {
                const dst: u3 = @truncate((opcode >> 3) & 0x07);
                const src: u3 = @truncate(opcode & 0x07);
                const val = self.readR8Idx(src);
                self.writeR8Idx(dst, val);
                return if (src == 6 or dst == 6) 8 else 4;
            },

            // HALT
            0x76 => {
                self.halted = true;
                return 4;
            },

            // ALU A,r block (0x80-0xBF)
            // Opcode encodes: op in bits 5-3, src in bits 2-0
            0x80...0xBF => {
                const alu_op: u3 = @truncate((opcode >> 3) & 0x07);
                const src: u3 = @truncate(opcode & 0x07);
                const val = self.readR8Idx(src);
                self.aluDispatch(alu_op, val);
                return if (src == 6) 8 else 4;
            },

            // RET NZ
            0xC0 => self.ret(!self.getFlag(FLAG_Z)),

            // POP r16 (BC, DE, HL, AF)
            // Pattern: 11_pp_0001
            0xC1, 0xD1, 0xE1, 0xF1 => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                const reg = self.r16stk(@enumFromInt(rp));
                reg.* = self.pop();
                // Special case: AF lower nibble is always 0
                if (rp == 3) self.af &= 0xFFF0;
                return 12;
            },

            // JP NZ,nn
            0xC2 => self.jp(!self.getFlag(FLAG_Z)),

            // JP nn
            0xC3 => {
                self.pc = self.readPc16();
                return 16;
            },

            // CALL NZ,nn
            0xC4 => self.call(!self.getFlag(FLAG_Z)),

            // PUSH r16 (BC, DE, HL, AF)
            // Pattern: 11_pp_0101
            0xC5, 0xD5, 0xE5, 0xF5 => {
                const rp: u2 = @truncate((opcode >> 4) & 0x03);
                self.push(self.r16stk(@enumFromInt(rp)).*);
                return 16;
            },

            // ALU A,n immediate (ADD, ADC, SUB, SBC, AND, XOR, OR, CP)
            // Pattern: 11_xxx_110 where xxx = ALU operation
            0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE => {
                const alu_op: u3 = @truncate((opcode >> 3) & 0x07);
                self.aluDispatch(alu_op, self.readPc());
                return 8;
            },

            // RST n (00, 08, 10, 18, 20, 28, 30, 38)
            // Pattern: 11_xxx_111 where address = xxx * 8
            0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF => {
                self.rst(opcode & 0x38);
                return 16;
            },

            // RET Z
            0xC8 => self.ret(self.getFlag(FLAG_Z)),

            // RET
            0xC9 => {
                self.pc = self.pop();
                return 16;
            },

            // JP Z,nn
            0xCA => self.jp(self.getFlag(FLAG_Z)),

            // CB prefix
            0xCB => self.executeCb(),

            // CALL Z,nn
            0xCC => self.call(self.getFlag(FLAG_Z)),

            // CALL nn
            0xCD => {
                const addr = self.readPc16();
                self.push(self.pc);
                self.pc = addr;
                return 24;
            },

            // RET NC
            0xD0 => self.ret(!self.getFlag(FLAG_C)),

            // JP NC,nn
            0xD2 => self.jp(!self.getFlag(FLAG_C)),

            // Invalid
            0xD3 => {
                self.invalidOp(0xD3);
                return 4;
            },

            // CALL NC,nn
            0xD4 => self.call(!self.getFlag(FLAG_C)),

            // RET C
            0xD8 => self.ret(self.getFlag(FLAG_C)),

            // RETI
            0xD9 => {
                self.pc = self.pop();
                self.ime = true;
                return 16;
            },

            // JP C,nn
            0xDA => self.jp(self.getFlag(FLAG_C)),

            // Invalid
            0xDB => {
                self.invalidOp(0xDB);
                return 4;
            },

            // CALL C,nn
            0xDC => self.call(self.getFlag(FLAG_C)),

            // Invalid
            0xDD => {
                self.invalidOp(0xDD);
                return 4;
            },

            // LDH (n),A
            0xE0 => {
                const offset = self.readPc();
                self.write(0xFF00 | @as(u16, offset), self.r8(.a).*);
                return 12;
            },

            // LD (C),A
            0xE2 => {
                self.write(0xFF00 | @as(u16, self.r8(.c).*), self.r8(.a).*);
                return 8;
            },

            // Invalid
            0xE3 => {
                self.invalidOp(0xE3);
                return 4;
            },

            // Invalid
            0xE4 => {
                self.invalidOp(0xE4);
                return 4;
            },

            // ADD SP,n
            0xE8 => {
                const offset: i8 = @bitCast(self.readPc());
                const result = self.addSp(offset);
                self.sp = result;
                return 16;
            },

            // JP HL
            0xE9 => {
                self.pc = self.hl;
                return 4;
            },

            // LD (nn),A
            0xEA => {
                const addr = self.readPc16();
                self.write(addr, self.r8(.a).*);
                return 16;
            },

            // Invalid
            0xEB => {
                self.invalidOp(0xEB);
                return 4;
            },

            // Invalid
            0xEC => {
                self.invalidOp(0xEC);
                return 4;
            },

            // Invalid
            0xED => {
                self.invalidOp(0xED);
                return 4;
            },

            // LDH A,(n)
            0xF0 => {
                const offset = self.readPc();
                self.r8(.a).* = self.read(0xFF00 | @as(u16, offset));
                return 12;
            },

            // LD A,(C)
            0xF2 => {
                self.r8(.a).* = self.read(0xFF00 | @as(u16, self.r8(.c).*));
                return 8;
            },

            // DI
            0xF3 => {
                self.ime = false;
                return 4;
            },

            // Invalid
            0xF4 => {
                self.invalidOp(0xF4);
                return 4;
            },

            // LD HL,SP+n
            0xF8 => {
                const offset: i8 = @bitCast(self.readPc());
                const result = self.addSp(offset);
                self.hl = result;
                return 12;
            },

            // LD SP,HL
            0xF9 => {
                self.sp = self.hl;
                return 8;
            },

            // LD A,(nn)
            0xFA => {
                const addr = self.readPc16();
                self.r8(.a).* = self.read(addr);
                return 16;
            },

            // EI
            0xFB => {
                self.ime_scheduled = true;
                return 4;
            },

            // Invalid
            0xFC => {
                self.invalidOp(0xFC);
                return 4;
            },

            // Invalid
            0xFD => {
                self.invalidOp(0xFD);
                return 4;
            },
        };
    }

    fn executeCb(self: *Self) u32 {
        const opcode = self.readPc();
        const op: u2 = @truncate((opcode >> 6) & 0x03);
        const bit_num: u3 = @truncate((opcode >> 3) & 0x07);
        const reg: u3 = @truncate(opcode & 0x07);

        var value = self.readR8Idx(reg);
        const is_mem = reg == 6;

        switch (op) {
            0 => {
                // Rotate/shift operations
                value = switch (bit_num) {
                    0 => self.rlc(value),
                    1 => self.rrc(value),
                    2 => self.rl(value),
                    3 => self.rr(value),
                    4 => self.sla(value),
                    5 => self.sra(value),
                    6 => self.swap(value),
                    7 => self.srl(value),
                };
                self.writeR8Idx(reg, value);
                return if (is_mem) 16 else 8;
            },
            1 => {
                // BIT - doesn't modify value
                self.bit(bit_num, value);
                return if (is_mem) 12 else 8;
            },
            2 => {
                // RES
                value = value & ~(@as(u8, 1) << bit_num);
                self.writeR8Idx(reg, value);
                return if (is_mem) 16 else 8;
            },
            3 => {
                // SET
                value = value | (@as(u8, 1) << bit_num);
                self.writeR8Idx(reg, value);
                return if (is_mem) 16 else 8;
            },
        }
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
        const a = self.r8(.a);
        const carry: u8 = if (with_carry and self.getFlag(FLAG_C)) 1 else 0;
        const result = @as(u16, a.*) + @as(u16, value) + @as(u16, carry);
        const half = (a.* & 0x0F) + (value & 0x0F) + carry;
        a.* = @truncate(result);
        self.setFlags(a.* == 0, false, half > 0x0F, result > 0xFF);
    }

    fn sub(self: *Self, value: u8, with_carry: bool) void {
        const a = self.r8(.a);
        const carry: u8 = if (with_carry and self.getFlag(FLAG_C)) 1 else 0;
        const result = @as(i16, a.*) - @as(i16, value) - @as(i16, carry);
        const half = @as(i16, a.* & 0x0F) - @as(i16, value & 0x0F) - @as(i16, carry);
        a.* = @truncate(@as(u16, @bitCast(result)));
        self.setFlags(a.* == 0, true, half < 0, result < 0);
    }

    fn andA(self: *Self, value: u8) void {
        const a = self.r8(.a);
        a.* &= value;
        self.setFlags(a.* == 0, false, true, false);
    }

    fn xorA(self: *Self, value: u8) void {
        const a = self.r8(.a);
        a.* ^= value;
        self.setFlags(a.* == 0, false, false, false);
    }

    fn orA(self: *Self, value: u8) void {
        const a = self.r8(.a);
        a.* |= value;
        self.setFlags(a.* == 0, false, false, false);
    }

    fn cp(self: *Self, value: u8) void {
        const a = self.r8(.a);
        const result = @as(i16, a.*) - @as(i16, value);
        const half = @as(i16, a.* & 0x0F) - @as(i16, value & 0x0F);
        self.setFlags(a.* == value, true, half < 0, result < 0);
    }

    fn addHl(self: *Self, value: u16) void {
        const hl_val = self.hl;
        const result = @as(u32, hl_val) + @as(u32, value);
        const half = (hl_val & 0x0FFF) + (value & 0x0FFF);
        self.hl = @truncate(result);
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
        const a = self.r8(.a);

        if (self.getFlag(FLAG_N)) {
            // After subtraction
            if (self.getFlag(FLAG_C)) {
                adjust = 0x60;
                carry = true;
            }
            if (self.getFlag(FLAG_H)) {
                adjust |= 0x06;
            }
            a.* -%= adjust;
        } else {
            // After addition
            if (self.getFlag(FLAG_C) or a.* > 0x99) {
                adjust = 0x60;
                carry = true;
            }
            if (self.getFlag(FLAG_H) or (a.* & 0x0F) > 0x09) {
                adjust |= 0x06;
            }
            a.* +%= adjust;
        }

        self.setFlags(a.* == 0, null, false, carry);
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

// test "cpu initialization" {
//     var bus = Bus.init();
//     var cpu = Cpu.init(&bus);
//     try std.testing.expectEqual(@as(u16, 0x0100), cpu.pc);
//     try std.testing.expectEqual(@as(u8, 0x01), cpu.a);
// }

// test "cpu inc/dec" {
//     var bus = Bus.init();
//     var cpu = Cpu.init(&bus);

//     cpu.bc = 0x0013;
//     const b = cpu.r16(.bc);
//     // const b_inc = cpu.inc(b);
//     try std.testing.expectEqual(@as(u8, 0x01), cpu.b);
//     try std.testing.expect(!cpu.getFlag(Cpu.FLAG_Z));

//     cpu.b = 0xFF;
//     cpu.b = cpu.inc(cpu.b);
//     try std.testing.expectEqual(@as(u8, 0x00), cpu.b);
//     try std.testing.expect(cpu.getFlag(Cpu.FLAG_Z));
// }

// test "cpu add" {
//     var bus = Bus.init();
//     var cpu = Cpu.init(&bus);

//     cpu.a = 0x10;
//     cpu.add(0x20, false);
//     try std.testing.expectEqual(@as(u8, 0x30), cpu.a);
//     try std.testing.expect(!cpu.getFlag(Cpu.FLAG_C));

//     cpu.a = 0xFF;
//     cpu.add(0x01, false);
//     try std.testing.expectEqual(@as(u8, 0x00), cpu.a);
//     try std.testing.expect(cpu.getFlag(Cpu.FLAG_Z));
//     try std.testing.expect(cpu.getFlag(Cpu.FLAG_C));
// }
