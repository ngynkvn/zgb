const std = @import("std");
const NoMbc = @import("none.zig").NoMbc;
const Mbc1 = @import("mbc1.zig").Mbc1;
const Mbc3 = @import("mbc3.zig").Mbc3;
const Mbc5 = @import("mbc5.zig").Mbc5;

/// Memory Bank Controller union
pub const Mbc = union(enum) {
    none: NoMbc,
    mbc1: Mbc1,
    mbc3: Mbc3,
    mbc5: Mbc5,

    const Self = @This();

    pub fn read(self: *Self, addr: u16) u8 {
        return switch (self.*) {
            .none => |*m| m.read(addr),
            .mbc1 => |*m| m.read(addr),
            .mbc3 => |*m| m.read(addr),
            .mbc5 => |*m| m.read(addr),
        };
    }

    pub fn write(self: *Self, addr: u16, value: u8) void {
        switch (self.*) {
            .none => |*m| m.write(addr, value),
            .mbc1 => |*m| m.write(addr, value),
            .mbc3 => |*m| m.write(addr, value),
            .mbc5 => |*m| m.write(addr, value),
        }
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .none => {},
            .mbc1 => |*m| m.deinit(),
            .mbc3 => |*m| m.deinit(),
            .mbc5 => |*m| m.deinit(),
        }
    }
};
