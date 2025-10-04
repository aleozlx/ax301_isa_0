\# Toy FPGA Soft Processor



Minimal 8-bit soft processor on Cyclone IV (AX301 board).



\## ISA (3 instructions)

\- `MOVI rX, imm4` - Load 4-bit immediate

\- `ADD rX, rY` - Add registers

\- `DISP rX` - Display register on 7-segment



\## Usage

1\. Compile in Quartus Prime

2\. Program FPGA

3\. Run: `python src/myasm.py src/test\_isa.txt COM3`



\## Hardware

\- Board: ALINX AX301 (Cyclone IV EP4CE6F17C8)

\- UART: 115200 baud on PIN\_M2

\- Display: 6-digit 7-segment



