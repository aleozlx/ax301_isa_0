# 16-bit ISA Refactoring Complete

## Summary

Successfully refactored the processor from 8-bit to 16-bit ISA while keeping the same 5 instructions from Phase 0. No new instructions were added - only the encoding and register width changed.

## What Changed

### Hardware (uart_to_display.v)

1. **Register file:** `reg [7:0] registers [0:3]` → `reg [15:0] registers [0:15]`
   - Expanded from 4×8-bit to 16×16-bit registers
   - r3 still serves as display register

2. **Instruction reception:** 8-bit single byte → 16-bit two bytes
   - Added `inst_byte_high` and `inst_byte_valid` for 2-byte assembly
   - UART receives high byte first, then low byte
   - Instruction assembled as `{inst_byte_high, rx_data}`

3. **Instruction decoder:** New 16-bit format `[Op:2][Mod:6][Src:4][Dst:4]`
   - Opcode (2 bits): Instruction family
   - Mod (6 bits): Operation variant within family
   - Src (4 bits): Source register or immediate
   - Dst (4 bits): Destination register

4. **SDRAM operations:** Already 16-bit native
   - PUSH: Writes full 16-bit register value
   - POP: Reads full 16-bit value into register
   - Stack pointer still word-aligned (increments by 2)

5. **Display:** Updated for 16-bit r3 register
   - Shows 4 hex digits (r3[15:12], r3[11:8], r3[7:4], r3[3:0])
   - Monitor shows lower 2 digits of SDRAM 0x900000
   - Layout: `[r3_3][r3_2][r3_1][r3_0][mon_1][mon_0]`

### Software (myasm.py)

1. **Encoding:** 8-bit → 16-bit instructions
   - Generates 16-bit instruction words
   - Sends as 2 bytes: high byte first, then low byte

2. **Register range:** r0-r3 → r0-r15
   - Parses register numbers from r0 to r15
   - Validates register numbers ≤ 15

3. **Instruction mapping:**
```
Old 8-bit                  New 16-bit encoding
───────────────────────   ─────────────────────────────────────
MOVI rx, imm4             00 010000 iiii dddd  (ADDI encoding)
MOV  rx, ry               00 000000 ssss dddd  (R-family MOV)
ADD  rx, ry               00 000001 ssss dddd  (R-family ADD)
PUSH rx                   01 000010 0000 dddd  (M-family PUSH)
POP  rx                   01 000011 0000 dddd  (M-family POP)
```

## Instruction Encodings

### MOVI r0-r15, imm4
**Binary:** `00 010000 iiii dddd`
- Op: 00 (R-family)
- Mod: 010000 (ADDI variant)
- Src: imm4 (4-bit immediate value)
- Dst: register number (0-15)
- **Semantics:** `rd = {12'b0, imm4}` (zero-extended to 16 bits)

### MOV rd, rs
**Binary:** `00 000000 ssss dddd`
- Op: 00 (R-family)
- Mod: 000000 (MOV variant)
- Src: source register (0-15)
- Dst: destination register (0-15)
- **Semantics:** `rd = rs`

### ADD rd, rs
**Binary:** `00 000001 ssss dddd`
- Op: 00 (R-family)
- Mod: 000001 (ADD variant)
- Src: source register (0-15)
- Dst: destination register (0-15)
- **Semantics:** `rd = rd + rs`

### PUSH rd
**Binary:** `01 000010 0000 dddd`
- Op: 01 (M-family)
- Mod: 000010 (PUSH variant)
- Src: 0000 (unused)
- Dst: register to push (0-15)
- **Semantics:** `mem[sp] = rd; sp += 2`

### POP rd
**Binary:** `01 000011 0000 dddd`
- Op: 01 (M-family)
- Mod: 000011 (POP variant)
- Src: 0000 (unused)
- Dst: destination register (0-15)
- **Semantics:** `sp -= 2; rd = mem[sp]`

