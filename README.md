# UART-Based Soft Processor with SDRAM Stack

Minimal 8-bit soft processor on Cyclone IV (AX301 board) with SDRAM-backed stack operations.

## Features

- **8-bit ISA** with 5 instructions encoded in single byte
- **SDRAM integration** (32MB @ 100MHz) for stack operations
- **UART interface** (115200 baud) for instruction input
- **7-segment display** showing register r3 and memory monitor
- **Independent memory monitor** reads SDRAM every 750μs to verify retention

## ISA (5 instructions)

**Encoding:** `[opcode:2][dst:2][subop/imm:2][src:2]`

- `MOVI rX, imm4` - Load 4-bit immediate into register (opcode 00)
- `MOV rX, rY` - Copy register (opcode 01, subop 00)
- `ADD rX, rY` - Add registers: rX = rX + rY (opcode 01, subop 01)
- `PUSH rX` - Push register to SDRAM stack (opcode 10, subop 01)
- `POP rX` - Pop from SDRAM stack to register (opcode 10, subop 00)

**Registers:** r0-r3 (r3 is display register)

**Stack:** 24-bit stack pointer, 16-bit word access, starts at 0x900010

## Display Layout

6-digit 7-segment display shows (left to right):
- `[unused][unused][monitor_high][monitor_low][r3_high][r3_low]`
- Monitor displays memory at 0x900000 (initialized to 0xCC)
- r3 shows the display register value

## Usage

1. Compile in Quartus Prime
2. Program FPGA
3. Run: `python src/myasm.py src/test_stack.txt COM3`

Example program (test_stack.txt):
```assembly
MOVI r0, 5      # r0 = 5
PUSH r0         # Push to SDRAM stack
MOVI r0, 0      # Clear r0
POP  r0         # Pop from stack (r0 = 5)
MOV  r3, r0     # Display (shows "05")
```

## Hardware

- **Board:** ALINX AX301 (Cyclone IV EP4CE6F17C8)
- **UART:** 115200 baud on PIN_M2
- **Display:** 6-digit 7-segment
- **SDRAM:** 32MB SDR-133 @ 100MHz (16-bit data bus)
- **Clock:** 50MHz input → PLL generates 100MHz for SDRAM

## Architecture

- **Main clock domain:** 100MHz (SDRAM operations, instruction execution)
- **Display clock domain:** 50MHz (7-segment multiplexing)
- **SDRAM controller:** Burst mode with automatic refresh (7.5μs period)
- **Memory layout:**
  - `0x900000-0x90000F`: Initialized area (0xCC pattern for testing)
  - `0x900010+`: Stack grows upward

## Files

- `src/uart_to_display.v` - Top module with processor + SDRAM interface
- `src/sdram_core.v` - SDRAM controller (burst mode, auto-refresh)
- `src/uart_rx.v` - UART receiver
- `src/seg_scan.v` - 7-segment display multiplexer
- `src/myasm.py` - Assembler and serial transmitter
- `src/test_stack.txt` - Test program demonstrating stack operations
