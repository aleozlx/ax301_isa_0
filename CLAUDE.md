# Dual-Core Soft Processor FPGA Project

> **Note:** See `chat_context.txt` for the high-level project roadmap (text/graphics dual-mode processor architecture). That roadmap is stable and will not change in the medium term. This file documents the current implementation status and ISA design.

## Current Status: VGA Output Working! 🎉

Successfully implemented VGA output with line-buffered display. The processor now renders to a 2KB SRAM line buffer that repeats on all scanlines, providing immediate visual debugging feedback. The VGA controller generates a stable 1024×768@60Hz signal.

**Hardware verified working:**
- 16-bit soft processor with SDRAM stack ✓
- VGA timing generation (1024×768@60Hz) ✓
- Line buffer scanout (2KB SRAM, RGB565 format) ✓
- Dual clock domains (100MHz processor, 65MHz VGA) ✓
- Test pattern display (8 vertical color bars) ✓

## What's Working

### Processor Core (16-bit ISA)
- **16-bit ISA** with 7 instructions: MOV, ADD, XOR, ADDI, PUSH, POP
- **16 general-purpose registers** (r0-r15, where r3 is display register)
- **16-bit instruction encoding:** `[Op:2][Mod:6][Src:4][Dst:4]`
- **UART instruction input** @ 115200 baud (2 bytes per instruction)
- **24-bit stack pointer** with SDRAM-backed stack
- **State machine execution** with proper SDRAM handshaking

### SDRAM Integration
- **SDRAM controller** (burst mode, 16-bit data width)
- **Automatic refresh** every 7.5μs (critical for data retention)
- **100MHz clock domain** for SDRAM operations
- **Proper clock output** to SDRAM chip (sdram_clk = 100MHz)
- **16-bit word access** (native SDRAM width)
- **Verified data retention** via independent periodic monitor

### Display System
- **6-digit 7-segment display** @ 50MHz clock domain
- **Layout**: [r3[15:12]][r3[11:8]][r3[7:4]][r3[3:0]][unused][unused]
- **Full 16-bit display** of r3 register (4 hex digits)
- **Real-time register display** (r3 updates on MOV r3, rX)

### VGA Output System (NEW!)
- **VGA timing generator** (1024×768@60Hz, negative H/V sync)
- **65MHz pixel clock** (from video_pll: 50MHz × 13/10)
- **RGB565 output** (5-bit red, 6-bit green, 5-bit blue)
- **Line buffer architecture**: 2KB SRAM (1024 pixels × 16-bit)
- **Repeating scanlines**: Same line buffer displayed on all 768 rows
- **Test pattern**: 8 vertical color bars (128 pixels each)
  - Red (F800) | Green (07E0) | Blue (001F) | Yellow (FFE0)
  - Cyan (07FF) | Magenta (F81F) | White (FFFF) | Black (0000)
- **"Barcode effect"**: Processor writes to SRAM → immediately visible on screen
- **Dual-clock design**: VGA reads @ 65MHz, processor writes @ 100MHz

## Key Lessons Learned

### Critical Bug Fix: Missing SDRAM Clock
**Problem:** Memory contents would immediately become 0xFF, suggesting refresh failure.

**Root Cause:** Missing `sdram_clk` output pin! The SDRAM chip had no clock signal, so it couldn't perform any operations including refresh. Without refresh, capacitor charge leaked and memory showed 0xFF (floating high).

**Solution:**
```verilog
// uart_to_display.v
output wire sdram_clk;
assign sdram_clk = clk_100mhz;

// seg_test.qsf
set_location_assignment PIN_B14 -to sdram_clk
```

### SDRAM Handshaking Protocol
- Requests must be **held HIGH** until finish signal asserts
- Cannot use edge detection on requests
- Data must be provided when `wr_burst_data_req` asserts
- Read data valid for multiple cycles during `rd_burst_data_valid`

### 16-bit ISA Design Philosophy
The processor uses a clean, explicit ISA with no "magic" instructions:
- **No MOVI**: Use `XOR rd, rd; ADDI rd, imm` to load immediates explicitly
- **Transparent encoding**: Each assembly line = exactly one 16-bit instruction
- **ADDI semantics**: `rd = rd + imm` (accumulative, not load)
- **XOR for clearing**: `XOR rd, rd` sets register to zero efficiently

### Burst Length Configuration
The SDRAM Mode Register was configured for full-page bursts (`3'b111`), but we only use 1-word bursts (`burst_len = 10'd1`). This is fine because the controller's `end_tread`/`end_twrite` counters terminate the burst early based on the `burst_len` parameter. The Mode Register setting doesn't prevent shorter bursts.

## Architecture Details

### Memory Map

#### SRAM (32 KiB - Block RAM)
```
0x0000 - 0x07FF   VGA Line Buffer (2 KiB, 1024×16-bit RGB565)
0x0800 - 0x7FFF   Reserved for future use (30 KiB)
```

#### SDRAM (32 MiB)
```
0x900000 - 0x90000F   Initialized test area (0xCC pattern)
0x900010+             Stack (grows upward)
```

