# Architecture

This document describes the technical architecture of zgb.

## Overview

zgb separates the emulator core (`zgb` module) from the frontend (`main.zig`). The core handles all Game Boy hardware emulation while the frontend manages windowing, input, and rendering.

```
┌─────────────────────────────────────────────────────┐
│                    main.zig                         │
│              (raylib frontend)                      │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│                   GameBoy                           │
│                  (root.zig)                         │
├─────────────────────────────────────────────────────┤
│  ┌─────┐  ┌─────┐  ┌───────┐  ┌───────┐  ┌──────┐  │
│  │ CPU │  │ PPU │  │ Timer │  │Joypad │  │ Cart │  │
│  └──┬──┘  └──┬──┘  └───┬───┘  └───┬───┘  └──┬───┘  │
│     │        │         │          │         │      │
│     └────────┴────┬────┴──────────┴─────────┘      │
│                   │                                 │
│              ┌────▼────┐                           │
│              │   Bus   │                           │
│              └─────────┘                           │
└─────────────────────────────────────────────────────┘
```

## Component Communication

All components communicate through the **Bus**. Components hold a pointer to the Bus, and the Bus holds optional pointers back to components that need direct access (PPU, Timer, Joypad, Cartridge).

### Initialization

GameBoy uses a two-phase initialization to handle Zig's value semantics:

```zig
var gb = GameBoy.create();  // Creates struct with undefined component fields
gb.setup();                  // Wires up pointers after struct is in final location
```

This is necessary because component pointers would be invalidated if the GameBoy struct moved after initialization.

## CPU (cpu.zig)

Implements the SM83 (Sharp LR35902), a Z80-derived processor.

### Registers

```
┌───┬───┐
│ A │ F │  AF (Accumulator + Flags)
├───┼───┤
│ B │ C │  BC
├───┼───┤
│ D │ E │  DE
├───┼───┤
│ H │ L │  HL
└───┴───┘
   SP      Stack Pointer (16-bit)
   PC      Program Counter (16-bit)
```

Flags (F register): Z (Zero), N (Subtract), H (Half-carry), C (Carry)

### Register Access

The CPU uses enum-based register accessors:

- `r8(Reg8)` - Returns pointer to 8-bit register (A, F, B, C, D, E, H, L)
- `r16(Register16)` - Returns pointer to 16-bit pair (BC, DE, HL, SP)
- `r16stk(Register16Stack)` - Stack variant (BC, DE, HL, AF)

### Opcode Decoding

Many opcodes follow patterns where register selection is encoded in 3-bit fields:

```
REG_DECODE: [8]?Reg8 = { B, C, D, E, H, L, (HL), A }
```

The `readR8Idx()` and `writeR8Idx()` functions handle this, returning memory at (HL) for index 6.

ALU operations use `aluDispatch()` which maps 3-bit op codes to: ADD, ADC, SUB, SBC, AND, XOR, OR, CP.

### Instruction Execution

`step()` executes one instruction:
1. Handle scheduled IME (from EI instruction)
2. Check and handle interrupts if IME is set
3. If halted, check wake condition or return 4 cycles
4. Fetch and execute opcode

CB-prefixed instructions are handled in `executeCb()` for bit operations and rotates/shifts.

## Bus (bus.zig)

Maps the 64KB address space:

| Range         | Size  | Description          |
|---------------|-------|----------------------|
| 0x0000-0x3FFF | 16KB  | ROM Bank 0           |
| 0x4000-0x7FFF | 16KB  | ROM Bank N (switchable) |
| 0x8000-0x9FFF | 8KB   | Video RAM            |
| 0xA000-0xBFFF | 8KB   | External RAM         |
| 0xC000-0xDFFF | 8KB   | Work RAM             |
| 0xE000-0xFDFF | -     | Echo RAM (mirrors WRAM) |
| 0xFE00-0xFE9F | 160B  | OAM (sprite attributes) |
| 0xFEA0-0xFEFF | -     | Unusable             |
| 0xFF00-0xFF7F | 128B  | I/O Registers        |
| 0xFF80-0xFFFE | 127B  | High RAM             |
| 0xFFFF        | 1B    | Interrupt Enable     |

### I/O Register Routing

`readIO()` and `writeIO()` dispatch to appropriate components:
- 0xFF00: Joypad
- 0xFF04-0xFF07: Timer (DIV, TIMA, TMA, TAC)
- 0xFF0F: Interrupt Flag
- 0xFF40-0xFF4B: PPU registers

### DMA Transfer

OAM DMA copies 160 bytes from source address to OAM. Triggered by writing to 0xFF46. Has a 2-cycle startup delay, then transfers one byte per cycle.

## PPU (ppu.zig)

Renders 160x144 pixels at ~59.7 fps.

### Timing

Each frame consists of 154 scanlines, each taking 456 dots (T-cycles):

