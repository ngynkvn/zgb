// zgb - GameBoy Emulator Library
pub const Cpu = @import("cpu.zig").Cpu;
pub const Bus = @import("bus.zig").Bus;
pub const Interrupt = @import("bus.zig").Interrupt;
pub const Ppu = @import("ppu.zig").Ppu;
pub const Timer = @import("timer.zig").Timer;
pub const Joypad = @import("joypad.zig").Joypad;
pub const Button = @import("joypad.zig").Button;
pub const Cartridge = @import("cartridge.zig").Cartridge;

const std = @import("std");

/// Complete GameBoy emulator state
pub const GameBoy = struct {
    bus: Bus,
    cpu: Cpu,
    ppu: Ppu,
    timer: Timer,
    joypad: Joypad,
    cartridge: ?Cartridge = null,

    allocator: std.mem.Allocator,

    // Timing
    cycles_per_frame: u32 = 70224, // ~59.7 fps
    cycles_this_frame: u32 = 0,

    const Self = @This();

    /// Create an uninitialized GameBoy struct.
    /// IMPORTANT: You MUST call setup() after the struct is in its final memory location!
    pub fn create(allocator: std.mem.Allocator) Self {
        return Self{
            .bus = Bus.init(),
            .cpu = undefined,
            .ppu = undefined,
            .timer = undefined,
            .joypad = undefined,
            .allocator = allocator,
        };
    }

    /// Wire up internal component pointers.
    /// Must be called after the struct is in its final memory location.
    pub fn setup(self: *Self) void {
        // Connect components - now using stable pointer to self
        self.cpu = Cpu.init(&self.bus);
        self.ppu = Ppu.init(&self.bus);
        self.timer = Timer.init(&self.bus);
        self.joypad = Joypad.init(&self.bus);

        // Wire up bus connections
        self.bus.ppu = &self.ppu;
        self.bus.timer = &self.timer;
        self.bus.joypad = &self.joypad;
    }

    pub fn deinit(self: *Self) void {
        if (self.cartridge) |*cart| {
            cart.deinit();
        }
    }

    pub fn loadRom(self: *Self, path: []const u8) !void {
        if (self.cartridge) |*cart| {
            cart.deinit();
        }

        self.cartridge = try Cartridge.load(self.allocator, path);
        self.bus.cartridge = &self.cartridge.?;

        std.log.info("Loaded: {s}", .{self.cartridge.?.getTitle()});
        std.log.info("Type: {s}", .{self.cartridge.?.getCartridgeTypeName()});
        std.log.info("ROM: {}KB, RAM: {}KB", .{ self.cartridge.?.getRomSizeKb(), self.cartridge.?.getRamSizeKb() });
    }

    /// Run one CPU instruction and advance all subsystems
    pub fn step(self: *Self) u32 {
        const cpu_cycles = self.cpu.step();

        // Advance timer
        self.timer.tick(cpu_cycles);

        // Advance PPU
        var ppu_cycles: u32 = 0;
        while (ppu_cycles < cpu_cycles) : (ppu_cycles += 1) {
            self.ppu.tick();
            self.bus.tickDma();
        }

        self.cycles_this_frame += cpu_cycles;
        return cpu_cycles;
    }

    /// Debug: dump CPU state
    pub fn debugCpuState(self: *Self) void {
        std.log.debug("PC:{X:0>4} AF:{X:0>4} BC:{X:0>4} DE:{X:0>4} HL:{X:0>4} SP:{X:0>4}", .{
            self.cpu.pc,
            self.cpu.af(),
            self.cpu.bc(),
            self.cpu.de(),
            self.cpu.hl(),
            self.cpu.sp,
        });
    }

    /// Debug: dump PPU state
    pub fn debugPpuState(self: *Self) void {
        std.log.debug("PPU: LY={} LCDC={X:0>2} STAT={X:0>2} mode={}", .{
            self.ppu.ly,
            self.ppu.lcdc,
            self.ppu.stat,
            @intFromEnum(self.ppu.mode),
        });
    }

    /// Debug: check VRAM for non-zero data
    pub fn debugVram(self: *Self) void {
        var nonzero_count: u32 = 0;
        for (self.bus.vram) |b| {
            if (b != 0) nonzero_count += 1;
        }
        std.log.debug("VRAM: {}/8192 non-zero bytes", .{nonzero_count});

        // Check tile map area (0x9800-0x9BFF and 0x9C00-0x9FFF)
        var tilemap_nonzero: u32 = 0;
        for (self.bus.vram[0x1800..0x2000]) |b| {
            if (b != 0) tilemap_nonzero += 1;
        }
        std.log.debug("Tilemap: {}/2048 non-zero bytes", .{tilemap_nonzero});
    }

    /// Debug: trace next N instructions
    pub fn debugTrace(self: *Self, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const pc = self.cpu.pc;
            const opcode = self.bus.read(pc);
            std.log.debug("[{X:0>4}] {X:0>2}", .{ pc, opcode });
            _ = self.step();
        }
    }

    /// Debug: dump ROM entry point
    pub fn debugRomEntry(self: *Self) void {
        std.log.info("ROM bytes at entry point (0x0100-0x010F):", .{});
        var i: u16 = 0x0100;
        while (i < 0x0110) : (i += 1) {
            const b = self.bus.read(i);
            std.log.debug("  [{X:0>4}] = {X:0>2}", .{ i, b });
        }
    }

    /// Run until frame is complete
    pub fn runFrame(self: *Self) void {
        self.cycles_this_frame = 0;
        while (self.cycles_this_frame < self.cycles_per_frame) {
            _ = self.step();
        }
    }

    /// Check if a new frame is ready to display
    pub fn isFrameReady(self: *Self) bool {
        return self.ppu.pollFrameReady();
    }

    /// Get the framebuffer (160x144 pixels, 2-bit color indices)
    pub fn getFramebuffer(self: *Self) *const [160 * 144]u8 {
        return self.ppu.getFramebuffer();
    }

    /// Set button state
    pub fn setButton(self: *Self, button: Button, pressed: bool) void {
        self.joypad.setButton(button, pressed);
    }

    /// Reset the emulator
    pub fn reset(self: *Self) void {
        self.bus = Bus.init();
        self.cpu = Cpu.init(&self.bus);
        self.ppu = Ppu.init(&self.bus);
        self.timer = Timer.init(&self.bus);
        self.joypad = Joypad.init(&self.bus);

        self.bus.ppu = &self.ppu;
        self.bus.timer = &self.timer;
        self.bus.joypad = &self.joypad;

        if (self.cartridge) |*cart| {
            self.bus.cartridge = cart;
        }

        self.cycles_this_frame = 0;
    }
};

test "gameboy basic initialization" {
    const allocator = std.testing.allocator;
    var gb = GameBoy.create(allocator);
    gb.setup();
    defer gb.deinit();

    try std.testing.expectEqual(@as(u16, 0x0100), gb.cpu.pc);
}
