# Dual-Core Soft Processor FPGA Project

16-bit dual-core soft processor with VGA framebuffer output on Cyclone IV (ALINX AX301 board). Features SDRAM-backed execution, line-buffered VGA display (1024×768@60Hz), and a clean ISA designed for graphics programming.

## Current Status: Phase 1c Complete ✅

**Working:**
- 16-bit soft processor with SDRAM stack
- VGA output (1024×768@60Hz, RGB565 format)
- Dual line-buffered SDRAM framebuffer scanout
- UART instruction input (115200 baud)
- 7-segment display for register debugging
- Diagonal test pattern with aspect-ratio correction

**Next Phase:** Processor framebuffer access (LOAD/STORE instructions)

## Features

### Processor Core
- **16-bit ISA** with 4 instruction families (R/M/J/X)
- **16 general-purpose registers** (r0-r15)
- **24-bit addressing** for SDRAM access
- **UART interface** for instruction streaming
- **Dual-core architecture** (planned: Main + Shader cores)

### VGA Display System
- **Resolution:** 1024×768@60Hz (VESA standard)
- **Color format:** RGB565 (16-bit per pixel)
- **Framebuffer:** 1.5 MiB in SDRAM (double-buffered)
- **Line buffers:** Dual 2KB SRAM (ping-pong architecture)
- **Performance:** 3-4 μs line fill time (5:1 margin vs 20.67 μs deadline)

### Memory System
- **SDRAM:** 32 MiB @ 100MHz with burst mode
- **SRAM:** 32 KiB Block RAM (line buffers, caches, stacks)
- **Automatic refresh:** 7.5 μs period for data retention
- **Arbiter:** VGA priority > Processor > Monitor

## ISA Overview

**Encoding:** `[Op:2][Mod:6][Src:4][Dst:4]` (16-bit fixed width)

### R-Family (Opcode 00) - ALU Operations
```
MOV   rd, rs        # Register copy
ADD   rd, rs        # Add (rd = rd + rs)
XOR   rd, rs        # Bitwise XOR
ADDI  rd, imm4      # Add immediate (4-bit)
```

### M-Family (Opcode 01) - Memory Operations
```
LOAD  rd, [rs]      # Load from memory (planned)
STORE rd, [rs]      # Store to memory (planned)
PUSH  rd            # Push to data stack
POP   rd            # Pop from data stack
```

### J-Family (Opcode 10) - Jumps and Constants
```
JMP   offset        # Unconditional jump (±2048 instructions)
JZ    offset        # Jump if zero
LDC   const_id      # Load 16-bit constant from pool (13-bit ID)
LDCS  rd            # Copy constant TOS to register
```

### X-Family (Opcode 11) - Reserved
- Future extensions (floating-point, SIMD, graphics accelerators)

## Architecture

### Clock Domains
- **50MHz:** Input clock, 7-segment display
- **100MHz:** SDRAM controller, processor execution
- **65MHz:** VGA pixel clock (from video_pll: 50MHz × 13/10)

### Memory Map

**SDRAM (32 MiB):**
```
0x000000 - 0x17FFFF   Framebuffer 0 (1.5 MiB, 1024×768 RGB565)
0x180000 - 0x2FFFFF   Framebuffer 1 (1.5 MiB, double-buffer)
0x300000 - 0x33FFFF   Font Atlas (256 KiB)
0x900000 - 0x903FFF   Constant Pool (16 KiB, 8192×16-bit)
0x904000+             Program memory and heap
```

**SRAM (32 KiB):**
```
0x0000 - 0x07FF   Line Buffer A (2 KiB)
0x0800 - 0x0FFF   Line Buffer B (2 KiB)
0x1000 - 0x77FF   Caches and work buffers (26 KiB)
0x7800 - 0x7F7F   Data Stack (2 KiB, grows upward)
0x7F80 - 0x7FFF   Constant Stack (128 bytes)
```

## Display Layout

**7-segment display** (6 digits, left to right):
- `[r3[15:12]][r3[11:8]][r3[7:4]][r3[3:0]][unused][unused]`
- Shows r3 register value in hex (e.g., "A301" = 0xA301)

**VGA output** (1024×768):
- Displays SDRAM framebuffer in real-time
- Current test pattern: Diagonal split with checkerboard regions

