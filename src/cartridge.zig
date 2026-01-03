const std = @import("std");
const Mbc = @import("mbc/mbc.zig").Mbc;
const NoMbc = @import("mbc/none.zig").NoMbc;
const Mbc1 = @import("mbc/mbc1.zig").Mbc1;
const Mbc3 = @import("mbc/mbc3.zig").Mbc3;
const Mbc5 = @import("mbc/mbc5.zig").Mbc5;

/// GameBoy Cartridge
pub const Cartridge = struct {
    rom: []const u8,
    mbc: Mbc,

    // Header info
    title: [16]u8 = undefined,
    cartridge_type: u8 = 0,
    rom_size: u8 = 0,
    ram_size: u8 = 0,

    const Self = @This();

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Self {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        // Get file size
        const stat = try file.stat(io);
        const size: usize = @intCast(stat.size);

        // Allocate and read using streaming API
        const rom = try allocator.alloc(u8, size);
        errdefer allocator.free(rom);

        var total_read: usize = 0;
        while (total_read < size) {
            const bytes_read = try file.readStreaming(io, &.{rom[total_read..]});
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        return try initFromRom(allocator, rom);
    }

    pub fn loadFromMemory(allocator: std.mem.Allocator, rom: []const u8) !Self {
        const rom_copy = try allocator.dupe(u8, rom);
        return try initFromRom(allocator, rom_copy);
    }

    fn initFromRom(allocator: std.mem.Allocator, rom: []const u8) !Self {
        if (rom.len < 0x150) {
            return error.InvalidRom;
        }

        var cart = Self{
            .rom = rom,
            .mbc = undefined,
        };

        // Parse header
        @memcpy(&cart.title, rom[0x0134..0x0144]);
        cart.cartridge_type = rom[0x0147];
        cart.rom_size = rom[0x0148];
        cart.ram_size = rom[0x0149];

        // Validate header checksum
        var checksum: u8 = 0;
        for (rom[0x0134..0x014D]) |byte| {
            checksum = checksum -% byte -% 1;
        }
        if (checksum != rom[0x014D]) {
            std.log.warn("Header checksum mismatch: expected {X:0>2}, got {X:0>2}", .{ rom[0x014D], checksum });
        }

        // Create appropriate MBC
        const ram_banks = cart.getRamBanks();
        cart.mbc = try createMbc(allocator, cart.cartridge_type, rom, ram_banks);

        return cart;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.mbc.deinit(allocator);
        allocator.free(self.rom);
    }

    fn createMbc(allocator: std.mem.Allocator, cart_type: u8, rom: []const u8, ram_banks: u8) !Mbc {
        return switch (cart_type) {
            // ROM only
            0x00 => Mbc{ .none = NoMbc.init(rom) },

            // MBC1
            0x01 => Mbc{ .mbc1 = try Mbc1.init(allocator, rom, 0) },
            0x02 => Mbc{ .mbc1 = try Mbc1.init(allocator, rom, ram_banks) },
            0x03 => Mbc{ .mbc1 = try Mbc1.init(allocator, rom, ram_banks) }, // +Battery

            // MBC3
            0x0F => Mbc{ .mbc3 = try Mbc3.init(allocator, rom, 0, true) }, // +Timer+Battery
            0x10 => Mbc{ .mbc3 = try Mbc3.init(allocator, rom, ram_banks, true) }, // +Timer+RAM+Battery
            0x11 => Mbc{ .mbc3 = try Mbc3.init(allocator, rom, 0, false) },
            0x12 => Mbc{ .mbc3 = try Mbc3.init(allocator, rom, ram_banks, false) },
            0x13 => Mbc{ .mbc3 = try Mbc3.init(allocator, rom, ram_banks, false) }, // +Battery

            // MBC5
            0x19 => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, 0) },
            0x1A => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, ram_banks) },
            0x1B => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, ram_banks) }, // +Battery
            0x1C => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, 0) }, // +Rumble
            0x1D => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, ram_banks) }, // +Rumble
            0x1E => Mbc{ .mbc5 = try Mbc5.init(allocator, rom, ram_banks) }, // +Rumble+Battery

            else => {
                std.log.warn("Unsupported cartridge type: {X:0>2}, using ROM only", .{cart_type});
                return Mbc{ .none = NoMbc.init(rom) };
            },
        };
    }

    fn getRamBanks(self: *const Self) u8 {
        return switch (self.ram_size) {
            0x00 => 0,
            0x01 => 0, // Listed as 2KB, but usually unused
            0x02 => 1, // 8KB
            0x03 => 4, // 32KB
            0x04 => 16, // 128KB
            0x05 => 8, // 64KB
            else => 0,
        };
    }

    pub fn read(self: *Self, addr: u16) u8 {
        return self.mbc.read(addr);
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        self.mbc.write(addr, value);
    }

    pub fn getTitle(self: *const Self) []const u8 {
        // Find null terminator or end
        var len: usize = 0;
        for (self.title) |c| {
            if (c == 0) break;
            len += 1;
        }
        return self.title[0..len];
    }

    pub fn getCartridgeTypeName(self: *const Self) []const u8 {
        return switch (self.cartridge_type) {
            0x00 => "ROM ONLY",
            0x01 => "MBC1",
            0x02 => "MBC1+RAM",
            0x03 => "MBC1+RAM+BATTERY",
            0x05 => "MBC2",
            0x06 => "MBC2+BATTERY",
            0x0F => "MBC3+TIMER+BATTERY",
            0x10 => "MBC3+TIMER+RAM+BATTERY",
            0x11 => "MBC3",
            0x12 => "MBC3+RAM",
            0x13 => "MBC3+RAM+BATTERY",
            0x19 => "MBC5",
            0x1A => "MBC5+RAM",
            0x1B => "MBC5+RAM+BATTERY",
            0x1C => "MBC5+RUMBLE",
            0x1D => "MBC5+RUMBLE+RAM",
            0x1E => "MBC5+RUMBLE+RAM+BATTERY",
            else => "UNKNOWN",
        };
    }

    pub fn getRomSizeKb(self: *const Self) u32 {
        return @as(u32, 32) << @intCast(self.rom_size);
    }

    pub fn getRamSizeKb(self: *const Self) u32 {
        return switch (self.ram_size) {
            0x00 => 0,
            0x01 => 2,
            0x02 => 8,
            0x03 => 32,
            0x04 => 128,
            0x05 => 64,
            else => 0,
        };
    }
};