### Clock Domains
- **50MHz**: Input clock, drives 7-segment display multiplexing
- **100MHz**: sys_pll output, drives SDRAM controller and processor execution
- **65MHz**: video_pll output, drives VGA pixel clock and timing generator

### State Machine
```
EXEC_INIT          → Initialize SDRAM with 0xCC pattern
EXEC_INIT_WAIT     → Wait for init write to complete
EXEC_INIT_READ     → Read back to verify SDRAM working
EXEC_INIT_READ_WAIT→ Wait for init read, display result on r3
EXEC_FETCH         → Wait for UART instruction
EXEC_PUSH_WAIT     → Wait for PUSH write to complete
EXEC_POP_WAIT      → Wait for POP read to complete
```

### Independent Monitor
```verilog
// Separate always block, independent FSM
// Reads 0x900000 every 750μs (100x slower than refresh period)
// Proves SDRAM refresh is working
always @(posedge clk_100mhz) begin
    if (monitor_counter == 17'd75000) begin
        // Issue read request
        monitor_rd_req <= 1'b1;
        // Address multiplexing: monitor overrides main when active
    end
end
```

## Current Instruction Set

### R-Family (Opcode 00)
```
MOV  rd, rs     00 000000 ssss dddd    rd = rs
ADD  rd, rs     00 000001 ssss dddd    rd = rd + rs
XOR  rd, rs     00 000101 ssss dddd    rd = rd ^ rs
ADDI rd, imm4   00 010000 iiii dddd    rd = rd + imm (imm in src field)
```

### M-Family (Opcode 01)
```
PUSH rd         01 000010 0000 dddd    mem[sp] = rd; sp += 2
POP  rd         01 000011 0000 dddd    sp -= 2; rd = mem[sp]
```

### Usage Examples
```assembly
# Load immediate value (2 instructions)
XOR  r0, r0     # r0 = 0
ADDI r0, 5      # r0 = 0 + 5 = 5

# Clear register (1 instruction)
XOR  r1, r1     # r1 = 0

# Accumulate
ADDI r0, 3      # r0 = r0 + 3 (no clear needed)
```

## Test Program (test_stack.txt)

```assembly
# Test 1: Basic PUSH/POP
XOR  r0, r0     # r0 = 0
ADDI r0, 5      # r0 = 5
PUSH r0         # Push to stack
XOR  r0, r0     # Clear
POP  r0         # r0 = 5
MOV  r3, r0     # Display: 0005

# Test 2: LIFO verification
XOR  r1, r1
ADDI r1, 9      # r1 = 9
PUSH r1
XOR  r2, r2
ADDI r2, 3      # r2 = 3
PUSH r2
POP  r1         # r1 = 3 (LIFO)
POP  r2         # r2 = 9
ADD  r1, r2     # r1 = 12
MOV  r3, r1     # Display: 000C

# Test 3: Wide registers (r4-r15)
XOR  r4, r4
ADDI r4, 15     # r4 = 15
MOV  r5, r4
ADD  r5, r4     # r5 = 30
MOV  r3, r5     # Display: 001E
```

**Expected display sequence:**
- Initial: `a301` (SDRAM init pattern)
- After test 1: `0005`
- After test 2: `000c`
- After test 3: `001e`

## Phase 1a: 16-bit ISA Foundation (Current)

### Completed
- ✅ 16-bit register file (16 registers × 16 bits)
- ✅ 16-bit instruction encoding: `[Op:2][Mod:6][Src:4][Dst:4]`
- ✅ 2-byte UART instruction reception
- ✅ Basic ALU operations (MOV, ADD, XOR, ADDI)
- ✅ Stack operations (PUSH, POP)
- ✅ 16-bit display output

### Next Steps
- Add more ALU operations (SUB, AND, OR, shifts)
- Implement branch instructions (JMP, JZ, JNZ) with 12-bit offset
- Add LDC/LDCS for constant pool access
- Prepare for dual-core architecture

## ISA Architecture: 4 Instruction Families

**Fixed 16-bit encoding:** `[Op:2][Mod:6][Src:4][Dst:4]`

### Current Implementation Status
- **R-Family (00)**: MOV, ADD, XOR, ADDI ✅
- **M-Family (01)**: PUSH, POP ✅
- **J-Family (10)**: Not implemented yet
- **X-Family (11)**: Reserved for future

#### Family 0: R-Family (Register/ALU Operations)
**Opcode:** `00`

**Format:** `00 mmmmmm ssss dddd`
- **Mod[5:0]:** ALU operation variant (64 possible)
- **Src[3:0]:** Source register (r0-r15)
- **Dst[3:0]:** Destination register (r0-r15)

