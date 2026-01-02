const std = @import("std");

/// MBC3 - Used by Pokemon Gold/Silver and many others
/// Supports up to 2MB ROM, 32KB RAM, and RTC
pub const Mbc3 = struct {
    rom: []const u8,
    ram: ?[]u8,

    // Registers
    ram_rtc_enabled: bool = false,
    rom_bank: u8 = 1,
    ram_bank_or_rtc: u8 = 0,

    // RTC registers
    rtc_s: u8 = 0, // Seconds (0-59)
    rtc_m: u8 = 0, // Minutes (0-59)
    rtc_h: u8 = 0, // Hours (0-23)
    rtc_dl: u8 = 0, // Day counter low
    rtc_dh: u8 = 0, // Day counter high + flags

    // RTC latching
    rtc_latched: bool = false,
    rtc_latch_prepare: bool = false,
    latched_s: u8 = 0,
    latched_m: u8 = 0,
    latched_h: u8 = 0,
    latched_dl: u8 = 0,
    latched_dh: u8 = 0,

    // Config
    has_rtc: bool,
    rom_banks: u16,
    ram_banks: u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, rom: []const u8, ram_banks: u8, has_rtc: bool) !Self {
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
            .has_rtc = has_rtc,
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
            0x0000...0x3FFF => if (addr < self.rom.len) self.rom[addr] else 0xFF,

            // ROM Bank N (0x4000-0x7FFF)
            0x4000...0x7FFF => {
                const bank: u32 = if (self.rom_bank == 0) 1 else self.rom_bank;
                const rom_addr = (bank % self.rom_banks) * 0x4000 + (addr - 0x4000);
                return if (rom_addr < self.rom.len) self.rom[rom_addr] else 0xFF;
            },

            // External RAM / RTC (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_rtc_enabled) return 0xFF;

                if (self.ram_bank_or_rtc <= 0x03) {
                    // RAM access
                    if (self.ram) |ram| {
                        const bank: u32 = self.ram_bank_or_rtc % self.ram_banks;
                        const ram_addr = bank * 0x2000 + (addr - 0xA000);
                        return if (ram_addr < ram.len) ram[ram_addr] else 0xFF;
                    }
                    return 0xFF;
                } else if (self.has_rtc and self.ram_bank_or_rtc >= 0x08 and self.ram_bank_or_rtc <= 0x0C) {
                    // RTC register access
                    if (self.rtc_latched) {
                        return switch (self.ram_bank_or_rtc) {
                            0x08 => self.latched_s,
                            0x09 => self.latched_m,
                            0x0A => self.latched_h,
                            0x0B => self.latched_dl,
                            0x0C => self.latched_dh,
                            else => 0xFF,
                        };
                    } else {
                        return switch (self.ram_bank_or_rtc) {
                            0x08 => self.rtc_s,
                            0x09 => self.rtc_m,
                            0x0A => self.rtc_h,
                            0x0B => self.rtc_dl,
                            0x0C => self.rtc_dh,
                            else => 0xFF,
                        };
                    }
                }
                return 0xFF;
            },

            else => 0xFF,
        };
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        switch (addr) {
            // RAM/RTC Enable (0x0000-0x1FFF)
            0x0000...0x1FFF => {
                self.ram_rtc_enabled = (value & 0x0F) == 0x0A;
            },

            // ROM Bank Number (0x2000-0x3FFF)
            0x2000...0x3FFF => {
                self.rom_bank = value & 0x7F;
                if (self.rom_bank == 0) self.rom_bank = 1;
            },

            // RAM Bank / RTC Register Select (0x4000-0x5FFF)
            0x4000...0x5FFF => {
                self.ram_bank_or_rtc = value;
            },

            // Latch Clock Data (0x6000-0x7FFF)
            0x6000...0x7FFF => {
                if (self.has_rtc) {
                    if (value == 0x00) {
                        self.rtc_latch_prepare = true;
                    } else if (value == 0x01 and self.rtc_latch_prepare) {
                        self.rtc_latched = !self.rtc_latched;
                        if (self.rtc_latched) {
                            self.latched_s = self.rtc_s;
                            self.latched_m = self.rtc_m;
                            self.latched_h = self.rtc_h;
                            self.latched_dl = self.rtc_dl;
                            self.latched_dh = self.rtc_dh;
                        }
                        self.rtc_latch_prepare = false;
                    } else {
                        self.rtc_latch_prepare = false;
                    }
                }
            },

            // External RAM / RTC (0xA000-0xBFFF)
            0xA000...0xBFFF => {
                if (!self.ram_rtc_enabled) return;

                if (self.ram_bank_or_rtc <= 0x03) {
                    // RAM write
                    if (self.ram) |ram| {
                        const bank: u32 = self.ram_bank_or_rtc % self.ram_banks;
                        const ram_addr = bank * 0x2000 + (addr - 0xA000);
                        if (ram_addr < ram.len) {
                            ram[ram_addr] = value;
                        }
                    }
                } else if (self.has_rtc and self.ram_bank_or_rtc >= 0x08 and self.ram_bank_or_rtc <= 0x0C) {
                    // RTC register write
                    switch (self.ram_bank_or_rtc) {
                        0x08 => self.rtc_s = value & 0x3F,
                        0x09 => self.rtc_m = value & 0x3F,
                        0x0A => self.rtc_h = value & 0x1F,
                        0x0B => self.rtc_dl = value,
                        0x0C => self.rtc_dh = value & 0xC1,
                        else => {},
                    }
                }
            },

            else => {},
        }
    }

    // Call this once per second to update RTC
    pub fn tickRtc(self: *Self) void {
        if (!self.has_rtc) return;
        if ((self.rtc_dh & 0x40) != 0) return; // Halt flag set

        self.rtc_s +%= 1;
        if (self.rtc_s >= 60) {
            self.rtc_s = 0;
            self.rtc_m +%= 1;
            if (self.rtc_m >= 60) {
                self.rtc_m = 0;
                self.rtc_h +%= 1;
                if (self.rtc_h >= 24) {
                    self.rtc_h = 0;
                    // Increment day counter
                    const day: u16 = (@as(u16, self.rtc_dh & 0x01) << 8) | self.rtc_dl;
                    const new_day = day +% 1;
                    self.rtc_dl = @truncate(new_day);
                    self.rtc_dh = (self.rtc_dh & 0xFE) | @as(u8, @truncate(new_day >> 8));
                    if (new_day > 0x1FF) {
                        self.rtc_dh |= 0x80; // Set carry flag
                    }
                }
            }
        }
    }
};
