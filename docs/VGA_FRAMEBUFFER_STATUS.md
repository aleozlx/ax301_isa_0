# VGA Framebuffer Implementation Status

## ✅ COMPLETE - Phase 1c: SDRAM Framebuffer Scanout

### Final Architecture

**VGA Controller**: Fully functional line-buffered display from SDRAM framebuffer
- **Resolution**: 1024×768@60Hz (VESA standard)
- **Pixel format**: RGB565 (16-bit per pixel)
- **Framebuffer location**: SDRAM 0x000000-0x17FFFF (1.5 MiB)
- **Line buffers**: Dual 2KB SRAM buffers (internal to vga_controller.v)
- **Burst configuration**: 4 blocks × 256 words per scanline
- **Inter-block wait**: 2 cycles (prevents arbiter collision)

### Verified Working ✅

1. **VGA Timing Generator** (`vga_timing.v`)
   - 1024×768@60Hz with 65MHz pixel clock
   - Stable H/V sync (negative polarity)
   - Non-standard counter convention (starts at front porch)
   - `active_y` updates at h_cnt=23 (provides 24-cycle H_FP window)

2. **Dual Line Buffers** (`vga_controller.v` lines 72-73)
   - Buffer A: 1024×16-bit RGB565
   - Buffer B: 1024×16-bit RGB565
   - Ping-pong architecture: `vga_buf_sel = active_y[0]`
   - Dual-port inference confirmed (M10K Block RAM)

3. **SDRAM Line Fill FSM** (`vga_controller.v` lines 144-261)
   - Fills line N+2 while displaying line N
   - 4 bursts × 256 words = 1024 pixels/line
   - 2-cycle wait between bursts (critical for arbiter)
   - Completes in ~3-4 μs (5:1 margin vs 20.67 μs deadline)

4. **Clock Domain Crossing** (65MHz VGA ↔ 100MHz SDRAM)
   - Quasi-static CDC: signals stable for 20.67 μs (1000+ cycle margin)
   - Single-bit `wr_buf_sel_vga` synchronized via 2-stage FF
   - Multi-bit `fill_y_vga[11:0]` sampled when synchronized edge detected
   - Formal CDC compliance via quasi-static stability

5. **SDRAM Arbiter** (`uart_to_display.v` lines 152-185)
   - Priority: VGA (hard deadline) > Processor > Monitor
   - VGA line requests granted when processor idle
   - 256-word bursts (fits SDRAM page size ≤ 512)
   - `rd_burst_len = 10'd256` per burst

6. **Framebuffer Initialization** (`uart_to_display.v` lines 301-342)
   - Diagonal test pattern (45° compensated for 4:3 aspect)
   - Formula: `pixel_y * 4 + pixel_x * 3 < 13'd3072`
   - Full 20-bit addressing (`fb_init_counter[19:0]`)
   - Checkerboard pattern in diagonal regions

### Key Fixes Applied

1. **CDC Synchronizer** (line 192 in vga_controller.v)
   - Added `else` clause to properly clear `line_start` pulse
   - Prevents synchronizer from hanging after edge detection

2. **Inter-Block Wait** (lines 188, 215-216)
   - Added `block_wait` counter (2 cycles)
   - Prevents rapid-fire burst requests that arbiter denies
   - SignalTap revealed FSM was cycling FILL_REQ→FILL_BURST→FILL_IDLE in 1 cycle without wait

3. **Framebuffer Init Range** (line 310)
   - Changed from `fb_init_counter[18:0]` to `fb_init_counter[19:0]`
   - Fixed: only first 512 lines were initialized (last 256 showed garbage)

4. **Loop Termination** (line 253)
   - Condition: `block_idx < BLK_COUNT - 1` (for BLK_COUNT=4, stops at block 3)
   - Prevents spurious "block 4" request that would overwrite buffer

### Performance Metrics

**Timing:**
- Line fill: 3-4 μs (4 bursts + overhead)
- Available: 20.67 μs (H_TOTAL period)
- Margin: ~5:1 safety factor ✓

**Resource Usage:**
- Logic Elements: ~1,500 / 6,272 (24%)
- M10K Blocks: 4KB line buffers (dual-port)
- PLLs: sys_pll (100MHz) + video_pll (65MHz)

### Debug Tools Used

1. **SignalTap Logic Analyzer**
   - Identified rapid FSM transitions (missing wait states)
   - Verified `block_idx` increments correctly
   - Confirmed `wr_addr` sequential writes to line buffer

2. **7-Segment Display**
   - Shows r3 register (SDRAM init verification)
   - Confirmed 0xA301 pattern during startup

3. **Test Patterns**
   - Diagonal split (aspect-corrected 45°)
   - Checkerboard regions (XOR pattern)
   - Validates SDRAM address calculation

### Files Modified

1. `src/vga_controller.v` - Complete rewrite
   - Removed debug outputs (`debug_buffer_ready`, `debug_fill_state`)
   - Added inter-block wait mechanism
   - Fixed CDC synchronizer with proper `else` clause

