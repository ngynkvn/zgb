const Bus = @import("bus.zig").Bus;
const Interrupt = @import("bus.zig").Interrupt;

/// GameBoy PPU (Picture Processing Unit)
/// Renders 160x144 pixel display at ~59.7 fps
pub const Ppu = struct {
    bus: *Bus,

    // LCD Control Register (FF40)
    lcdc: u8 = 0x91,

    // LCD Status Register (FF41)
    stat: u8 = 0x85,

    // Position and scrolling
    scy: u8 = 0, // Scroll Y (FF42)
    scx: u8 = 0, // Scroll X (FF43)
    ly: u8 = 0, // Current scanline (FF44)
    lyc: u8 = 0, // LY Compare (FF45)
    wy: u8 = 0, // Window Y (FF4A)
    wx: u8 = 0, // Window X (FF4B)

    // Palettes
    bgp: u8 = 0xFC, // BG Palette (FF47)
    obp0: u8 = 0, // Sprite Palette 0 (FF48)
    obp1: u8 = 0, // Sprite Palette 1 (FF49)

    // Internal state
    mode: Mode = .oam_search,
    dots: u16 = 0, // Dot counter within scanline
    frame_ready: bool = false,

    // Window internal line counter
    window_line: u8 = 0,
    window_triggered: bool = false,

    // Framebuffer (160x144 pixels, 2 bits per pixel packed, but stored as bytes for simplicity)
    framebuffer: [160 * 144]u8 = undefined,

    // STAT interrupt tracking
    stat_line: bool = false,

    pub const Mode = enum(u2) {
        hblank = 0,
        vblank = 1,
        oam_search = 2,
        pixel_transfer = 3,
    };

    pub const SCREEN_WIDTH = 160;
    pub const SCREEN_HEIGHT = 144;
    pub const DOTS_PER_LINE = 456;
    pub const LINES_PER_FRAME = 154;
    pub const VBLANK_START = 144;

    const Self = @This();

    pub fn init(bus: *Bus) Self {
        var ppu = Self{
            .bus = bus,
        };
        @memset(&ppu.framebuffer, 0);
        return ppu;
    }

    /// Tick PPU by one T-cycle
    pub fn tick(self: *Self) void {
        if (!self.isLcdEnabled()) {
            return;
        }

        self.dots += 1;

        switch (self.mode) {
            .oam_search => {
                if (self.dots >= 80) {
                    self.setMode(.pixel_transfer);
                }
            },
            .pixel_transfer => {
                // Simplified: assume constant 172 dots for pixel transfer
                if (self.dots >= 80 + 172) {
                    self.renderScanline();
                    self.setMode(.hblank);
                }
            },
            .hblank => {
                if (self.dots >= DOTS_PER_LINE) {
                    self.dots = 0;
                    self.ly += 1;

                    if (self.ly >= VBLANK_START) {
                        self.setMode(.vblank);
                        self.bus.requestInterrupt(Interrupt.vblank);
                        self.frame_ready = true;
                        self.window_line = 0;
                    } else {
                        self.setMode(.oam_search);
                        self.window_triggered = false;
                    }
                    self.checkLycInterrupt();
                }
            },
            .vblank => {
                if (self.dots >= DOTS_PER_LINE) {
                    self.dots = 0;
                    self.ly += 1;

                    if (self.ly >= LINES_PER_FRAME) {
                        self.ly = 0;
                        self.setMode(.oam_search);
                        self.window_triggered = false;
                    }
                    self.checkLycInterrupt();
                }
            },
        }
    }

    fn setMode(self: *Self, mode: Mode) void {
        self.mode = mode;
        self.stat = (self.stat & 0xFC) | @intFromEnum(mode);
        self.updateStatInterrupt();
    }

    fn checkLycInterrupt(self: *Self) void {
        const coincidence = self.ly == self.lyc;
        if (coincidence) {
            self.stat |= 0x04;
        } else {
            self.stat &= ~@as(u8, 0x04);
        }
        self.updateStatInterrupt();
    }

    fn updateStatInterrupt(self: *Self) void {
        var stat_condition = false;

        // Mode 0 H-Blank interrupt
        if ((self.stat & 0x08) != 0 and self.mode == .hblank) {
            stat_condition = true;
        }
        // Mode 1 V-Blank interrupt
        if ((self.stat & 0x10) != 0 and self.mode == .vblank) {
            stat_condition = true;
        }
        // Mode 2 OAM interrupt
        if ((self.stat & 0x20) != 0 and self.mode == .oam_search) {
            stat_condition = true;
        }
        // LYC=LY interrupt
        if ((self.stat & 0x40) != 0 and (self.stat & 0x04) != 0) {
            stat_condition = true;
        }

        // Rising edge detection
        if (stat_condition and !self.stat_line) {
            self.bus.requestInterrupt(Interrupt.lcd_stat);
        }
        self.stat_line = stat_condition;
    }

    fn renderScanline(self: *Self) void {
        const line_offset = @as(usize, self.ly) * SCREEN_WIDTH;

        // Clear line
        @memset(self.framebuffer[line_offset .. line_offset + SCREEN_WIDTH], 0);

        // Render background
        if (self.isBgEnabled()) {
            self.renderBackground(line_offset);
        }

        // Render window
        if (self.isWindowEnabled() and self.ly >= self.wy) {
            self.renderWindow(line_offset);
        }

        // Render sprites
        if (self.isSpritesEnabled()) {
            self.renderSprites(line_offset);
        }
    }

    fn renderBackground(self: *Self, line_offset: usize) void {
        const tile_map_base: u16 = if ((self.lcdc & 0x08) != 0) 0x9C00 else 0x9800;
        const tile_data_base: u16 = if ((self.lcdc & 0x10) != 0) 0x8000 else 0x8800;
        const signed_addressing = (self.lcdc & 0x10) == 0;

        const y = self.ly +% self.scy;
        const tile_row = @as(u16, (y / 8) & 31); // Wrap at 32 tiles
        const pixel_row = @as(u16, y % 8);

        var x: u16 = 0;
        while (x < SCREEN_WIDTH) : (x += 1) {
            const scroll_x: u8 = @truncate(x +% @as(u16, self.scx));
            const tile_col = @as(u16, (scroll_x / 8) & 31); // Wrap at 32 tiles
            const pixel_col: u3 = @intCast(scroll_x % 8);

            const tile_map_addr = tile_map_base + tile_row * 32 + tile_col;
            const tile_index = self.bus.vram[tile_map_addr - 0x8000];

            const tile_addr: u16 = if (signed_addressing) blk: {
                const signed_idx: i16 = @as(i8, @bitCast(tile_index));
                const offset: i16 = signed_idx * 16;
                break :blk @intCast(@as(i32, 0x9000) + offset);
            } else tile_data_base + @as(u16, tile_index) * 16;

            const row_addr = tile_addr + pixel_row * 2;
            const lo = self.bus.vram[row_addr - 0x8000];
            const hi = self.bus.vram[row_addr + 1 - 0x8000];

            const bit: u3 = 7 - pixel_col;
            const color_id = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
            const color = (self.bgp >> (@as(u3, @intCast(color_id)) * 2)) & 0x03;

            self.framebuffer[line_offset + x] = color;
        }
    }

    fn renderWindow(self: *Self, line_offset: usize) void {
        if (self.wx > 166) return;

        const window_x = @as(i16, self.wx) - 7;
        if (window_x >= SCREEN_WIDTH) return;

        if (!self.window_triggered) {
            self.window_triggered = true;
        }

        const tile_map_base: u16 = if ((self.lcdc & 0x40) != 0) 0x9C00 else 0x9800;
        const tile_data_base: u16 = if ((self.lcdc & 0x10) != 0) 0x8000 else 0x8800;
        const signed_addressing = (self.lcdc & 0x10) == 0;

        const tile_row = @as(u16, (self.window_line / 8) & 31);
        const pixel_row = @as(u16, self.window_line % 8);

        const start_x: u16 = if (window_x < 0) 0 else @intCast(window_x);

        var x: u16 = start_x;
        while (x < SCREEN_WIDTH) : (x += 1) {
            const wx_offset = if (window_x < 0)
                x + @as(u16, @intCast(-window_x))
            else
                x - @as(u16, @intCast(window_x));

            const tile_col = (wx_offset / 8) & 31;
            const pixel_col: u3 = @intCast(wx_offset % 8);

            const tile_map_addr = tile_map_base + tile_row * 32 + tile_col;
            const tile_index = self.bus.vram[tile_map_addr - 0x8000];

            const tile_addr: u16 = if (signed_addressing) blk: {
                const signed_idx: i16 = @as(i8, @bitCast(tile_index));
                const offset: i16 = signed_idx * 16;
                break :blk @intCast(@as(i32, 0x9000) + offset);
            } else tile_data_base + @as(u16, tile_index) * 16;

            const row_addr = tile_addr + pixel_row * 2;
            const lo = self.bus.vram[row_addr - 0x8000];
            const hi = self.bus.vram[row_addr + 1 - 0x8000];

            const bit: u3 = 7 - pixel_col;
            const color_id = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);
            const color = (self.bgp >> (@as(u3, @intCast(color_id)) * 2)) & 0x03;

            self.framebuffer[line_offset + x] = color;
        }

        self.window_line += 1;
    }

    fn renderSprites(self: *Self, line_offset: usize) void {
        const sprite_height: u8 = if ((self.lcdc & 0x04) != 0) 16 else 8;

        // Collect sprites on this scanline (max 10)
        var sprites: [10]SpriteData = undefined;
        var sprite_count: u8 = 0;

        var i: u16 = 0;
        while (i < 40 and sprite_count < 10) : (i += 1) {
            const oam_addr = i * 4;
            const y_pos = @as(i16, self.bus.oam[oam_addr]) - 16;
            const x_pos = @as(i16, self.bus.oam[oam_addr + 1]) - 8;
            const tile_index = self.bus.oam[oam_addr + 2];
            const attributes = self.bus.oam[oam_addr + 3];

            const ly_i16: i16 = self.ly;
            if (ly_i16 >= y_pos and ly_i16 < y_pos + sprite_height) {
                sprites[sprite_count] = .{
                    .x = x_pos,
                    .y = y_pos,
                    .tile = tile_index,
                    .attrs = attributes,
                    .oam_index = @intCast(i),
                };
                sprite_count += 1;
            }
        }

        // Sort by X position (DMG priority: lower X = higher priority)
        // Simple bubble sort for up to 10 elements
        var n: u8 = sprite_count;
        while (n > 1) {
            var j: u8 = 0;
            while (j < n - 1) : (j += 1) {
                if (sprites[j].x > sprites[j + 1].x or
                    (sprites[j].x == sprites[j + 1].x and sprites[j].oam_index > sprites[j + 1].oam_index))
                {
                    const tmp = sprites[j];
                    sprites[j] = sprites[j + 1];
                    sprites[j + 1] = tmp;
                }
            }
            n -= 1;
        }

        // Render sprites in reverse order (lowest priority first)
        var s: u8 = sprite_count;
        while (s > 0) {
            s -= 1;
            const sprite = sprites[s];
            self.renderSprite(line_offset, sprite, sprite_height);
        }
    }

    fn renderSprite(self: *Self, line_offset: usize, sprite: SpriteData, sprite_height: u8) void {
        const flip_y = (sprite.attrs & 0x40) != 0;
        const flip_x = (sprite.attrs & 0x20) != 0;
        const palette = if ((sprite.attrs & 0x10) != 0) self.obp1 else self.obp0;
        const bg_priority = (sprite.attrs & 0x80) != 0;

        var row = @as(i16, self.ly) - sprite.y;
        if (flip_y) {
            row = sprite_height - 1 - row;
        }

        const tile = if (sprite_height == 16)
            (sprite.tile & 0xFE) + @as(u8, if (row >= 8) 1 else 0)
        else
            sprite.tile;

        const tile_row: u16 = @intCast(@mod(row, 8));
        const tile_addr: u16 = 0x8000 + @as(u16, tile) * 16 + tile_row * 2;
        const lo = self.bus.vram[tile_addr - 0x8000];
        const hi = self.bus.vram[tile_addr + 1 - 0x8000];

        var px: u8 = 0;
        while (px < 8) : (px += 1) {
            const screen_x = sprite.x + @as(i16, px);
            if (screen_x < 0 or screen_x >= SCREEN_WIDTH) continue;

            const px3: u3 = @intCast(px);
            const bit: u3 = if (flip_x) px3 else 7 - px3;
            const color_id = (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1);

            // Color 0 is transparent for sprites
            if (color_id == 0) continue;

            const fb_idx = line_offset + @as(usize, @intCast(screen_x));

            // BG priority: sprite hidden behind BG colors 1-3
            if (bg_priority and self.framebuffer[fb_idx] != 0) continue;

            const color = (palette >> (@as(u3, @intCast(color_id)) * 2)) & 0x03;
            self.framebuffer[fb_idx] = color;
        }
    }

    const SpriteData = struct {
        x: i16,
        y: i16,
        tile: u8,
        attrs: u8,
        oam_index: u8,
    };

    // LCDC bit helpers
    fn isLcdEnabled(self: *Self) bool {
        return (self.lcdc & 0x80) != 0;
    }

    fn isBgEnabled(self: *Self) bool {
        return (self.lcdc & 0x01) != 0;
    }

    fn isWindowEnabled(self: *Self) bool {
        return (self.lcdc & 0x20) != 0;
    }

    fn isSpritesEnabled(self: *Self) bool {
        return (self.lcdc & 0x02) != 0;
    }

    // Register access
    pub fn readLcdc(self: *Self) u8 {
        return self.lcdc;
    }

    pub fn writeLcdc(self: *Self, value: u8) void {
        const was_enabled = self.isLcdEnabled();
        self.lcdc = value;

        if (was_enabled and !self.isLcdEnabled()) {
            // LCD disabled - reset state
            self.ly = 0;
            self.dots = 0;
            self.mode = .hblank;
            self.stat = (self.stat & 0xFC) | @intFromEnum(Mode.hblank);
            self.window_line = 0;
        }
    }

    pub fn readStat(self: *Self) u8 {
        return self.stat | 0x80; // Bit 7 always reads as 1
    }

    pub fn writeStat(self: *Self, value: u8) void {
        // Mode and coincidence flags are read-only
        self.stat = (value & 0x78) | (self.stat & 0x07);
        self.updateStatInterrupt();
    }

    /// Check if a new frame is ready and reset the flag
    pub fn pollFrameReady(self: *Self) bool {
        if (self.frame_ready) {
            self.frame_ready = false;
            return true;
        }
        return false;
    }

    /// Get the framebuffer for rendering
    pub fn getFramebuffer(self: *Self) *const [160 * 144]u8 {
        return &self.framebuffer;
    }
};
