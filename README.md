# zgb

A Game Boy (DMG) emulator written in Zig.

## Features

- SM83 CPU emulation (Sharp LR35902)
- PPU with background, window, and sprite rendering
- Timer with accurate falling-edge detection
- Joypad input
- MBC support: ROM-only, MBC1, MBC3, MBC5

## Requirements

- Zig 0.16.0 or later
- raylib (included as a dependency)

## Building

```bash
zig build
```

## Running

```bash
zig build run -- <path/to/rom.gb>
```

## Controls

| Key       | Button |
|-----------|--------|
| Arrow keys | D-pad  |
| Z         | A      |
| X         | B      |
| Enter     | Start  |
| Backspace | Select |
| R         | Reset  |
| Escape    | Quit   |

## Testing

```bash
zig build test
```

## Project Structure

```
src/
├── main.zig       # raylib frontend
├── root.zig       # zgb library exports
├── cpu.zig        # SM83 CPU
├── bus.zig        # Memory bus
├── ppu.zig        # Picture Processing Unit
├── timer.zig      # DIV/TIMA timer
├── joypad.zig     # Input handling
├── cartridge.zig  # ROM loading
└── mbc/           # Memory Bank Controllers
    ├── mbc.zig
    ├── none.zig
    ├── mbc1.zig
    ├── mbc3.zig
    └── mbc5.zig
```

## Library Usage

The emulator core is available as a separate `zgb` module that can be used without the raylib frontend:

```zig
const zgb = @import("zgb");

var gb = zgb.GameBoy.create();
gb.setup();
defer gb.deinit(allocator);

try gb.loadRom(allocator, "game.gb");

// Main loop
while (running) {
    gb.runFrame();
    const framebuffer = gb.getFramebuffer();
    // Render framebuffer (160x144, 2-bit color indices)
}
```

## Status

Work in progress. Many games are playable but accuracy improvements are ongoing.