| Scanline | Mode Sequence |
|----------|---------------|
| 0-143    | OAM Search (80 dots) → Pixel Transfer (~172 dots) → H-Blank |
| 144-153  | V-Blank |

### Rendering Pipeline

Each visible scanline renders in order:
1. **Background** - 256x256 tilemap, scrolled by SCX/SCY
2. **Window** - Fixed overlay, positioned by WX/WY
3. **Sprites** - Up to 40 sprites, 10 per scanline limit

### Tile Addressing

Two addressing modes controlled by LCDC bit 4:
- **8000 mode**: Tiles 0-255 at 0x8000-0x8FFF (unsigned)
- **8800 mode**: Tiles -128 to 127 at 0x8800-0x97FF (signed, base 0x9000)

### STAT Interrupts

STAT interrupt triggers on rising edge of any enabled condition:
- Mode 0 (H-Blank)
- Mode 1 (V-Blank)
- Mode 2 (OAM Search)
- LYC=LY coincidence

## Timer (timer.zig)

### Registers

- **DIV** (0xFF04): Upper 8 bits of internal 16-bit counter, increments every 256 T-cycles
- **TIMA** (0xFF05): Timer counter, increments at frequency set by TAC
- **TMA** (0xFF06): Timer modulo, loaded into TIMA on overflow
- **TAC** (0xFF07): Timer control (enable + frequency select)

### Frequency Selection

TAC bits 0-1 select which bit of the internal counter triggers TIMA increment:

| TAC | Frequency | Counter Bit |
|-----|-----------|-------------|
| 00  | 4096 Hz   | Bit 9       |
| 01  | 262144 Hz | Bit 3       |
| 10  | 65536 Hz  | Bit 5       |
| 11  | 16384 Hz  | Bit 7       |

TIMA increments on **falling edge** of the selected bit AND enable.

### Overflow Behavior

When TIMA overflows:
1. TIMA becomes 0x00
2. After 4 cycles, TIMA is reloaded from TMA
3. Timer interrupt is requested

## Cartridge (cartridge.zig)

Handles ROM loading and header parsing.

### Header Fields (0x0134-0x014F)

- Title (0x0134-0x0143)
- Cartridge type (0x0147)
- ROM size (0x0148)
- RAM size (0x0149)
- Header checksum (0x014D)

### MBC Selection

Cartridge type byte determines MBC:

| Type | MBC |
|------|-----|
| 0x00 | None (ROM only) |
| 0x01-0x03 | MBC1 |
| 0x0F-0x13 | MBC3 |
| 0x19-0x1E | MBC5 |

## Memory Bank Controllers (mbc/)

MBCs handle ROM/RAM banking for cartridges larger than 32KB ROM or 8KB RAM.

### MBC Interface

All MBCs implement read/write through a tagged union (`Mbc`):

```zig
pub const Mbc = union(enum) {
    none: NoMbc,
    mbc1: Mbc1,
    mbc3: Mbc3,
    mbc5: Mbc5,
};
```

### Banking Regions

- **0x0000-0x3FFF**: ROM Bank 0 (sometimes switchable on MBC1)
- **0x4000-0x7FFF**: ROM Bank N (switchable)
- **0xA000-0xBFFF**: External RAM (switchable, if present)

### MBC1

- Up to 2MB ROM (125 banks) or 32KB RAM (4 banks)
- Two modes: ROM banking mode (default) and RAM banking mode
- 5-bit ROM bank register + 2-bit upper bits/RAM bank register

### MBC3

- Up to 2MB ROM, 32KB RAM
- Optional RTC (Real-Time Clock)
- 7-bit ROM bank register, 4-bit RAM bank/RTC register

### MBC5

- Up to 8MB ROM (512 banks), 128KB RAM (16 banks)
- 9-bit ROM bank register, 4-bit RAM bank register
- No mode switching complexity

## Joypad (joypad.zig)

### Register (0xFF00)

```
Bit 7-6: Unused (read as 1)
Bit 5: Select buttons (active low)
Bit 4: Select D-pad (active low)
Bit 3-0: Input lines (active low)
```

When select bit is low, corresponding button group is read on bits 3-0:

| Bit | D-pad | Buttons |
|-----|-------|---------|
| 0   | Right | A       |
| 1   | Left  | B       |
| 2   | Up    | Select  |
| 3   | Down  | Start   |

Joypad interrupt triggers on any button press (high-to-low transition).

## Interrupts

Five interrupt sources, priority from high to low:

| Bit | Address | Source |
|-----|---------|--------|
| 0   | 0x0040  | V-Blank |
| 1   | 0x0048  | LCD STAT |
| 2   | 0x0050  | Timer |
| 3   | 0x0058  | Serial |
| 4   | 0x0060  | Joypad |

Interrupt handling:
1. Check IE & IF for pending interrupts
2. Disable IME
3. Clear IF bit
4. Push PC to stack
5. Jump to handler address
