const Bus = @import("bus.zig").Bus;
const Interrupt = @import("bus.zig").Interrupt;

/// GameBoy Timer subsystem
/// DIV increments at 16384 Hz (every 256 T-cycles)
/// TIMA increments at frequency specified by TAC
pub const Timer = struct {
    bus: *Bus,

    // Internal counter (DIV is upper 8 bits)
    div_counter: u16 = 0xABCC, // Initial value after boot

    // Timer registers
    tima: u8 = 0,
    tma: u8 = 0,
    tac: u8 = 0xF8, // Upper bits always read as 1

    // Reload delay
    reload_scheduled: bool = false,
    reload_cycle: u8 = 0,

    // Previous bit for falling edge detection
    prev_bit: bool = false,

    const Self = @This();

    pub fn init(bus: *Bus) Self {
        return Self{
            .bus = bus,
        };
    }

    /// Tick the timer by the given number of T-cycles
    pub fn tick(self: *Self, cycles: u32) void {
        var i: u32 = 0;
        while (i < cycles) : (i += 1) {
            self.tickOne();
        }
    }

    fn tickOne(self: *Self) void {
        // Handle TIMA reload delay
        if (self.reload_scheduled) {
            self.reload_cycle -= 1;
            if (self.reload_cycle == 0) {
                self.tima = self.tma;
                self.reload_scheduled = false;
                self.bus.requestInterrupt(Interrupt.timer);
            }
        }

        // Increment internal counter
        self.div_counter +%= 1;

        // Check for falling edge on selected bit
        const current_bit = self.getTimerBit();
        const enabled = (self.tac & 0x04) != 0;

        if (self.prev_bit and !current_bit and enabled) {
            self.incrementTima();
        }

        self.prev_bit = current_bit and enabled;
    }

    fn getTimerBit(self: *Self) bool {
        const bit_pos: u4 = switch (self.tac & 0x03) {
            0 => 9, // 4096 Hz
            1 => 3, // 262144 Hz
            2 => 5, // 65536 Hz
            3 => 7, // 16384 Hz
            else => unreachable,
        };
        return ((self.div_counter >> bit_pos) & 1) != 0;
    }

    fn incrementTima(self: *Self) void {
        const result = @addWithOverflow(self.tima, 1);
        self.tima = result[0];
        if (result[1] == 1) {
            // Overflow - schedule reload with 4 cycle delay
            self.reload_scheduled = true;
            self.reload_cycle = 4;
        }
    }

    // Register access
    pub fn readDiv(self: *Self) u8 {
        return @truncate(self.div_counter >> 8);
    }

    pub fn writeDiv(self: *Self) void {
        // Writing any value resets DIV to 0
        // This can also affect TIMA due to falling edge detection
        const old_bit = self.getTimerBit();
        self.div_counter = 0;
        const enabled = (self.tac & 0x04) != 0;
        if (old_bit and enabled) {
            self.incrementTima();
        }
        self.prev_bit = false;
    }

    pub fn readTima(self: *Self) u8 {
        return self.tima;
    }

    pub fn writeTima(self: *Self, value: u8) void {
        // Writing TIMA during reload cycle has special behavior
        if (self.reload_scheduled and self.reload_cycle == 4) {
            // Write is ignored if reload is happening this cycle
            return;
        }
        self.tima = value;
        // Cancel any pending reload
        self.reload_scheduled = false;
    }

    pub fn readTma(self: *Self) u8 {
        return self.tma;
    }

    pub fn writeTma(self: *Self, value: u8) void {
        self.tma = value;
        // If reload is happening this cycle, new TMA is used
        if (self.reload_scheduled and self.reload_cycle == 4) {
            self.tima = value;
        }
    }

    pub fn readTac(self: *Self) u8 {
        return self.tac | 0xF8; // Upper 5 bits always read as 1
    }

    pub fn writeTac(self: *Self, value: u8) void {
        const old_enabled = (self.tac & 0x04) != 0;
        const old_bit = self.getTimerBit();

        self.tac = value | 0xF8;

        const new_enabled = (self.tac & 0x04) != 0;
        const new_bit = self.getTimerBit();

        // Falling edge glitch when changing TAC
        if (old_enabled and old_bit and !(new_enabled and new_bit)) {
            self.incrementTima();
        }

        self.prev_bit = new_enabled and new_bit;
    }
};
