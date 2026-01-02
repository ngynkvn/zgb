const std = @import("std");

/// MBC5 - Used by Pokemon Crystal and later games
/// Supports up to 8MB ROM and 128KB RAM
pub const Mbc5 = struct {
    rom: []const u8,
    ram: ?[]u8,

    // Registers
    ram_enabled: bool = false,
    rom_bank_lo: u8 = 1,
    rom_bank_hi: u8 = 0,
    ram_bank: u8 = 0,

    // Derived values
    rom_banks: u16,
    ram_banks: u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, rom: []const u8, ram_banks: u8) !Self {
        const ram = if (ram_banks > 0)
            try allocator.alloc(u8, @as(usize, ram_banks) * 0x2000)
        else
            null;

        if (ram) |r| {
            @memset(r, 0);
        }

        return Self{
            .rom = rom,
            .ram = ram,
            .rom_banks = @intCast(@max(1, rom.len / 0x4000)),
            .ram_banks = ram_banks,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.ram) |r| {
            allocator.free(r);
        }
    }

    fn getRomBank(self: *Self) u16 {
        return (@as(u16, self.rom_bank_hi & 0x01) << 8) | self.rom_bank_lo;
    }

    pub fn read(self: *Self, addr: u16) u8 {
        return switch (addr) {
            // ROM Bank 0 (0x0000-0x3FFF)
            0x0000...0x3FFF => if (addr < self.rom.len) self.rom[addr] else 0xFF,

            // ROM Bank N (0x4000-0x7FFF)
            0x4000...0x7FFF => {
                const bank: u32 = self.getRomBank() % self.rom_banks;
                const rom_addr = bank * 0x4000 + (addr - 0x4000);
                return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
            },

            // External RAM (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_enabled) return 0xFF;
                if (self.ram) |ram| {
                    const bank: u32 = self.ram_bank % self.ram_banks;
                    const ram_addr = bank * 0x2000 + (addr - 0xA000);
                    return if (ram_addr < ram.len) ram[ram_addr] else 0xFF;
                }
                return 0xFF;
            },

            else => 0xFF,
        };
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        switch (addr) {
            // RAM Enable (0x0000-0x1FFF)
            0x0000...0x1FFF => {
                self.ram_enabled = (value & 0x0F) == 0x0A;
            },

            // ROM Bank Low (0x2000-0x2FFF)
            0x2000...0x2FFF => {
                self.rom_bank_lo = value;
            },

            // ROM Bank High (0x3000-0x3FFF)
            0x3000...0x3FFF => {
                self.rom_bank_hi = value & 0x01;
            },

            // RAM Bank (0x4000-0x5FFF)
            0x4000...0x5FFF => {
                self.ram_bank = value & 0x0F;
            },

            // External RAM (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_enabled) return;
                if (self.ram) |ram| {
                    const bank: u32 = self.ram_bank % self.ram_banks;
                    const ram_addr = bank * 0x2000 + (addr - 0xA000);
                    if (ram_addr < ram.len) {
                        ram[ram_addr] = value;
                    }
                }
            },

            else => {},
        }
    }
};
