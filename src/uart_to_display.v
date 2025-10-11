module uart_to_display(
    input wire clk,           // 50MHz input clock
    input wire rst_n,
    input wire uart_rx,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,

    // SDRAM physical interface
    output wire sdram_clk,
    output wire sdram_cke,
    output wire sdram_cs_n,
    output wire sdram_ras_n,
    output wire sdram_cas_n,
    output wire sdram_we_n,
    output wire [1:0] sdram_ba,
    output wire [12:0] sdram_addr,
    output wire [1:0] sdram_dqm,
    inout wire [15:0] sdram_dq
);

// PLL: 50MHz -> 100MHz for SDRAM
wire clk_100mhz;
wire pll_unused;

sys_pll pll_inst (
    .inclk0(clk),
    .c0(pll_unused),      // 100MHz (unused)
    .c1(clk_100mhz)       // 100MHz for SDRAM
);

// Drive SDRAM clock pin
assign sdram_clk = clk_100mhz;

// UART RX instance (now runs at 100MHz)
wire [7:0] rx_data;
wire rx_data_valid;
reg rx_data_ready;

uart_rx #(
    .CLK_FRE(100),      // Changed to 100MHz
    .BAUD_RATE(115200)
) uart_rx_inst (
    .clk(clk_100mhz),   // Use 100MHz clock
    .rst_n(rst_n),
    .rx_data(rx_data),
    .rx_data_valid(rx_data_valid),
    .rx_data_ready(rx_data_ready),
    .rx_pin(uart_rx)
);

// Register file (16-bit ISA upgrade)
reg [15:0] registers [0:15];  // r0-r15 (r3 is display register)
reg [23:0] sp;                // Stack pointer (24-bit for SDRAM addressing)
integer i;

// 16-bit instruction assembly (2 bytes from UART)
reg [7:0] inst_byte_high;     // First byte received (bits [15:8])
reg inst_byte_valid;           // Flag: waiting for second byte
wire [15:0] instruction = {inst_byte_high, rx_data};  // Assembled 16-bit instruction

// Decode 16-bit instruction: [Op:2][Mod:6][Src:4][Dst:4]
wire [1:0] opcode = instruction[15:14];
wire [5:0] mod    = instruction[13:8];
wire [3:0] src    = instruction[7:4];
wire [3:0] dst    = instruction[3:0];

// For MOVI/ADDI: 4-bit immediate from src field (ADDI encoding: 00 010000 ssss dddd)
wire [3:0] imm4   = src;

// SDRAM direct 16-bit burst interface
reg wr_burst_req;
reg [15:0] wr_burst_data;
reg [9:0] wr_burst_len;
reg [23:0] wr_burst_addr;
wire wr_burst_data_req;
wire wr_burst_finish;

reg rd_burst_req_main;      // Main execution path read request
wire rd_burst_req;           // Combined with monitor
reg [9:0] rd_burst_len;
reg [23:0] rd_burst_addr_main;  // Main execution path address
wire [23:0] rd_burst_addr;       // Multiplexed address
wire [15:0] rd_burst_data;
wire rd_burst_data_valid;
wire rd_burst_finish;

// Working register for SDRAM operations
reg [15:0] sdram_write_data_reg;

// Combine main and monitor read requests
assign rd_burst_req = rd_burst_req_main | monitor_rd_req;
// Multiplex address: monitor wins when it's requesting (simpler priority)
assign rd_burst_addr = monitor_rd_req ? 24'h900000 : rd_burst_addr_main;

// SDRAM controller core (uses 100MHz clock)
sdram_core #(
    .T_RP(4),
    .T_RC(6),
    .T_MRD(6),
    .T_RCD(2),
    .T_WR(3),
    .CASn(3),
    .SDR_BA_WIDTH(2),
    .SDR_ROW_WIDTH(13),
    .SDR_COL_WIDTH(9),
    .SDR_DQ_WIDTH(16),
    .APP_ADDR_WIDTH(24),
    .APP_BURST_WIDTH(10)
) sdram_ctrl (
    .clk(clk_100mhz),
    .rst(~rst_n),
    .wr_burst_req(wr_burst_req),
    .wr_burst_data(wr_burst_data),
    .wr_burst_len(wr_burst_len),
    .wr_burst_addr(wr_burst_addr),
    .wr_burst_data_req(wr_burst_data_req),
    .wr_burst_finish(wr_burst_finish),
    .rd_burst_req(rd_burst_req),
    .rd_burst_len(rd_burst_len),
    .rd_burst_addr(rd_burst_addr),
    .rd_burst_data(rd_burst_data),
    .rd_burst_data_valid(rd_burst_data_valid),
    .rd_burst_finish(rd_burst_finish),
    .sdram_cke(sdram_cke),
    .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n(sdram_ras_n),
    .sdram_cas_n(sdram_cas_n),
    .sdram_we_n(sdram_we_n),
    .sdram_ba(sdram_ba),
    .sdram_addr(sdram_addr),
    .sdram_dqm(sdram_dqm),
    .sdram_dq(sdram_dq)
);