## Test Program

Created `test_16bit.txt` with three tests:

1. **Basic PUSH/POP:** Verify 16-bit stack operations work
2. **Multiple values:** Test LIFO order with PUSH/POP
3. **Wide registers:** Test r4, r5 (beyond old r0-r3 range)

Expected display sequence:
- Initial: `cccc cc` (monitor shows 0xCCCC from init)
- After test 1: `0005 cc` (r3 = 5)
- After test 2: `000c cc` (r3 = 12 = 3+9)
- After test 3: `001e cc` (r3 = 30 = 15+15)

## How to Test

1. **Compile in Quartus:**
   ```
   Open seg_test.qpf
   Processing → Start Compilation
   ```

2. **Program FPGA:**
   ```
   Tools → Programmer
   Start programming
   ```

3. **Run test program:**
   ```bash
   python src/myasm.py src/test_16bit.txt COM3
   ```

4. **Observe 7-segment display:**
   - Should show sequence: `cccc cc` → `0005 cc` → `000c cc` → `001e cc`

## What Didn't Change

- SDRAM controller (already 16-bit native)
- Monitor FSM (updated to store 16-bit, but logic unchanged)
- PLL and clock domains
- UART baud rate (115200)
- Stack pointer addressing (still 24-bit, word-aligned)
- Display timing (50MHz scan, 100MHz execution)

## Backwards Compatibility

**None.** The old 8-bit assembler and test programs are incompatible with the new 16-bit ISA. All programs must be reassembled with the new `myasm.py`.

## Next Steps (Future)

This refactoring sets the foundation for:
- **LDC/LDCS instructions:** Constant pool loading (Phase 1a)
- **Branch instructions:** JMP, JZ, JNZ with 12-bit offset (Phase 1a)
- **More ALU ops:** SUB, XOR, SHL, etc. (Phase 1a)
- **Dual-core architecture:** Main + Shader processors (Phase 1b)
- **VGA line buffering:** Display from SDRAM framebuffer (Phase 1c)

## File Changes

**Modified:**
- `src/uart_to_display.v` - Processor core refactored to 16-bit
- `src/myasm.py` - Assembler updated for 16-bit encoding

**Created:**
- `src/test_16bit.txt` - Test program for 16-bit ISA
- `REFACTOR_16BIT.md` - This document

**Unchanged:**
- `src/sdram_core.v`
- `src/uart_rx.v`
- `src/seg_scan.v`
- `src/seg_decoder.v`
- `seg_test.qsf`
- All IP cores

## Design Notes

### Why MOVI uses ADDI encoding?

MOVI loads a small 4-bit immediate. In the new ISA, we use the ADDI encoding (00 010000 iiii dddd) where the immediate goes in the Src field. This is semantically equivalent to `rd = 0 + imm4`, which matches the old MOVI behavior.

### Why 2-byte instruction reception?

UART delivers one byte at a time. To assemble 16-bit instructions, we:
1. Receive first byte → store in `inst_byte_high`
2. Set `inst_byte_valid` flag
3. Receive second byte → assemble as `{inst_byte_high, rx_data}`
4. Decode and execute
5. Clear `inst_byte_valid` for next instruction

This doubles the UART reception time per instruction (~170μs → ~340μs), but execution is still fast (<1μs for ALU ops, ~10μs for SDRAM).

### Why display shows "cccc cc" initially?

The SDRAM initialization writes 0xCCCC to location 0x900000. After init, the processor reads this back and displays it in r3, confirming SDRAM is working. The monitor independently reads 0x900000 every 750μs, showing the lower 2 digits (cc).

## Success Criteria

✅ Processor refactored to 16-bit registers and instructions
✅ Only existing 5 instructions implemented (no ISA bloat)
✅ Assembler generates correct 16-bit encoding
✅ Test program created with 3 test cases
✅ Display updated to show full 16-bit values
✅ Ready for Phase 1a feature additions
