const Bus = @import("bus.zig").Bus;
const Interrupt = @import("bus.zig").Interrupt;

/// GameBoy Joypad Input
/// Button states are active-low (0 = pressed)
pub const Joypad = struct {
    bus: *Bus,

    // Select which buttons to read
    select_buttons: bool = false,
    select_dpad: bool = false,

    // Button states (active-high internally, inverted on read)
    dpad: Buttons = .{},
    buttons: Buttons = .{},

    pub const Buttons = packed struct {
        right_a: bool = false,
        left_b: bool = false,
        up_select: bool = false,
        down_start: bool = false,
    };

    const Self = @This();

    pub fn init(bus: *Bus) Self {
        return Self{
            .bus = bus,
        };
    }

    pub fn read(self: *Self) u8 {
        var result: u8 = 0xCF; // Upper 2 bits always 1, lower 4 bits default to 1

        if (!self.select_buttons) {
            result &= 0xDF; // Bit 5 = 0
            // Read button states
            if (self.buttons.right_a) result &= ~@as(u8, 0x01);
            if (self.buttons.left_b) result &= ~@as(u8, 0x02);
            if (self.buttons.up_select) result &= ~@as(u8, 0x04);
            if (self.buttons.down_start) result &= ~@as(u8, 0x08);
        }

        if (!self.select_dpad) {
            result &= 0xEF; // Bit 4 = 0
            // Read D-pad states
            if (self.dpad.right_a) result &= ~@as(u8, 0x01);
            if (self.dpad.left_b) result &= ~@as(u8, 0x02);
            if (self.dpad.up_select) result &= ~@as(u8, 0x04);
            if (self.dpad.down_start) result &= ~@as(u8, 0x08);
        }

        return result;
    }

    pub fn write(self: *Self, value: u8) void {
        self.select_buttons = (value & 0x20) != 0;
        self.select_dpad = (value & 0x10) != 0;
    }

    /// Update button state and potentially trigger interrupt
    pub fn setButton(self: *Self, button: Button, pressed: bool) void {
        const was_pressed = self.isPressed(button);

        switch (button) {
            .right => self.dpad.right_a = pressed,
            .left => self.dpad.left_b = pressed,
            .up => self.dpad.up_select = pressed,
            .down => self.dpad.down_start = pressed,
            .a => self.buttons.right_a = pressed,
            .b => self.buttons.left_b = pressed,
            .select => self.buttons.up_select = pressed,
            .start => self.buttons.down_start = pressed,
        }

        // Request interrupt on high-to-low transition (button press)
        if (pressed and !was_pressed) {
            self.bus.requestInterrupt(Interrupt.joypad);
        }
    }

    fn isPressed(self: *Self, button: Button) bool {
        return switch (button) {
            .right => self.dpad.right_a,
            .left => self.dpad.left_b,
            .up => self.dpad.up_select,
            .down => self.dpad.down_start,
            .a => self.buttons.right_a,
            .b => self.buttons.left_b,
            .select => self.buttons.up_select,
            .start => self.buttons.down_start,
        };
    }
};

pub const Button = enum {
    right,
    left,
    up,
    down,
    a,
    b,
    select,
    start,
};