// Execution state machine
reg [2:0] exec_state;
localparam EXEC_INIT = 3'd0;         // Initialize SDRAM with test pattern
localparam EXEC_INIT_WAIT = 3'd1;    // Wait for init write to complete
localparam EXEC_INIT_READ = 3'd2;    // Read back to verify SDRAM works
localparam EXEC_INIT_READ_WAIT = 3'd3; // Wait for init read to complete
localparam EXEC_FETCH = 3'd4;        // Fetch instruction
localparam EXEC_POP_WAIT = 3'd5;     // Wait for POP read
localparam EXEC_PUSH_WAIT = 3'd6;    // Wait for PUSH write

// SDRAM initialization state
reg [7:0] init_counter;

// Independent periodic monitor (750μs = 75,000 cycles @ 100MHz)
//reg [16:0] monitor_counter;
//reg [15:0] monitor_data;  // Changed to 16-bit
reg monitor_rd_req;
//reg [1:0] monitor_state;
//localparam MON_IDLE = 2'd0;
//localparam MON_READ = 2'd1;
//localparam MON_WAIT = 2'd2;

// Execute instruction (now at 100MHz)
always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 16; i = i + 1)
            registers[i] <= 16'h0000;
        sp <= 24'h900010;  // Stack starts after initialized area (0x900000-0x90000F)
        rx_data_ready <= 1'b0;  // Not ready until SDRAM init done
        exec_state <= EXEC_INIT;
        wr_burst_req <= 1'b0;
        rd_burst_req_main <= 1'b0;
        wr_burst_len <= 10'd1;  // Always 1 word (16-bit)
        rd_burst_len <= 10'd1;
        init_counter <= 8'd0;
        sdram_write_data_reg <= 16'h0000;
        inst_byte_high <= 8'h00;
        inst_byte_valid <= 1'b0;
    end else begin
        case (exec_state)
            EXEC_INIT: begin
                // Initialize SDRAM with 0xCC pattern (16-bit words)
                // Fill more memory to catch out-of-bounds reads
                rx_data_ready <= 1'b0;
                if (init_counter < 8'd32) begin  // 32 words = 64 bytes (0x900000-0x90003F)
                    wr_burst_addr <= 24'h900000 + {14'd0, init_counter, 1'b0};  // Word-aligned
                    sdram_write_data_reg <= 16'hA301;
                    wr_burst_req <= 1'b1;
                    exec_state <= EXEC_INIT_WAIT;
                end else begin
                    // Write done, now read back from 0x900000 to verify
                    exec_state <= EXEC_INIT_READ;
                end
            end

            EXEC_INIT_WAIT: begin
                // Provide data when controller requests it
                if (wr_burst_data_req) begin
                    wr_burst_data <= sdram_write_data_reg;
                end

                // Wait for finish
                if (wr_burst_finish) begin
                    wr_burst_req <= 1'b0;
                    init_counter <= init_counter + 1;
                    exec_state <= EXEC_INIT;
                end
            end

           EXEC_INIT_READ: begin
                // Read back from 0x900000 to verify SDRAM works
                rd_burst_addr_main <= 24'h900000;
                rd_burst_req_main <= 1'b1;
                exec_state <= EXEC_INIT_READ_WAIT;
            end

            EXEC_INIT_READ_WAIT: begin
                // Capture read data and display it
                if (rd_burst_data_valid) begin
                    registers[3] <= rd_burst_data[15:0];  // Display on r3
                end

                // Wait for read to complete
                if (rd_burst_finish) begin
                    rd_burst_req_main <= 1'b0;
                    exec_state <= EXEC_FETCH;  // Now ready for instructions
                end
            end

            EXEC_FETCH: begin
                rx_data_ready <= 1'b1;
                if (rx_data_valid) begin
                    if (!inst_byte_valid) begin
                        // First byte received (high byte)
                        inst_byte_high <= rx_data;
                        inst_byte_valid <= 1'b1;
                    end else begin
                        // Second byte received (low byte), instruction complete
                        inst_byte_valid <= 1'b0;

                        // Decode 16-bit instruction [Op:2][Mod:6][Src:4][Dst:4]
                        case (opcode)
                            2'b00: begin  // R-Family (Register/ALU operations)
                                case (mod)
                                    6'b000000: begin  // MOV rd, rs
                                        registers[dst] <= registers[src];
                                    end
                                    6'b000001: begin  // ADD rd, rs
                                        registers[dst] <= registers[dst] + registers[src];
                                    end
                                    6'b000101: begin  // XOR rd, rs
                                        registers[dst] <= registers[dst] ^ registers[src];
                                    end
                                    6'b010000: begin  // ADDI rd, imm4
                                        registers[dst] <= registers[dst] + {12'b0, imm4};
                                    end
                                    default: begin
                                        // Unknown R-family instruction, ignore
                                    end
                                endcase
                            end

                            2'b01: begin  // M-Family (Memory operations)
                                case (mod)
                                    6'b000010: begin  // PUSH rd
                                        wr_burst_addr <= sp;
                                        sdram_write_data_reg <= registers[dst];
                                        wr_burst_req <= 1'b1;
                                        sp <= sp + 24'd2;
                                        exec_state <= EXEC_PUSH_WAIT;
                                    end
                                    6'b000011: begin  // POP rd
                                        sp <= sp - 24'd2;
                                        rd_burst_addr_main <= sp - 24'd2;
                                        rd_burst_req_main <= 1'b1;
                                        exec_state <= EXEC_POP_WAIT;
                                    end
                                    default: begin
                                        // Unknown M-family instruction, ignore
                                    end
                                endcase
                            end

                            default: begin
                                // Op 10 (J-family) and 11 (X-family) not implemented yet
                            end
                        endcase
                    end
                end
            end

            EXEC_POP_WAIT: begin
                // Wait for POP read to complete
                if (rd_burst_data_valid) begin
                    registers[dst] <= rd_burst_data[15:0];  // Full 16-bit value
                end

                // Only check finish if req is still active
                if (rd_burst_finish && rd_burst_req_main) begin
                    rd_burst_req_main <= 1'b0;
                    exec_state <= EXEC_FETCH;
                end
            end

            EXEC_PUSH_WAIT: begin
                // Provide data when controller requests it
                if (wr_burst_data_req) begin
                    wr_burst_data <= sdram_write_data_reg;
                end

                // Wait for write to finish
                if (wr_burst_finish) begin
                    wr_burst_req <= 1'b0;
                    exec_state <= EXEC_FETCH;
                end
            end
        endcase
    end
end

// Independent periodic SDRAM monitor (runs at 750μs intervals)
//always @(posedge clk_100mhz or negedge rst_n) begin
//    if (!rst_n) begin
//        monitor_counter <= 17'd0;
//        monitor_data <= 16'h0000;
//        monitor_rd_req <= 1'b0;
//        monitor_state <= MON_IDLE;
//    end else begin
//        // Counter increments every cycle
//        if (monitor_counter < 17'd75000)
//            monitor_counter <= monitor_counter + 1;
//        else
//            monitor_counter <= 17'd0;
//
//        case (monitor_state)
//            MON_IDLE: begin
//                if (monitor_counter == 17'd75000) begin
//                    monitor_state <= MON_READ;
//                end
//            end
//
//            MON_READ: begin
//                // Issue read request (address muxed automatically to 0x900000)
//                monitor_rd_req <= 1'b1;
//                monitor_state <= MON_WAIT;
//            end
//
//            MON_WAIT: begin
//                // Capture data when valid (shared signal with main)
//                if (rd_burst_data_valid && monitor_rd_req) begin
//                    monitor_data <= rd_burst_data[15:0];  // Full 16-bit
//                end
//
//                // Wait for finish
//                if (rd_burst_finish && monitor_rd_req) begin
//                    monitor_rd_req <= 1'b0;
//                    monitor_state <= MON_IDLE;
//                end
//            end
//        endcase
//    end
//end

// Decode nibbles to 7-seg (r3 is the display register, now 16-bit)
wire [6:0] seg_nibble0, seg_nibble1, seg_nibble2, seg_nibble3;
wire [6:0] mon_nibble0, mon_nibble1;

// r3 register (16-bit = 4 nibbles)
seg_decoder dec_r3_0(
    .bin_data(registers[3][3:0]),    // Lowest nibble
    .seg_data(seg_nibble0)
);

seg_decoder dec_r3_1(
    .bin_data(registers[3][7:4]),
    .seg_data(seg_nibble1)
);

seg_decoder dec_r3_2(
    .bin_data(registers[3][11:8]),
    .seg_data(seg_nibble2)
);

seg_decoder dec_r3_3(
    .bin_data(registers[3][15:12]),  // Highest nibble
    .seg_data(seg_nibble3)
);

// Monitor data (16-bit = 4 nibbles, but only show 2 for now)
//seg_decoder mon_dec_0(
//    .bin_data(monitor_data[3:0]),
//    .seg_data(mon_nibble0)
//);
//
//seg_decoder mon_dec_1(
//    .bin_data(monitor_data[7:4]),
//    .seg_data(mon_nibble1)
//);

// Display scanner - use original 50MHz clock for stable display
// Layout: [r3[15:12]][r3[11:8]][r3[7:4]][r3[3:0]][mon[7:4]][mon[3:0]]
seg_scan scanner(
    .clk(clk),
    .rst_n(rst_n),
    .seg_sel(seg_sel),
    .seg_data(seg_data),
    .seg_data_0({1'b1, seg_nibble3}),   // r3 highest nibble (leftmost)
    .seg_data_1({1'b1, seg_nibble2}),   // r3
    .seg_data_2({1'b1, seg_nibble1}),   // r3
    .seg_data_3({1'b1, seg_nibble0}),   // r3 lowest nibble
    .seg_data_4({1'b1, mon_nibble1}),   // Monitor high
    .seg_data_5({1'b1, mon_nibble0})    // Monitor low (rightmost)
);

endmodule