**Core Operations:**
```
00 000000 ssss dddd    MOV   rd, rs
00 000001 ssss dddd    ADD   rd, rs        (rd = rd + rs)
00 000010 ssss dddd    SUB   rd, rs        (rd = rd - rs)
00 000011 ssss dddd    AND   rd, rs
00 000100 ssss dddd    OR    rd, rs
00 000101 ssss dddd    XOR   rd, rs
00 000110 ssss dddd    SHL   rd, rs        (shift left by rs amount)
00 000111 ssss dddd    SHR   rd, rs        (logical shift right)
00 001000 ssss dddd    SAR   rd, rs        (arithmetic shift right)
00 001001 ssss dddd    MUL   rd, rs        (low 16 bits)
00 001010 ssss dddd    CMP   rd, rs        (compare, set flags)
00 001011 ssss dddd    TEST  rd, rs        (bitwise test)
00 001100 ssss dddd    NOT   rd, rs
00 001101 ssss dddd    NEG   rd, rs
00 001110 xxxx dddd    INC   rd
00 001111 xxxx dddd    DEC   rd

4-bit immediate variants (Src = immediate):
00 010000 iiii dddd    ADDI  rd, imm4
00 010001 iiii dddd    SUBI  rd, imm4
00 010010 iiii dddd    SHLI  rd, imm4
00 010011 iiii dddd    SHRI  rd, imm4
00 010100 iiii dddd    CMPI  rd, imm4
00 010101 iiii dddd    ANDI  rd, imm4
00 010110 iiii dddd    ORI   rd, imm4
00 010111 iiii dddd    XORI  rd, imm4
```

#### Family 1: M-Family (Memory Operations)
**Opcode:** `01`

**Format:** `01 mmmmmm ssss dddd`
- **Mod[5:0]:** Memory operation type
- **Src[3:0]:** Address register (for LOAD/STORE)
- **Dst[3:0]:** Data register

**Operations:**
```
Pure register indirect addressing:
01 000000 ssss dddd    LOAD  rd, [rs]      (rd = mem[rs])
01 000001 ssss dddd    STORE rd, [rs]      (mem[rs] = rd)

Data stack operations:
01 000010 xxxx dddd    PUSH  rd            (mem[sp] = rd; sp += 2)
01 000011 xxxx dddd    POP   rd            (sp -= 2; rd = mem[sp])

Constant stack operations (NEW):
01 000100 xxxx dddd    LDCS  rd            (rd = const_tos, non-destructive)
01 000101 xxxx xxxx    LDCSP               (pop const stack, discard TOS)

Control flow:
01 000110 xxxx xxxx    RET                 (return from subroutine)
01 000111 ssss xxxx    CALL  [rs]          (call subroutine at [rs])

Extended access:
01 001000 ssss dddd    LOADB rd, [rs]      (load byte, zero-extend)
01 001001 ssss dddd    STOREB rd, [rs]     (store byte)
```

**Addressing philosophy:** Pure register indirect only. For address offsets:
```assembly
LDC  0x100        ; Load base address from constant pool
LDCS r1           ; r1 = base address
ADDI r1, 10       ; r1 = base + 10
LOAD r0, [r1]     ; Load from array[10]
```

#### Family 2: J-Family (Jump/Branch + Load Constant)
**Opcode:** `10`

**Two sub-families distinguished by Mod[5]:**

**Branch Instructions (Mod[5] = 0):**
```
Format: 10 0cccoo oooooooo
- Condition[2:0]: Mod[4:2]
- Offset[11:0]: {Mod[4:0], Src[3:0], Dst[3:1]} (signed, ±2048 instructions)

10 0000oo oooooooo    JMP   offset        (unconditional)
10 0001oo oooooooo    JZ    offset        (jump if zero)
10 0010oo oooooooo    JNZ   offset        (jump if not zero)
10 0011oo oooooooo    JLT   offset        (signed <)
10 0100oo oooooooo    JGT   offset        (signed >)
10 0101oo oooooooo    JLE   offset        (signed ≤)
10 0110oo oooooooo    JGE   offset        (signed ≥)
10 0111oo oooooooo    JC    offset        (jump if carry)
```

**Load Constant (Mod[5] = 1):**
```
Format: 10 1iiiii iiii iiii
- const_id[12:0]: {Mod[4:0], Src[3:0], Dst[3:0]} = 13 bits = 8192 constants

10 1iiiii iiii iiii    LDC  const_id
```

**Operation flow:**
1. Fetch 16-bit value from SDRAM constant pool (0x900000 + const_id×2)
2. Push value onto SRAM constant stack
3. Update hardware TOS (Top-Of-Stack) register
4. Use LDCS instruction to copy TOS into any destination register

**Constant Stack Architecture:**
- **Hardware registers:**
  - `sp_const[15:0]` - Constant stack pointer
  - `const_tos[15:0]` - Top-of-stack register (always valid)
- **SRAM location:** 0x7F80-0x7FFF (128 bytes = 64 entries max)
- **Stack grows downward** from 0x7FFF

**Usage examples:**
```assembly
; Load single constant
LDC  0x123        ; Fetch from pool, push to stack, update TOS (~10 cycles)
LDCS r5           ; Copy TOS → r5 (~1 cycle)
LDCSP             ; Pop const stack (optional cleanup)

; Reuse same constant
LDC  0x456        ; Load once
LDCS r0           ; Copy to r0
LDCS r1           ; Copy to r1 (non-destructive, still in TOS!)
LDCS r2           ; Copy to r2
LDCSP             ; Discard when done

; Multiple constants
LDC  0x100        ; Load first
LDC  0x200        ; Load second (pushes 0x100 down stack)
LDCS r0           ; r0 = 0x200 (current TOS)
LDCSP             ; Discard
LDCS r1           ; r1 = 0x100 (new TOS)
LDCSP             ; Clean up
```