## Usage

### Hardware Setup
1. Connect ALINX AX301 board to VGA monitor
2. Connect UART (115200 baud) on PIN_M2
3. Compile in Quartus Prime and program FPGA

### Running Programs
```bash
python src/myasm.py src/test_stack.txt COM3
```

Example program (test_stack.txt):
```assembly
# Load immediate using XOR + ADDI pattern
XOR  r0, r0         # r0 = 0
ADDI r0, 5          # r0 = 5

# Stack operations
PUSH r0             # Push to SDRAM stack
XOR  r0, r0         # Clear r0
POP  r0             # Pop (r0 = 5)
MOV  r3, r0         # Display shows "0005"
```

## Hardware

- **Board:** ALINX AX301 (Cyclone IV EP4CE6F17C8)
- **Logic Elements:** 1,443 / 6,272 (23% utilized)
- **Block RAM:** 16 KiB / 276 KiB (6% utilized)
- **PLLs:** 2 / 2 (sys_pll @ 100MHz, video_pll @ 65MHz)
- **UART:** 115200 baud, 8N1 on PIN_M2
- **Display:** 6-digit 7-segment + VGA output
- **SDRAM:** 32 MiB H57V2562 @ 100MHz (16-bit data bus)

## Project Structure

```
src/
├── uart_to_display.v      # Top module (processor + SDRAM + VGA)
├── sdram_core.v           # SDRAM controller (burst mode)
├── vga_controller.v       # VGA line buffer reader
├── vga_timing.v           # VGA timing generator (1024×768@60Hz)
├── video_define.v         # Video resolution parameters
├── uart_rx.v              # UART receiver
├── seg_scan.v             # 7-segment multiplexer
├── myasm.py               # Assembler and serial transmitter
├── test_stack.txt         # Test program
└── ip_core/
    ├── sys_pll.qip        # PLL: 50MHz → 100MHz
    ├── video_pll.v        # PLL: 50MHz → 65MHz
    └── video_pll_bb.v     # Black box for video_pll

docs/
├── CLAUDE.md              # Technical documentation and roadmap
├── VGA_FRAMEBUFFER_STATUS.md  # Phase 1c completion status
└── REFACTOR_16BIT.md      # ISA design notes

seg_test.qsf               # Quartus project settings
uart_to_display.sdc        # Timing constraints
README.md                  # This file
```

## Key Design Decisions

- **RGB565 over RGB888:** 33% bandwidth savings, native SDRAM width
- **Dual line buffers:** Ping-pong eliminates VGA underruns
- **256-word bursts:** Fits SDRAM page (≤512), reduces overhead
- **2-cycle inter-block wait:** Prevents arbiter collision
- **Quasi-static CDC:** Exploits 20 μs line period for safe multi-bit crossing
- **Constant pool in SDRAM:** Larger range (8192 constants) than inline immediates
- **Fixed 16-bit encoding:** Simpler decoder, no variable-length complexity

## Documentation

- **CLAUDE.md** - Detailed technical notes, ISA specification, lessons learned
- **VGA_FRAMEBUFFER_STATUS.md** - Phase 1c completion status and next steps
- **docs/REFACTOR_16BIT.md** - ISA design rationale and migration notes

## Development Phases

- ✅ **Phase 0:** 8-bit ISA with SDRAM stack (deprecated)
- ✅ **Phase 1a:** 16-bit ISA foundation with register expansion
- ✅ **Phase 1b:** VGA output with repeating line buffer
- ✅ **Phase 1c:** SDRAM framebuffer scanout (dual line buffers)
- 🔄 **Phase 1d:** Processor LOAD/STORE for framebuffer writes (next)
- 📋 **Phase 2:** Dual-core architecture (Main + Shader cores)
- 📋 **Phase 3:** Graphics pipeline (rasterizer, texture mapping)

## License

**Original Work (MIT License):**
- Processor core and ISA architecture
- VGA framebuffer pipeline & VGA controller

**Reference Designs from ALINX:**
- SDRAM controller base (sdram_core.v)
- VGA timing generator base (vga_timing.v)

---

MIT License

Copyright (c) 2025 Alex Yang Ph.D.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
