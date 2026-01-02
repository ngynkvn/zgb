const std = @import("std");

/// MBC1 - Most common MBC for early GameBoy games
/// Supports up to 2MB ROM and 32KB RAM
pub const Mbc1 = struct {
    rom: []const u8,
    ram: ?[]u8,

    // Registers
    ram_enabled: bool = false,
    rom_bank: u8 = 1,
    ram_bank: u8 = 0,
    banking_mode: bool = false, // false = ROM mode, true = RAM mode

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
            .rom_banks = @intCast(rom.len / 0x4000),
            .ram_banks = ram_banks,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.ram) |r| {
            allocator.free(r);
        }
    }

    pub fn read(self: *Self, addr: u16) u8 {
        return switch (addr) {
            // ROM Bank 0 (0x0000-0x3FFF)
            0x0000...0x3FFF => {
                var bank: u32 = 0;
                if (self.banking_mode) {
                    bank = (@as(u32, self.ram_bank) << 5) % self.rom_banks;
                }
                const rom_addr = (bank * 0x4000) + addr;
                return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
            },

            // ROM Bank N (0x4000-0x7FFF)
            0x4000...0x7FFF => {
                var bank: u32 = self.rom_bank;
                bank |= @as(u32, self.ram_bank) << 5;
                bank %= self.rom_banks;
                const rom_addr = (bank * 0x4000) + (addr - 0x4000);
                return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
            },

            // External RAM (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_enabled) return 0xFF;
                if (self.ram) |ram| {
                    var bank: u32 = 0;
                    if (self.banking_mode) {
                        bank = self.ram_bank % self.ram_banks;
                    }
                    const ram_addr = (bank * 0x2000) + (addr - 0xA000);
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

            // ROM Bank Number (0x2000-0x3FFF)
            0x2000...0x3FFF => {
                var bank = value & 0x1F;
                if (bank == 0) bank = 1; // Bank 0 maps to bank 1
                self.rom_bank = bank;
            },

            // RAM Bank Number / Upper ROM Bank (0x4000-0x5FFF)
            0x4000...0x5FFF => {
                self.ram_bank = value & 0x03;
            },

            // Banking Mode Select (0x6000-0x7FFF)
            0x6000...0x7FFF => {
                self.banking_mode = (value & 0x01) != 0;
            },

            // External RAM (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_enabled) return;
                if (self.ram) |ram| {
                    var bank: u32 = 0;
                    if (self.banking_mode) {
                        bank = self.ram_bank % self.ram_banks;
                    }
                    const ram_addr = (bank * 0x2000) + (addr - 0xA000);
                    if (ram_addr < ram.len) {
                        ram[ram_addr] = value;
                    }
                }
            },

            else => {},
        }
    }
};
