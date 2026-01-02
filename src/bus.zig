const std = @import("std");
const Cartridge = @import("cartridge.zig").Cartridge;
const Ppu = @import("ppu.zig").Ppu;
const Timer = @import("timer.zig").Timer;
const Joypad = @import("joypad.zig").Joypad;

/// GameBoy Memory Bus
/// Handles all memory mapping and I/O register access
pub const Bus = struct {
    // Memory regions
    vram: [0x2000]u8 = undefined, // 8KB Video RAM (0x8000-0x9FFF)
    wram: [0x2000]u8 = undefined, // 8KB Work RAM (0xC000-0xDFFF)
    oam: [0xA0]u8 = undefined, // Object Attribute Memory (0xFE00-0xFE9F)
    io: [0x80]u8 = undefined, // I/O Registers (0xFF00-0xFF7F)
    hram: [0x7F]u8 = undefined, // High RAM (0xFF80-0xFFFE)
    ie: u8 = 0, // Interrupt Enable (0xFFFF)

    // Components
    cartridge: ?*Cartridge = null,
    ppu: ?*Ppu = null,
    timer: ?*Timer = null,
    joypad: ?*Joypad = null,

    // DMA state
    dma_active: bool = false,
    dma_byte: u8 = 0,
    dma_value: u8 = 0,
    dma_delay: u8 = 0,

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        @memset(&self.vram, 0);
        @memset(&self.wram, 0);
        @memset(&self.oam, 0);
        @memset(&self.io, 0);
        @memset(&self.hram, 0);

        // Initialize I/O registers to boot values (post-boot ROM)
        self.io[0x00] = 0xCF; // JOYP
        self.io[0x01] = 0x00; // SB
        self.io[0x02] = 0x7E; // SC
        self.io[0x04] = 0xAB; // DIV
        self.io[0x05] = 0x00; // TIMA
        self.io[0x06] = 0x00; // TMA
        self.io[0x07] = 0xF8; // TAC
        self.io[0x0F] = 0xE1; // IF
        self.io[0x10] = 0x80; // NR10
        self.io[0x11] = 0xBF; // NR11
        self.io[0x12] = 0xF3; // NR12
        self.io[0x13] = 0xFF; // NR13
        self.io[0x14] = 0xBF; // NR14
        self.io[0x16] = 0x3F; // NR21
        self.io[0x17] = 0x00; // NR22
        self.io[0x18] = 0xFF; // NR23
        self.io[0x19] = 0xBF; // NR24
        self.io[0x1A] = 0x7F; // NR30
        self.io[0x1B] = 0xFF; // NR31
        self.io[0x1C] = 0x9F; // NR32
        self.io[0x1D] = 0xFF; // NR33
        self.io[0x1E] = 0xBF; // NR34
        self.io[0x20] = 0xFF; // NR41
        self.io[0x21] = 0x00; // NR42
        self.io[0x22] = 0x00; // NR43
        self.io[0x23] = 0xBF; // NR44
        self.io[0x24] = 0x77; // NR50
        self.io[0x25] = 0xF3; // NR51
        self.io[0x26] = 0xF1; // NR52
        self.io[0x40] = 0x91; // LCDC
        self.io[0x41] = 0x85; // STAT
        self.io[0x42] = 0x00; // SCY
        self.io[0x43] = 0x00; // SCX
        self.io[0x44] = 0x00; // LY
        self.io[0x45] = 0x00; // LYC
        self.io[0x46] = 0xFF; // DMA
        self.io[0x47] = 0xFC; // BGP
        self.io[0x48] = 0x00; // OBP0 (on CGB: 0xFF)
        self.io[0x49] = 0x00; // OBP1 (on CGB: 0xFF)
        self.io[0x4A] = 0x00; // WY
        self.io[0x4B] = 0x00; // WX

        self.ie = 0x00;

        return self;
    }

    pub fn read(self: *Self, addr: u16) u8 {
        return switch (addr) {
            // ROM Bank 0 (0x0000-0x3FFF)
            0x0000...0x3FFF => if (self.cartridge) |cart| cart.read(addr) else 0xFF,

            // ROM Bank N (0x4000-0x7FFF)
            0x4000...0x7FFF => if (self.cartridge) |cart| cart.read(addr) else 0xFF,

            // VRAM (0x8000-0x9FFF)
            0x8000...0x9FFF => self.vram[addr - 0x8000],

            // External RAM (0xA000-0xBFFF)
            0xA000...0xBFFF => if (self.cartridge) |cart| cart.read(addr) else 0xFF,

            // Work RAM (0xC000-0xDFFF)
            0xC000...0xDFFF => self.wram[addr - 0xC000],

            // Echo RAM (0xE000-0xFDFF) - mirrors 0xC000-0xDDFF
            0xE000...0xFDFF => self.wram[addr - 0xE000],

            // OAM (0xFE00-0xFE9F)
            0xFE00...0xFE9F => self.oam[addr - 0xFE00],

            // Unusable (0xFEA0-0xFEFF)
            0xFEA0...0xFEFF => 0xFF,

            // I/O Registers (0xFF00-0xFF7F)
            0xFF00...0xFF7F => self.readIO(addr),

            // High RAM (0xFF80-0xFFFE)
            0xFF80...0xFFFE => self.hram[addr - 0xFF80],

            // Interrupt Enable (0xFFFF)
            0xFFFF => self.ie,
        };
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        switch (addr) {
            // ROM - writes go to MBC
            0x0000...0x7FFF => if (self.cartridge) |cart| cart.write(addr, value),

            // VRAM
            0x8000...0x9FFF => self.vram[addr - 0x8000] = value,

            // External RAM
            0xA000...0xBFFF => if (self.cartridge) |cart| cart.write(addr, value),

            // Work RAM
            0xC000...0xDFFF => self.wram[addr - 0xC000] = value,

            // Echo RAM
            0xE000...0xFDFF => self.wram[addr - 0xE000] = value,

            // OAM
            0xFE00...0xFE9F => self.oam[addr - 0xFE00] = value,

            // Unusable
            0xFEA0...0xFEFF => {},

            // I/O Registers
            0xFF00...0xFF7F => self.writeIO(addr, value),

            // High RAM
            0xFF80...0xFFFE => self.hram[addr - 0xFF80] = value,

            // Interrupt Enable
            0xFFFF => self.ie = value,
        }
    }

    fn readIO(self: *Self, addr: u16) u8 {
        const reg = addr & 0x7F;
        return switch (reg) {
            // Joypad
            0x00 => if (self.joypad) |j| j.read() else 0xFF,

            // Serial (stub)
            0x01 => self.io[0x01],
            0x02 => self.io[0x02],

            // Timer
            0x04 => if (self.timer) |t| t.readDiv() else self.io[0x04],
            0x05 => if (self.timer) |t| t.readTima() else self.io[0x05],
            0x06 => if (self.timer) |t| t.readTma() else self.io[0x06],
            0x07 => if (self.timer) |t| t.readTac() else self.io[0x07],

            // Interrupt Flag
            0x0F => self.io[0x0F],

            // Audio (stubs - not implemented)
            0x10...0x3F => self.io[reg],

            // PPU registers
            0x40 => if (self.ppu) |p| p.readLcdc() else self.io[0x40],
            0x41 => if (self.ppu) |p| p.readStat() else self.io[0x41],
            0x42 => if (self.ppu) |p| p.scy else self.io[0x42],
            0x43 => if (self.ppu) |p| p.scx else self.io[0x43],
            0x44 => if (self.ppu) |p| p.ly else self.io[0x44],
            0x45 => if (self.ppu) |p| p.lyc else self.io[0x45],
            0x46 => self.io[0x46], // DMA
            0x47 => if (self.ppu) |p| p.bgp else self.io[0x47],
            0x48 => if (self.ppu) |p| p.obp0 else self.io[0x48],
            0x49 => if (self.ppu) |p| p.obp1 else self.io[0x49],
            0x4A => if (self.ppu) |p| p.wy else self.io[0x4A],
            0x4B => if (self.ppu) |p| p.wx else self.io[0x4B],

            // Unusable in DMG mode
            0x4C...0x7F => 0xFF,

            else => self.io[reg],
        };
    }

    fn writeIO(self: *Self, addr: u16, value: u8) void {
        const reg = addr & 0x7F;
        switch (reg) {
            // Joypad
            0x00 => if (self.joypad) |j| j.write(value),

            // Serial
            0x01 => self.io[0x01] = value,
            0x02 => self.io[0x02] = value,

            // Timer
            0x04 => if (self.timer) |t| t.writeDiv(),
            0x05 => if (self.timer) |t| t.writeTima(value),
            0x06 => if (self.timer) |t| t.writeTma(value),
            0x07 => if (self.timer) |t| t.writeTac(value),

            // Interrupt Flag
            0x0F => self.io[0x0F] = value,

            // Audio (stubs)
            0x10...0x3F => self.io[reg] = value,

            // PPU registers
            0x40 => if (self.ppu) |p| p.writeLcdc(value),
            0x41 => if (self.ppu) |p| p.writeStat(value),
            0x42 => if (self.ppu) |p| {
                p.scy = value;
            },
            0x43 => if (self.ppu) |p| {
                p.scx = value;
            },
            0x44 => {}, // LY is read-only
            0x45 => if (self.ppu) |p| {
                p.lyc = value;
            },
            0x46 => self.startDma(value),
            0x47 => if (self.ppu) |p| {
                p.bgp = value;
            },
            0x48 => if (self.ppu) |p| {
                p.obp0 = value;
            },
            0x49 => if (self.ppu) |p| {
                p.obp1 = value;
            },
            0x4A => if (self.ppu) |p| {
                p.wy = value;
            },
            0x4B => if (self.ppu) |p| {
                p.wx = value;
            },

            else => self.io[reg] = value,
        }
    }

    fn startDma(self: *Self, value: u8) void {
        self.io[0x46] = value;
        self.dma_active = true;
        self.dma_byte = 0;
        self.dma_value = value;
        self.dma_delay = 2; // 2 cycle delay before DMA starts
    }

    pub fn tickDma(self: *Self) void {
        if (!self.dma_active) return;

        if (self.dma_delay > 0) {
            self.dma_delay -= 1;
            return;
        }

        const src_addr: u16 = (@as(u16, self.dma_value) << 8) | self.dma_byte;
        const data = self.read(src_addr);
        self.oam[self.dma_byte] = data;

        self.dma_byte += 1;
        if (self.dma_byte >= 0xA0) {
            self.dma_active = false;
        }
    }

    // Request an interrupt
    pub fn requestInterrupt(self: *Self, interrupt: Interrupt) void {
        self.io[0x0F] |= @intFromEnum(interrupt);
    }

    // Get interrupt flag
    pub fn getIF(self: *Self) u8 {
        return self.io[0x0F];
    }

    // Set interrupt flag
    pub fn setIF(self: *Self, value: u8) void {
        self.io[0x0F] = value;
    }
};

pub const Interrupt = enum(u8) {
    vblank = 0x01,
    lcd_stat = 0x02,
    timer = 0x04,
    serial = 0x08,
    joypad = 0x10,
};

test "bus initialization" {
    var bus = Bus.init();
    try std.testing.expectEqual(@as(u8, 0x91), bus.read(0xFF40)); // LCDC
    try std.testing.expectEqual(@as(u8, 0xFC), bus.read(0xFF47)); // BGP
}

test "bus wram read/write" {
    var bus = Bus.init();
    bus.write(0xC000, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), bus.read(0xC000));
    // Echo RAM
    try std.testing.expectEqual(@as(u8, 0x42), bus.read(0xE000));
}

test "bus hram read/write" {
    var bus = Bus.init();
    bus.write(0xFF80, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.read(0xFF80));
}
