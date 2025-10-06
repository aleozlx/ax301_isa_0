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

// Register file
reg [7:0] registers [0:3];  // r0-r3 (r3 is display register)
reg [23:0] sp;              // Stack pointer (24-bit for SDRAM addressing)
integer i;

// Decode instruction: [opcode:2][dst:2][subop/imm:2][src/unused:2]
wire [1:0] opcode = rx_data[7:6];
wire [1:0] dst    = rx_data[5:4];
wire [1:0] subop  = rx_data[3:2];  // subop for reg/mem ops
wire [1:0] src    = rx_data[1:0];
wire [3:0] imm    = rx_data[3:0];  // immediate for MOVI (special case)

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
reg [16:0] monitor_counter;
reg [7:0] monitor_data;
reg monitor_rd_req;
reg [1:0] monitor_state;
localparam MON_IDLE = 2'd0;
localparam MON_READ = 2'd1;
localparam MON_WAIT = 2'd2;

// Execute instruction (now at 100MHz)
always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 4; i = i + 1)
            registers[i] <= 8'h00;
        sp <= 24'h900010;  // Stack starts after initialized area (0x900000-0x90000F)
        rx_data_ready <= 1'b0;  // Not ready until SDRAM init done
        exec_state <= EXEC_INIT;
        wr_burst_req <= 1'b0;
        rd_burst_req_main <= 1'b0;
        wr_burst_len <= 10'd1;  // Always 1 word (16-bit)
        rd_burst_len <= 10'd1;
        init_counter <= 8'd0;
        sdram_write_data_reg <= 16'h0000;
    end else begin
        case (exec_state)
            EXEC_INIT: begin
                // Initialize SDRAM with 0xCC pattern (16-bit words)
                // Fill more memory to catch out-of-bounds reads
                rx_data_ready <= 1'b0;
                if (init_counter < 8'd32) begin  // 32 words = 64 bytes (0x900000-0x90003F)
                    wr_burst_addr <= 24'h900000 + {14'd0, init_counter, 1'b0};  // Word-aligned
                    sdram_write_data_reg <= 16'hCCCC;  // Both bytes CC
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
                    registers[3] <= rd_burst_data[7:0];  // Display on r3 (should show CC)
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
                    case (opcode)
                        2'b00: begin  // MOVI rx, imm4
                            registers[dst] <= {4'b0, imm};
                        end

                        2'b01: begin  // Register ops
                            case (subop)
                                2'b00: begin  // MOV rx, ry
                                    registers[dst] <= registers[src];
                                end
                                2'b01: begin  // ADD rx, ry
                                    registers[dst] <= registers[dst] + registers[src];
                                end
                                // 2'b10, 2'b11: reserved for SUB, XOR, etc.
                            endcase
                        end

                        2'b10: begin  // Memory ops (16-bit SDRAM access)
                            case (subop)
                                2'b00: begin  // POP rx (SP -= 2, read from new SP)
                                    sp <= sp - 24'd2;
                                    rd_burst_addr_main <= sp - 24'd2;  // Read from new SP value
                                    rd_burst_req_main <= 1'b1;
                                    exec_state <= EXEC_POP_WAIT;
                                end
                                2'b01: begin  // PUSH rx (write to SP, SP += 2)
                                    wr_burst_addr <= sp;
                                    sdram_write_data_reg <= {registers[dst], registers[dst]};
                                    wr_burst_req <= 1'b1;
                                    sp <= sp + 24'd2;
                                    exec_state <= EXEC_PUSH_WAIT;
                                end
                            endcase
                        end

                        // 2'b11: reserved for future complex instructions
                    endcase
                end
            end

            EXEC_POP_WAIT: begin
                // Exactly like EXEC_INIT_READ_WAIT
                if (rd_burst_data_valid) begin
					     registers[dst] <= rd_burst_data[7:0];
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
always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n) begin
        monitor_counter <= 17'd0;
        monitor_data <= 8'h00;
        monitor_rd_req <= 1'b0;
        monitor_state <= MON_IDLE;
    end else begin
        // Counter increments every cycle
        if (monitor_counter < 17'd75000)
            monitor_counter <= monitor_counter + 1;
        else
            monitor_counter <= 17'd0;

        case (monitor_state)
            MON_IDLE: begin
                if (monitor_counter == 17'd75000) begin
                    monitor_state <= MON_READ;
                end
            end

            MON_READ: begin
                // Issue read request (address muxed automatically to 0x900000)
                monitor_rd_req <= 1'b1;
                monitor_state <= MON_WAIT;
            end

            MON_WAIT: begin
                // Capture data when valid (shared signal with main)
                if (rd_burst_data_valid && monitor_rd_req) begin
                    monitor_data <= rd_burst_data[7:0];
                end

                // Wait for finish
                if (rd_burst_finish && monitor_rd_req) begin
                    monitor_rd_req <= 1'b0;
                    monitor_state <= MON_IDLE;
                end
            end
        endcase
    end
end

// Decode nibbles to 7-seg (r3 is the display register)
wire [6:0] seg_low, seg_high;
wire [6:0] mon_low, mon_high;

seg_decoder dec_low(
    .bin_data(registers[3][3:0]),
    .seg_data(seg_low)
);

seg_decoder dec_high(
    .bin_data(registers[3][7:4]),
    .seg_data(seg_high)
);

seg_decoder mon_dec_low(
    .bin_data(monitor_data[3:0]),
    .seg_data(mon_low)
);

seg_decoder mon_dec_high(
    .bin_data(monitor_data[7:4]),
    .seg_data(mon_high)
);

// Display scanner - use original 50MHz clock for stable display
seg_scan scanner(
    .clk(clk),
    .rst_n(rst_n),
    .seg_sel(seg_sel),
    .seg_data(seg_data),
    .seg_data_0({1'b1, seg_high}),   // r3 high nibble (rightmost)
    .seg_data_1({1'b1, seg_low}),    // r3 low nibble
    .seg_data_2({1'b1, mon_high}),   // monitor high nibble
    .seg_data_3({1'b1, mon_low}),    // monitor low nibble
    .seg_data_4(8'hFF),
    .seg_data_5(8'hFF)
);

endmodule