**Performance characteristics:**
- First LDC of a constant: ~10 cycles (SDRAM fetch)
- Repeated LDC: ~1 cycle (if still in TOS or SRAM stack)
- LDCS: ~1 cycle (register copy from TOS)
- LDCSP: ~1 cycle (pop operation)

**Why constant stack instead of direct register load?**
1. **Full 13-bit const_id** - No bits wasted on dst field in LDC
2. **Any destination register** - LDCS has full 4-bit dst field
3. **Explicit caching** - SRAM stack IS the cache, programmer controls it
4. **Multiple uses** - Load once, copy to many registers efficiently
5. **Non-destructive TOS** - Read repeatedly without reloading

#### Family 3: X-Family (Extended/Reserved)
**Opcode:** `11`

**Format:** `11 mmmmmm ssss dddd`

Fully reserved for future extensions (64 variants). Potential uses:
- Floating-point operations (FADD, FMUL, FSQRT)
- Graphics-specific ops (LERP, DOT3, CLAMP)
- SIMD/vector operations
- Hardware accelerators

**Phase 1 implementation:** Entire family unimplemented (reserved).

### Memory Layout Updates

#### SDRAM (32 MiB)
```
0x000000 - 0x17FFFF   Framebuffer 0 (1.5 MiB, 1024×768 RGB565)
0x180000 - 0x2FFFFF   Framebuffer 1 (1.5 MiB, double-buffer)
0x300000 - 0x33FFFF   Font Atlas (256 KiB)
0x340000 - 0x73FFFF   Texture Pages (4 MiB)
0x740000 - 0x8FFFFF   Z-buffer (1.75 MiB, optional)
0x900000 - 0x903FFF   Constant Pool (16 KiB, 8192×16-bit) ← NEW
0x904000 - 0x1FFFFFF  Vertex/Index Buffers (22.98 MiB)
```

#### SRAM (32 KiB)
```
0x0000 - 0x07FF   Line Buffer A (2 KiB, 1024×16-bit RGB565)
0x0800 - 0x0FFF   Line Buffer B (2 KiB, double-buffered)
0x1000 - 0x2FFF   Shader Register File (8 KiB, future multi-threading)
0x3000 - 0x4FFF   Texture/Glyph Cache (8 KiB)
0x5000 - 0x77FF   Scanline Work Buffer (10 KiB)
0x7800 - 0x7F7F   Data Stack (2 KiB, SP register)
0x7F80 - 0x7FFF   Constant Stack (128 bytes, SP_CONST register) ← NEW
```

### Design Rationale

**Why move from 8-bit to 16-bit?**
- Need to hold RGB565 pixels (16-bit) natively
- Better address range for memory operations
- Future SIMD operations benefit from wider registers
- Still fits comfortably in FPGA logic

**Why constant pool instead of immediate instructions?**
- **Fixed instruction size** - No MOVI/MOVHI complexity, easier debugging
- **SDRAM already proven** - Phase 0 validated SDRAM reliability
- **Larger constant range** - 8192 constants vs ~256 with inline immediates
- **Cache mitigates latency** - First access slow, subsequent fast
- **Cleaner ISA** - Fewer instruction variants, more orthogonal

**Why non-destructive TOS?**
- Common pattern: Load constant, use in multiple operations
- Without TOS register: Need to reload from SDRAM each time
- With TOS: LDCS copies instantly, no memory access
- Follows classic stack machine optimization (TOS caching)

**Why LDC in J-family instead of M-family?**
- Maximize const_id bits: 13 bits (8192 constants)
- M-family needs dst for data register
- J-family branches don't need dst, so more bits available
- 13 bits = 16 KiB constant pool (plenty for graphics applications)

### Dual-Core Architecture (Future)

**Core 0 (Main Processor):**
- General-purpose execution
- Full ISA access
- UART instruction input
- Coordinates rendering via Core 1

**Core 1 (Shader Processor):**
- Pixel processing
- Special register mappings:
  - `r1` = pixel_x (hardware-mapped, read-only)
  - `r2` = pixel_y (hardware-mapped, read-only)
  - `r0` = output color (hardware reads after RET)
- Invoked by rasterizer for each pixel
- RET instruction → implicit framebuffer write

**Programming model:**
```assembly
; Shader program (runs on Core 1)
shader_main:
    LDCS  r3           ; Load fg color from constant
    LDCS  r4           ; Load texture base address
    ADD   r4, r1       ; address = base + pixel_x
    LOAD  r0, [r4]     ; Sample texture
    AND   r0, r3       ; Modulate with color
    RET                ; Hardware writes r0 to framebuffer at (r1, r2)
```

### Next Implementation Steps

**Phase 1a: Migrate to 16-bit ISA**
1. Expand register file: 4 → 16 registers, 8-bit → 16-bit
2. Rewrite instruction decoder for new encoding
3. Implement constant pool initialization
4. Add constant stack hardware (sp_const, const_tos)
5. Update assembler (myasm.py) for new syntax

