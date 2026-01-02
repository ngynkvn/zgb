const std = @import("std");
const zgb = @import("zgb");
const c = @import("c.zig");

pub const std_options = std.Options{
    .log_level = .debug,
};

const SCREEN_WIDTH = 160;
const SCREEN_HEIGHT = 144;
const SCALE = 4;

// DMG palette colors (classic green)
const PALETTE = [4]c.Color{
    c.Color{ .r = 155, .g = 188, .b = 15, .a = 255 }, // Lightest
    c.Color{ .r = 139, .g = 172, .b = 15, .a = 255 },
    c.Color{ .r = 48, .g = 98, .b = 48, .a = 255 },
    c.Color{ .r = 15, .g = 56, .b = 15, .a = 255 }, // Darkest
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: zgb <rom.gb>\n", .{});
        std.debug.print("\nControls:\n", .{});
        std.debug.print("  Arrow keys - D-pad\n", .{});
        std.debug.print("  Z - A button\n", .{});
        std.debug.print("  X - B button\n", .{});
        std.debug.print("  Enter - Start\n", .{});
        std.debug.print("  Backspace - Select\n", .{});
        std.debug.print("  R - Reset\n", .{});
        std.debug.print("  Escape - Quit\n", .{});
        return;
    }

    const rom_path = args[1];

    // Initialize emulator
    // Two-phase init: create struct first, then setup pointers after it's in final location
    var gb = zgb.GameBoy.create(allocator);
    gb.setup(); // Now pointers point to correct locations
    defer gb.deinit();

    // Load ROM
    gb.loadRom(rom_path) catch |err| {
        std.debug.print("Failed to load ROM: {}\n", .{err});
        return;
    };

    // Debug: trace first 20 instructions
    std.log.info("=== Initial CPU trace ===", .{});
    gb.debugTrace(20);
    std.log.info("=== End trace ===", .{});

    // Initialize raylib window
    c.initWindow(SCREEN_WIDTH * SCALE, SCREEN_HEIGHT * SCALE, "zgb - GameBoy Emulator");
    defer c.closeWindow();

    c.setTargetFPS(60);

    // Create pixel buffer
    var pixels: [SCREEN_WIDTH * SCREEN_HEIGHT]c.Color = undefined;
    for (&pixels) |*p| {
        p.* = PALETTE[0];
    }

    // Create image with correct format
    const image = c.raylib.Image{
        .data = @ptrCast(&pixels),
        .width = SCREEN_WIDTH,
        .height = SCREEN_HEIGHT,
        .mipmaps = 1,
        .format = c.raylib.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };

    const texture = c.loadTextureFromImage(image);
    defer c.unloadTexture(texture);

    var frame_count: u32 = 0;

    // Main loop
    while (!c.windowShouldClose()) {
        // Handle input
        handleInput(&gb);

        // Check for reset
        if (c.isKeyPressed(c.KEY_R)) {
            gb.reset();
        }

        // Run emulator for one frame
        gb.runFrame();

        // Debug output every 60 frames
        frame_count += 1;
        if (frame_count % 60 == 0) {
            std.log.info("Frame {}", .{frame_count});
            gb.debugCpuState();
            gb.debugPpuState();
            gb.debugVram();
        }

        // Convert framebuffer to RGBA Colors
        const fb = gb.getFramebuffer();
        for (0..SCREEN_WIDTH * SCREEN_HEIGHT) |i| {
            const color_idx = fb[i] & 0x03;
            pixels[i] = PALETTE[color_idx];
        }

        // Update texture with new pixel data
        c.raylib.UpdateTexture(texture, @ptrCast(&pixels));

        // Draw
        c.beginDrawing();
        c.clearBackground(c.DARKGRAY);

        // Draw scaled texture
        const dest_rect = c.Rectangle{
            .x = 0,
            .y = 0,
            .width = SCREEN_WIDTH * SCALE,
            .height = SCREEN_HEIGHT * SCALE,
        };
        const src_rect = c.Rectangle{
            .x = 0,
            .y = 0,
            .width = SCREEN_WIDTH,
            .height = SCREEN_HEIGHT,
        };
        c.drawTexturePro(texture, src_rect, dest_rect, c.Vector2{ .x = 0, .y = 0 }, 0, c.WHITE);

        // Draw FPS
        c.drawFPS(5, 5);

        c.endDrawing();
    }
}

fn handleInput(gb: *zgb.GameBoy) void {
    // D-pad
    gb.setButton(.right, c.isKeyDown(c.KEY_RIGHT));
    gb.setButton(.left, c.isKeyDown(c.KEY_LEFT));
    gb.setButton(.up, c.isKeyDown(c.KEY_UP));
    gb.setButton(.down, c.isKeyDown(c.KEY_DOWN));

    // Buttons
    gb.setButton(.a, c.isKeyDown(c.KEY_Z));
    gb.setButton(.b, c.isKeyDown(c.KEY_X));
    gb.setButton(.start, c.isKeyDown(c.KEY_ENTER));
    gb.setButton(.select, c.isKeyDown(c.KEY_BACKSPACE));
}
