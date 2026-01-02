/// No MBC - ROM only cartridges (32KB max)
pub const NoMbc = struct {
    rom: []const u8,

    const Self = @This();

    pub fn init(rom: []const u8) Self {
        return Self{
            .rom = rom,
        };
    }

    pub fn read(self: *Self, addr: u16) u8 {
        return switch (addr) {
            // ROM (0x0000-0x7FFF)
            0x0000...0x7FFF => if (addr < self.rom.len) self.rom[addr] else 0xFF,
            // No external RAM
            0xA000...0xBFFF => 0xFF,
            else => 0xFF,
        };
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        _ = self;
        _ = addr;
        _ = value;
        // ROM only - writes are ignored
    }
};