**Phase 1b: Dual-Core Foundation**
1. Replicate processor core (Core 0 + Core 1)
2. Add SDRAM arbiter for dual access
3. Implement shader register mappings (r1/r2 as pixel coords)
4. Add shader invocation FSM
5. Test with simple fill shader

**Phase 1c: Line-Buffered VGA**
1. Implement VGA timing generator (1024×768@60Hz)
2. Add line buffer scanout FSM
3. H-blank SDRAM fill mechanism
4. Double-buffer ping-pong
5. Test with static framebuffer pattern

### Success Metrics

**Phase 1a Complete:**
- ✅ 16-bit instructions execute correctly
- ✅ LDC loads from constant pool
- ✅ LDCS copies from TOS to any register
- ✅ Branch instructions work with 12-bit offset
- ✅ Constant stack push/pop functional

**Phase 1b Complete:**
- ✅ Dual cores execute independently
- ✅ SDRAM arbiter prevents conflicts
- ✅ Shader receives pixel coordinates in r1/r2
- ✅ Shader RET writes r0 to framebuffer
- ✅ Simple fill shader works

**Phase 1c Complete:**
- ✅ VGA displays 1024×768 image from SDRAM framebuffer
- ✅ Line buffer maintains 60Hz with dual ping-pong buffers
- ✅ No tearing or artifacts (stable diagonal test pattern)
- ✅ SDRAM arbiter successfully multiplexes VGA and processor access
- ✅ 256-word bursts with 2-cycle inter-block wait achieves 5:1 timing margin

## Design Philosophy

This project follows a **phase-gate approach**:
1. Each phase delivers standalone value
2. Can stop at any phase with working system
3. Each phase validates assumptions for next phase
4. Incremental complexity (text before graphics, fixed before programmable)

**Phase 0 validates:** Memory subsystem is foundation for everything. Debug once, use everywhere.

## Hardware Resources

### Phase 1b (VGA Output) - Actual Utilization

**Quartus Prime 24.1std.0 Compilation Report:**
```
Total logic elements:    1,443 / 6,272 (23%)
Total registers:         657
Total pins:              74 / 180 (41%)
Total memory bits:       16,384 / 276,480 (6%)
Total PLLs:              2 / 2 (100%)
```

**Breakdown:**
- SDRAM controller: ~800 LEs
- VGA timing generator: ~200 LEs
- VGA line buffer FSM: ~100 LEs
- UART RX: ~200 LEs
- Execution FSM: ~400 LEs
- Monitor FSM: ~100 LEs
- 7-segment display: ~300 LEs
- **Total**: 1,443 LEs (23% utilization)

**Memory Usage:**
- Line buffer (2KB × 8-bit): 16,384 bits (6% of Block RAM)
- PLLs: sys_pll (100MHz) + video_pll (65MHz) = 2/2 (100%)

**Remaining headroom:** 4,829 LEs (77%) available for shader pipeline, texture unit, and dual-core expansion.

## File Structure

```
src/
├── uart_to_display.v      # Top module (processor + SDRAM + VGA)
├── sdram_core.v           # SDRAM controller (from reference)
├── vga_controller.v       # VGA line buffer reader (NEW)
├── vga_timing.v           # VGA timing generator (NEW)
├── video_define.v         # Video resolution defines (NEW)
├── uart_rx.v              # UART receiver
├── uart_tx.v              # UART transmitter (unused)
├── seg_scan.v             # 7-segment multiplexer
├── seg_decoder.v          # Hex to 7-segment decoder
├── myasm.py               # Assembler + serial transmitter
├── test_stack.txt         # Test program
└── ip_core/
    ├── sys_pll.qip        # PLL: 50MHz → 100MHz
    ├── video_pll.v        # PLL: 50MHz → 65MHz (NEW)
    └── video_pll_bb.v     # Black box for video_pll (NEW)

seg_test.qsf               # Quartus project settings (VGA pins added)
uart_to_display.sdc        # Timing constraints
README.md                  # User documentation
CLAUDE.md                  # This file (technical notes)
```

## Key Insights

1. **SDRAM clock is non-negotiable**: The SDRAM chip needs an external clock. No clock = no memory operations = no refresh = data loss.

2. **Refresh happens automatically**: The sdram_core controller has built-in refresh logic. It just needs to return to S_IDLE state periodically. UART provides natural gaps (~87μs between instructions) for refresh to occur.

3. **16-bit native access is simpler**: Fighting the hardware with byte wrappers adds complexity. Embrace the 16-bit width and let the processor work with words.

4. **State machine clarity matters**: Separate states for initialization, fetch, and memory operations makes debugging much easier. Don't try to multiplex everything into one state.

5. **Independent monitoring is powerful**: A separate FSM that reads memory periodically (without interfering with main execution) provides invaluable debugging visibility.

6. **VGA requires stable pixel clock**: The 65MHz pixel clock from video_pll must be rock-solid. Any jitter or frequency drift causes visible artifacts. Using proven PLL configuration from reference design avoids timing issues.

7. **Line buffer simplifies VGA**: Decoupling display scanout from rendering via a line buffer eliminates real-time constraints. VGA always reads from SRAM at 65MHz, processor writes opportunistically at 100MHz. No tearing, no timing violations.