2. `src/uart_to_display.v` - Updated
   - Removed debug wire declarations
   - Removed commented debug display code
   - Fixed framebuffer init to use full 20-bit counter

3. `CLAUDE.md` - Documentation
   - Added "Resolution: Fully Working" section
   - Documented lessons learned (arbiter back-pressure, diagonal math)
   - Updated Phase 1c success metrics

### Lessons Learned

1. **Arbiter Back-Pressure**
   - SDRAM controller needs recovery time between burst requests
   - 2-cycle wait prevents request denial/collision
   - Without wait: arbiter grants but immediately de-asserts (1-cycle glitch)
   - ![Signal tap arbiter pressure](signal_tap_vga_blocks.png)

2. **Diagonal Pattern Math**
   - For 45° on 1024×768 (4:3 aspect): scale Y by 4/3
   - Equation: `Y×4 + X×3 < 3072` (line from (0,767) to (1023,0))
   - Requires 13-bit sum (max: 767×4 + 1023×3 = 6137)

3. **CDC for Slow Signals**
   - Traditional multi-bit CDC (Gray code, handshake) unnecessary
   - If signal stable for 1000+ cycles, quasi-static CDC is valid
   - 20 μs stability >> 20 ns sync delay = 1000:1 margin

4. **SignalTap Essential**
   - Software simulation misses timing-dependent bugs
   - Real hardware trace revealed 1-cycle FSM glitches
   - Worth the compile time increase for critical debug

## Next Phase: Processor Framebuffer Access

### TODO: LOAD/STORE Instructions

**Status**: Not yet implemented

**Design**:
```verilog
M-family (opcode 01):
LOAD  rd, [rs]      # 01 000000 ssss dddd  (rd = mem[rs])
STORE rd, [rs]      # 01 000001 ssss dddd  (mem[rs] = rd)
```

**Implementation Steps**:
1. Add `EXEC_LOAD_WAIT` and `EXEC_STORE_WAIT` states
2. Decode mod=000000 (LOAD) and mod=000001 (STORE) in M-family
3. Use existing `rd_burst_req_main` / `wr_burst_req` for arbiter
4. Handle 24-bit addressing (registers hold addresses)

### TODO: Assembler Update

**File**: `src/myasm.py`

Add LOAD/STORE encoding:
```python
elif op == 'LOAD':
    # LOAD rd, [rs] -> [01][000000][src:4][dst:4]
    instruction = (0b01 << 14) | (0b000000 << 8) | (src << 4) | dst

elif op == 'STORE':
    # STORE rd, [rs] -> [01][000001][src:4][dst:4]
    instruction = (0b01 << 14) | (0b000001 << 8) | (src << 4) | dst
```

### TODO: Test Program

**File**: `src/test_framebuffer.txt` (to be created)

Example: Draw red pixel at (100, 100)
```assembly
# Load framebuffer base (0x180000 for FB1)
LDC  #FB1_BASE_H    # Load high word
LDCS r0
LDC  #FB1_BASE_L    # Load low word (if needed for 24-bit)

# Calculate offset: y*1024 + x (for pixel (x,y))
# addr = 0x180000 + (100*1024) + 100 = 0x180000 + 102500 = 0x199044

# For now: hard-code address in constant pool
LDC  #PIXEL_ADDR
LDCS r1             # r1 = address

# Load color (red = 0xF800 in RGB565)
LDC  #COLOR_RED
LDCS r2             # r2 = 0xF800

# Write to framebuffer
STORE r2, [r1]      # Write red pixel

# Set frame_ready flag (future: via special register write)
```

### Critical Considerations

1. **Address Calculation**
   - Current ISA lacks multiply/large shifts
   - Options: Add SHLI instruction, use lookup table, or hard-code addresses for testing

2. **Double-Buffer Management**
   - Processor writes to `back_buffer` (FB1 initially)
   - Set `frame_ready=1` to trigger swap on vsync
   - Need special register write or dedicated instruction

3. **Arbiter Priority**
   - VGA has hard deadline (must not underrun)
   - Processor LOAD/STORE can stall (acceptable)
   - Current arbiter already handles this correctly

## Compilation Status

**✅ COMPILES SUCCESSFULLY** (with debug outputs removed)

**✅ HARDWARE VERIFIED** (diagonal test pattern displays correctly)

**Ready for**:
- Processor LOAD/STORE implementation
- Dynamic framebuffer updates
- Interactive graphics programming

## Design Decisions Summary

- **RGB565 over RGB888**: 33% bandwidth savings, native SDRAM width
- **Dual line buffers**: Ping-pong eliminates arbitration contention
- **256-word bursts**: Fits SDRAM page (≤512), reduces overhead
- **2-cycle inter-block wait**: Prevents arbiter collision
- **Quasi-static CDC**: Exploits 20 μs stability for safe multi-bit crossing
- **Front/back swap on vsync**: Atomic, tearing-free updates
- **Processor writes to back buffer**: No VGA path interference
