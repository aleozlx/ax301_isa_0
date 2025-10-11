import serial
import sys
import time

# 16-bit ISA Instruction encoding
# Format: [Op:2][Mod:6][Src:4][Dst:4]

def assemble_line(line):
    """Convert one assembly line to 16-bit instruction"""
    line = line.strip().upper()

    # Skip empty lines and comments
    if not line or line.startswith('#') or line.startswith(';'):
        return None

    parts = line.replace(',', ' ').split()
    op = parts[0]

    if op == 'MOV':
        # MOV rX, rY -> [00][000000][src:4][dst:4]
        dst_str = parts[1][1:]
        src_str = parts[2][1:]
        dst = int(dst_str)
        src = int(src_str)
        if dst > 15 or src > 15:
            raise ValueError(f"Invalid MOV: dst={dst}, src={src}")

        opcode = 0b00
        mod = 0b000000  # MOV encoding

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    elif op == 'ADD':
        # ADD rX, rY -> [00][000001][src:4][dst:4]
        dst_str = parts[1][1:]
        src_str = parts[2][1:]
        dst = int(dst_str)
        src = int(src_str)
        if dst > 15 or src > 15:
            raise ValueError(f"Invalid ADD: dst={dst}, src={src}")

        opcode = 0b00
        mod = 0b000001  # ADD encoding

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    elif op == 'XOR':
        # XOR rX, rY -> [00][000101][src:4][dst:4]
        dst_str = parts[1][1:]
        src_str = parts[2][1:]
        dst = int(dst_str)
        src = int(src_str)
        if dst > 15 or src > 15:
            raise ValueError(f"Invalid XOR: dst={dst}, src={src}")

        opcode = 0b00
        mod = 0b000101  # XOR encoding

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    elif op == 'ADDI':
        # ADDI rX, imm4 -> [00][010000][imm4:4][dst:4]
        dst_str = parts[1][1:]
        dst = int(dst_str)
        imm = int(parts[2], 0)  # Support 0x hex or decimal
        if dst > 15 or imm > 15:
            raise ValueError(f"Invalid ADDI: dst={dst}, imm={imm}")

        opcode = 0b00
        mod = 0b010000  # ADDI encoding
        src = imm       # Immediate in src field

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    elif op == 'PUSH':
        # PUSH rX -> [01][000010][0000][dst:4]
        reg_str = parts[1][1:]
        reg = int(reg_str)
        if reg > 15:
            raise ValueError(f"Invalid PUSH: reg={reg}")

        opcode = 0b01
        mod = 0b000010  # PUSH encoding
        src = 0b0000    # Unused
        dst = reg

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    elif op == 'POP':
        # POP rX -> [01][000011][0000][dst:4]
        reg_str = parts[1][1:]
        reg = int(reg_str)
        if reg > 15:
            raise ValueError(f"Invalid POP: reg={reg}")

        opcode = 0b01
        mod = 0b000011  # POP encoding
        src = 0b0000    # Unused
        dst = reg

        instruction = (opcode << 14) | (mod << 8) | (src << 4) | dst
        return instruction

    else:
        raise ValueError(f"Unknown instruction: {op}")

def assemble_file(filename):
    """Assemble entire file to 16-bit instructions"""
    instructions = []
    with open(filename, 'r') as f:
        for line_num, line in enumerate(f, 1):
            try:
                instruction = assemble_line(line)
                if instruction is not None:
                    instructions.append(instruction)
                    print(f"Line {line_num}: {line.strip():20s} -> 0x{instruction:04X}")
            except Exception as e:
                print(f"Error on line {line_num}: {e}")
                sys.exit(1)
    return instructions

def send_to_serial(instructions, port='COM3', baud=115200, delay=0.1):
    """Send 16-bit instructions to serial port (big-endian: high byte first)"""
    ser = serial.Serial(port, baud, timeout=1)
    time.sleep(0.1)  # Let port stabilize

    print(f"\nSending {len(instructions)} instructions ({len(instructions)*2} bytes) to {port}...")
    for i, instruction in enumerate(instructions):
        # Send high byte first, then low byte
        high_byte = (instruction >> 8) & 0xFF
        low_byte = instruction & 0xFF

        ser.write(bytes([high_byte]))
        time.sleep(delay)
        ser.write(bytes([low_byte]))

        print(f"  [{i}] 0x{instruction:04X} = [0x{high_byte:02X}, 0x{low_byte:02X}]")
        time.sleep(delay)

    ser.close()
    print("Done!")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python myasm.py <program.txt> [COM_port]")
        sys.exit(1)

    filename = sys.argv[1]
    port = sys.argv[2] if len(sys.argv) > 2 else 'COM3'

    # Assemble
    instructions = assemble_file(filename)

    # Send to board
    send_to_serial(instructions, port)