8. **RGB565 is FPGA-friendly**: 16-bit color fits perfectly in Block RAM width and SDRAM data bus. Saves 33% bandwidth vs RGB888 with minimal visual quality loss. Natural fit for hardware.

## Reference Designs

### SDRAM Controller
Based on `sdram_vga_ref/src/sdram/sdram_core.v` from ALINX examples:
- T_RP=4, T_RC=6, T_MRD=6, T_RCD=2, T_WR=3, CAS=3
- 7.5μs refresh period (8192 rows / 64ms)
- Burst mode with automatic refresh
- Mode Register: burst length = full page (0x111)

### VGA Timing
Based on `sdram_vga_ref/src/vga/color_bar.v` from ALINX examples:
- 1024×768@60Hz (VESA standard)
- H_TOTAL=1344, V_TOTAL=806
- H_SYNC=136, V_SYNC=6 (negative polarity)
- Pixel clock: 65.000 MHz (50MHz × 13/10 via video_pll)

## Success Metrics

**Phase 0 Complete (16-bit ISA):**
- ✅ Display static image from SDRAM? → Monitor shows 0xCC
- ✅ PUSH/POP working? → test_stack shows correct results
- ✅ Refresh working? → Memory retains data over time
- ✅ Can execute programs? → UART input → execution → display

**Phase 1b Complete (VGA Output):**
- ✅ VGA displays 1024×768 @ 60Hz? → Yes, stable sync
- ✅ Line buffer reads from SRAM? → Yes, test pattern visible
- ✅ Color bars correct? → Yes, 8 distinct colors (R/G/B/Y/C/M/W/K)
- ✅ Dual clock domains working? → Yes, no timing violations
- ✅ Resource budget OK? → Yes, 23% logic, 6% memory, plenty of headroom

**Visual debugging unlocked!** 🎉

## Phase 1c: SDRAM Framebuffer Architecture (Current)

### Key Learnings

**SDRAM Controller Constraints (H57V2562):**
- 4 banks × 8192 rows × 512 columns × 16 bits
- Page size: **512 words maximum** (not 1024!)
- Burst modes: 1, 2, 4, 8, or full page (512)
- Must use full-page + early termination for variable lengths
- `rd_burst_len` must be ≤ 512 or burst won't complete

**Line Buffer Refactoring:**
- Moved dual 2KB line buffers inside `vga_controller.v`
- Simplified interface: only SDRAM burst signals exposed
- Automatic ping-pong: write to opposite buffer from scanout
- Rule: `vga_buf_sel = active_y[0]`, `wr_buf_sel = next_line_y[0]`
- Eliminated external SRAM interface (7 signals removed)

**Current Architecture:**
- 1024 pixels/line requires 8 × 128-word bursts (1024/128=8)
- Each burst: REQ → GRANT → BURST (128 words) → DONE
- Line fill loop: blocks 0-7, then mark buffer ready
- Buffer ready flag prevents underrun during scanout

### Underrun Analysis

**Symptoms:**
- Flickering display, mostly showing underrun pattern
- Framebuffer content visible but unstable
- Pattern location stable (proves SDRAM reads work)

**Timing Budget (per line):**
- Scanline period: 20.67 μs (1344 pixels @ 65MHz)
- Available for fill: ~20.67 μs (starts when new line begins)
- Required: 8 bursts × 128 words = 1024 words total
- SDRAM burst time: ~1 μs per 128-word burst @ 100MHz
- Total: 8 μs of SDRAM transfer + arbiter overhead

**Potential Causes:**

1. **Arbiter Latency:**
   - FSM: IDLE → REQ → (wait for grant) → BURST → DONE
   - 8 iterations = 8× grant latency
   - If each grant takes >1.5 μs, won't finish in time

2. **SDRAM Controller Efficiency:**
   - Page-mode optimization assumes sequential access
   - Row activations add cycles if crossing rows
   - 128-word bursts may not fully utilize page mode
   - Possible page misses between bursts

3. **Clock Domain Crossing:**
   - `line_start` detection: 65MHz → 100MHz
   - May miss trigger or add latency
   - `active_x1 < active_x0` wrap detection

