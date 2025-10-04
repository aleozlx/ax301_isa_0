import serial
import sys
import time

# Instruction encoding
def assemble_line(line):
    """Convert one assembly line to bytecode"""
    line = line.strip().upper()
    
    # Skip empty lines and comments
    if not line or line.startswith('#') or line.startswith(';'):
        return None
    
    parts = line.replace(',', ' ').split()
    op = parts[0]
    
    if op == 'MOVI':
        # MOVI rX, imm4
        reg = int(parts[1][1])  # Extract number from r0-r3
        imm = int(parts[2], 0)  # Support 0x hex or decimal
        if reg > 3 or imm > 15:
            raise ValueError(f"Invalid MOVI: reg={reg}, imm={imm}")
        return (0b00 << 6) | (reg << 4) | imm
    
    elif op == 'ADD':
        # ADD rX, rY
        dest = int(parts[1][1])
        src = int(parts[2][1])
        if dest > 3 or src > 3:
            raise ValueError(f"Invalid ADD: dest={dest}, src={src}")
        return (0b01 << 6) | (dest << 4) | (src << 2)
    
    elif op == 'DISP':
        # DISP rX
        reg = int(parts[1][1])
        if reg > 3:
            raise ValueError(f"Invalid DISP: reg={reg}")
        return (0b11 << 6) | (reg << 4)
    
    else:
        raise ValueError(f"Unknown instruction: {op}")

def assemble_file(filename):
    """Assemble entire file to bytecode"""
    bytecode = []
    with open(filename, 'r') as f:
        for line_num, line in enumerate(f, 1):
            try:
                byte = assemble_line(line)
                if byte is not None:
                    bytecode.append(byte)
                    print(f"Line {line_num}: {line.strip():20s} -> 0x{byte:02X}")
            except Exception as e:
                print(f"Error on line {line_num}: {e}")
                sys.exit(1)
    return bytecode

def send_to_serial(bytecode, port='COM3', baud=115200, delay=0.1):
    """Send bytecode to serial port"""
    ser = serial.Serial(port, baud, timeout=1)
    time.sleep(0.1)  # Let port stabilize
    
    print(f"\nSending {len(bytecode)} bytes to {port}...")
    for i, byte in enumerate(bytecode):
        ser.write(bytes([byte]))
        print(f"  [{i}] 0x{byte:02X}")
        time.sleep(delay)
    
    ser.close()
    print("Done!")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python asm.py <program.asm> [COM_port]")
        sys.exit(1)
    
    filename = sys.argv[1]
    port = sys.argv[2] if len(sys.argv) > 2 else 'COM3'
    
    # Assemble
    bytecode = assemble_file(filename)
    
    # Send to board
    send_to_serial(bytecode, port)
	 