4. **Buffer Ready Synchronization:**
   - `buffer_ready` set at 100MHz
   - Read at 65MHz (2-stage sync missing in user's code)
   - May see stale value → premature underrun

5. **Burst Restart Overhead:**
   - Each of 8 bursts requires: deassert req, request again, wait grant
   - `block_idx` loop adds FSM state transitions
   - Could pipeline: keep `sdram_line_req` high across bursts?

**Measured vs Expected:**
- Expected: 8 μs SDRAM + 8× arbiter = ~10-12 μs (fits in 20.67 μs)
- Actual: Frequent underruns suggest >20 μs
- **Hypothesis:** SDRAM controller inefficiency or arbiter starvation

### Resolution: Fully Working! ✅

**Final Configuration:**
- **Block size:** 256 words per burst (4 blocks × 256 = 1024 pixels/line)
- **Inter-block wait:** 2 cycles between burst requests
- **Key fixes:**
  1. Added `else` clause to CDC synchronizer for proper line_start clearing
  2. Implemented 2-cycle wait (`block_wait`) between SDRAM burst requests
  3. Fixed off-by-one in framebuffer init (used full `fb_init_counter[19:0]` instead of `[18:0]`)
  4. Corrected loop termination: `block_idx < BLK_COUNT - 1` to prevent extra block request

**Lessons Learned:**
1. **Arbiter back-pressure:** SDRAM controller needs time between back-to-back burst requests. A 2-cycle wait prevents request collision/denial.
2. **Diagonal pattern math:** For true 45° diagonal on 1024×768 (4:3 aspect), use: `pixel_y * 4 + pixel_x * 3 < 13'd3072` (accounts for aspect ratio scaling).
3. **Bit-width for overflow:** Sum requires 13 bits (max: 767×4 + 1023×3 = 6137).
4. **SignalTap debugging:** Essential for identifying rapid FSM state transitions that indicated missing wait states.

**Performance:**
- Line fill time: ~3-4 μs for 1024 pixels (4 bursts × 256 words @ 100MHz)
- Available time: 20.67 μs per scanline
- Margin: ~5:1 safety factor ✓

Next: Enable processor to write to framebuffer → test LOAD/STORE instructions

### VGA Controller Timing & Synchronization Design

This section documents the clock domain crossing (CDC) strategy and timing analysis for `vga_controller.v`. The design handles dual-clock operation (65MHz VGA, 100MHz SDRAM) with careful attention to synchronization and buffer management.

#### VGA Timing Counter Convention

**Non-standard counter phase:** The `vga_timing.v` module uses a counter that **starts at 0 during front porch**, not during active video. This differs from VESA standard but simplifies vertical counter updates.

```
h_cnt:  0        24      160             320            1344
        ├─ H_FP ─┤─SYNC─┤─── H_BP ────┤─── ACTIVE ────┤
        0-23     24-159  160-319        320-1343
```

**Key timing event (line 104 in vga_timing.v):**
```verilog
if((v_cnt >= V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))
    active_y_reg <= v_cnt - (V_FP + V_SYNC + V_BP - 1);
```

This means `active_y` updates at **h_cnt = 23** (last cycle of front porch), giving exactly **24 cycles of stable time** during H_FP (h_cnt 0-22) before the update occurs.

#### Clock Domain Crossing Strategy

**The Multi-bit CDC Challenge:**

Standard CDC guidelines prohibit crossing multi-bit buses (like `fill_y_vga[11:0]`) without Gray coding or handshaking, assuming rapidly changing signals. However, this design exploits **quasi-static signal behavior**:

**VGA domain (65MHz):**
```verilog
// During blanking after line N completes (h_cnt 0-22, before active_y updates)
if (wr_buf_sel_vga_once) begin
    fill_y_vga <= active_y + 12'd2;      // Update line number to fill
    wr_buf_sel_vga <= vga_buf_sel;       // Update buffer select
    wr_buf_sel_vga_once <= 0;
end
```

Both signals (`fill_y_vga` and `wr_buf_sel_vga`) update **simultaneously** in the same clock cycle, then remain **stable for H_TOTAL = 1344 cycles (20.67 μs)**.

**SDRAM domain (100MHz):**
```verilog
// 2-stage synchronizer for single-bit signal
wr_buf_sel_sync1 <= wr_buf_sel_vga;
wr_buf_sel <= wr_buf_sel_sync1;
wr_buf_sel_prev <= wr_buf_sel;

// Edge detection triggers sample of multi-bit bus
if (wr_buf_sel != wr_buf_sel_prev && !line_start) begin
    fill_y <= fill_y_vga;  // Sample 12-bit bus directly
    line_start <= 1;       // Pulse for 1 cycle
end
```

**Why this is safe:**

| Parameter | Value | Analysis |
|-----------|-------|----------|
| Signal update rate | Once per H_TOTAL | 20.67 μs between changes |
| Synchronizer delay | 2 cycles @ 100MHz | ~20 ns |
| Setup margin | 20.67 μs - 20 ns | **20.65 μs** (1033:1 ratio!) |
| Multi-bit settling | All 12 bits simultaneous | Single VGA clock edge |
| Sample timing | After 2-stage sync | Guaranteed stable |

Even accounting for:
- Clock domain jitter (±100 ps typical)
- Routing delay variations (1-5 ns)
- Multi-bit bus skew (sub-ns on FPGA fabric)

The **1000+ cycle margin** ensures all 12 bits are sampled from the **same stable value**. The slow update rate (H_TOTAL period) makes this effectively a quasi-static signal from the SDRAM domain's perspective.

**Contrast with true CDC violations:**
- ❌ Rapid changes (every few cycles): Bits sampled from different values
- ❌ Async handshake: No timing relationship, metastability risk
- ✅ This design: Single-bit synchronized toggle + 20 μs stable window

#### Buffer Swap Timing Window

**The 24-cycle H_FP window:**

The front porch (h_cnt 0-22) provides the **only safe window** to update buffer assignments based on `active_y`:

```
Cycle N:   de=1, active_x=1023, active_y=N (last active pixel)
Cycle N+1: de=0, active_x=0, active_y=N (blanking starts, H_FP begins)
           ↓ wr_buf_sel_vga_once triggers update
           fill_y_vga <= N + 2
           wr_buf_sel_vga <= N[0]

h_cnt 0-22: active_y still = N (stable for calculations)
h_cnt 23:   active_y updates to N+1 (too late to use safely)
```

**Why the "once" flag is necessary:**

Without the flag, the update logic would execute on **every blanking cycle**, including h_cnt ≥ 23 when `active_y` has already incremented. The flag ensures:
1. Set during active display (de=1)
2. Triggers update on first blanking cycle (de=0, h_cnt=0)
3. Cleared immediately to prevent re-execution

This guarantees the update happens **before h_cnt=23** when `active_y` is still stable at value N.

#### Dual Buffer Pipeline

**Buffer assignment logic:**

```
Line N displaying:  vga_buf_sel = N[0]        (buffer being scanned out)
Buffer being filled: wr_buf_sel = N[0]         (buffer we just finished displaying)
Line being filled:   fill_y = N + 2           (next-next line)

Example timeline:
  Line 0 displays from buffer A (0[0]=0)
  → Fill buffer A for line 2 (2[0]=0) ← Same buffer!

  Line 1 displays from buffer B (1[0]=1)
  → Fill buffer B for line 3 (3[0]=1) ← Same buffer!
```

**No conflict because:**
- Line N displays from buffer N[0]
- Simultaneously fills buffer N[0] for line N+2
- Different addresses within same buffer (dual-port SRAM)
- **Timing constraint**: Must complete fill within 1 full scanline period (20.67 μs) before line N+2 displays

**Available fill time:**
```
Start: h_cnt=0 of line N (front porch begins)
Deadline: h_cnt=0 of line N+2 (2 × 20.67 μs = 41.34 μs)
Required: 8 × 128-word bursts ≈ 8-10 μs (with arbiter overhead)
Margin: 31+ μs (3:1 safety factor)
```

#### Line Start Detection (Edge-Based Synchronization)

**Synchronizer behavior:**

The synchronization logic **pauses** when `line_start` pulses high:

```verilog
if (!line_start) begin
    // Synchronizer runs continuously
    wr_buf_sel_sync1 <= wr_buf_sel_vga;
    wr_buf_sel <= wr_buf_sel_sync1;
    wr_buf_sel_prev <= wr_buf_sel;
    if (wr_buf_sel != wr_buf_sel_prev) begin
        fill_y <= fill_y_vga;
        line_start <= 1;  // Pulse high
    end
end else begin
    line_start <= 0;  // Clear on next cycle
end
```

**Timeline:**
```
Cycle 0: line_start=0, sync runs, detects edge → line_start=1
Cycle 1: line_start=1, sync pauses (if block false), line_start=0 (else)
Cycle 2: line_start=0, sync resumes
```

**Why this works:**
- `line_start` pulses for exactly **1 cycle** (by design)
- Receiver FSM (fill_state machine) operates on **same clock domain** (100MHz)
- Cannot miss the pulse (both in clk_sys domain)
- Source signal (`wr_buf_sel_vga`) changes slowly (once per 20 μs), so pausing sync for 1 cycle doesn't lose edges

**Unusual but valid design pattern:** Typically synchronizers run continuously and edge detection is separate. This combines them, which works because:
1. Source changes infrequently (once per H_TOTAL)
2. Receiver is synchronous to sampled signal
3. 1-cycle pause doesn't affect slow source

#### Formal CDC Compliance (Optional)

If timing analysis tools flag the `fill_y_vga` → `fill_y` path as unconstrained CDC:

**Option 1: False path constraint** (recommended)
```tcl
# In uart_to_display.sdc
set_false_path -from [get_registers {*fill_y_vga[*]}] -to [get_registers {*fill_y[*]}]
```
Rationale: Actual timing controlled by synchronized `wr_buf_sel` edge, not raw `fill_y_vga` path.

**Option 2: Relaxed timing constraint**
```tcl
set_max_delay -from [get_registers {*fill_y_vga[*]}] -to [get_registers {*fill_y[*]}] 20000
# 20 μs >> any realistic routing delay
```

**Option 3: No action required** if synthesis completes without violations. The massive setup margin means tools likely won't flag it as timing-critical.

#### Design Validation

**Verified properties:**
1. ✅ Multi-bit CDC safe due to quasi-static behavior (1000:1 margin)
2. ✅ Buffer swap occurs during H_FP before active_y updates
3. ✅ Dual-port SRAM allows simultaneous read (VGA) + write (SDRAM)
4. ✅ 1-cycle line_start pulse cannot be missed (same clock domain)
5. ✅ Fill completes within scanline budget (10 μs fill, 20 μs available)

**Common pitfalls avoided:**
- ❌ Sampling `active_y` after h_cnt=23 (would get N+1 instead of N)
- ❌ Synchronizing `fill_y_vga` through 2-stage sync (unnecessary latency)
- ❌ Using same buffer for read+write at same address (dual-port prevents conflict)
- ❌ Assuming VESA counter convention (code uses phase-shifted convention)
