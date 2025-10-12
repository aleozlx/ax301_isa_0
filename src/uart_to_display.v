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
    inout wire [15:0] sdram_dq,

    // VGA outputs
    output wire [4:0] vga_out_r,
    output wire [5:0] vga_out_g,
    output wire [4:0] vga_out_b,
    output wire vga_out_hs,
    output wire vga_out_vs
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

// VGA PLL: 50MHz -> 65MHz for VGA pixel clock
wire clk_65mhz;

video_pll video_pll_inst (
    .inclk0(clk),
    .c0(clk_65mhz)        // 65MHz for VGA
);

// Framebuffer layout in SDRAM (RGB565 format, 16-bit per pixel)
// Each scanline: 1024 pixels × 2 bytes = 2048 bytes
// Each framebuffer: 1024 × 768 × 2 = 1,572,864 bytes (1.5 MiB)
localparam FB0_BASE = 24'h000000;  // Framebuffer 0: 0x000000 - 0x17FFFF
localparam FB1_BASE = 24'h180000;  // Framebuffer 1: 0x180000 - 0x2FFFFF
localparam FB_SCANLINE_BYTES = 11'd2048;  // 1024 pixels × 2 bytes

// Double-buffer management
reg front_buffer;       // 0 = FB0, 1 = FB1 (VGA reads from this)
reg back_buffer;        // 0 = FB0, 1 = FB1 (processor writes to this)
reg frame_ready;        // Processor sets when rendering complete
reg vga_enable;         // Enable VGA after processor init complete
wire [23:0] front_fb_base = front_buffer ? FB1_BASE : FB0_BASE;
wire [23:0] back_fb_base = back_buffer ? FB1_BASE : FB0_BASE;

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
reg [9:0] rd_burst_len_main; // Main execution path burst length
wire [9:0] rd_burst_len;     // Multiplexed burst length
reg [23:0] rd_burst_addr_main;  // Main execution path address
wire [23:0] rd_burst_addr;       // Multiplexed address
wire [15:0] rd_burst_data;
wire rd_burst_data_valid;
wire rd_burst_finish;

// Working register for SDRAM operations
reg [15:0] sdram_write_data_reg;

// SDRAM arbiter: VGA and processor share SDRAM controller
// Priority: Monitor (debug) > Processor > VGA
// VGA only gets access when enabled and processor idle
reg vga_rd_burst_active;
reg [23:0] vga_rd_burst_addr_reg;
reg [9:0] vga_rd_burst_len_reg;

assign rd_burst_req = monitor_rd_req ? 1'b1 :
                      rd_burst_req_main ? 1'b1 :
                      vga_rd_burst_active ? 1'b1 :  // VGA burst in progress
                      1'b0;

assign rd_burst_addr = monitor_rd_req ? 24'h900000 :
                       rd_burst_req_main ? rd_burst_addr_main :
                       vga_rd_burst_addr_reg;

/* notes: H57V2562 
4 banks × 8192 rows × 512 columns × 16 bits
= 4 × 2^13 × 2^9 × 16
= 4 × 8K × 512 × 16 bits
= 256 Mbit ✓

burst modes: 1, 2, 4, 8 words or full page (512 words)

we use full page + early stop, which requires that
rd_burst_len <= 512
*/
assign rd_burst_len = monitor_rd_req ? 10'd1 :
                      rd_burst_req_main ? rd_burst_len_main :
                      vga_rd_burst_len_reg;

// VGA line fill arbiter
always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n) begin
        vga_sdram_line_grant <= 1'b0;
        vga_sdram_line_done <= 1'b0;
        vga_rd_burst_active <= 1'b0;
        vga_rd_burst_addr_reg <= 24'h0;
        vga_rd_burst_len_reg <= 10'd0;
    end else begin
        // VGA line request (when enabled and processor not using SDRAM)
        if (vga_enable && vga_sdram_line_req && !vga_rd_burst_active &&
            !wr_burst_req && !rd_burst_req_main && !monitor_rd_req) begin
            // Grant VGA access and start burst read
            vga_sdram_line_grant <= 1'b1;
            vga_rd_burst_active <= 1'b1;
            vga_rd_burst_addr_reg <= vga_sdram_line_addr;
            vga_rd_burst_len_reg <= 10'd512;  // page size is 512 words maximum
            vga_sdram_line_done <= 1'b0;
        end else if (vga_rd_burst_active) begin
            // VGA burst active: forward SDRAM data to VGA
            // Keep grant asserted until request deasserts
            vga_sdram_line_grant <= vga_sdram_line_req;

            // Check if burst complete OR if VGA gave up (line_req deasserted)
            if (rd_burst_finish || !vga_sdram_line_req) begin
                vga_sdram_line_done <= 1'b1;
                vga_rd_burst_active <= 1'b0;
            end
        end else begin
            vga_sdram_line_grant <= 1'b0;
            vga_sdram_line_done <= 1'b0;
        end
    end
end

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
reg [3:0] exec_state;
localparam EXEC_INIT = 4'd0;         // Initialize SDRAM with test pattern at 0x900000
localparam EXEC_INIT_WAIT = 4'd1;    // Wait for init write to complete
localparam EXEC_INIT_FB = 4'd2;      // Initialize framebuffer with pattern
localparam EXEC_INIT_FB_WAIT = 4'd3; // Wait for FB write to complete
localparam EXEC_INIT_READ = 4'd4;    // Read back to verify SDRAM works
localparam EXEC_INIT_READ_WAIT = 4'd5; // Wait for init read to complete
localparam EXEC_FETCH = 4'd6;        // Fetch instruction
localparam EXEC_POP_WAIT = 4'd7;     // Wait for POP read
localparam EXEC_PUSH_WAIT = 4'd8;    // Wait for PUSH write

// SDRAM initialization state
reg [7:0] init_counter;
reg [19:0] fb_init_counter;  // Counter for framebuffer init (up to 786432 pixels)

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
        rd_burst_len_main <= 10'd1;
        init_counter <= 8'd0;
        fb_init_counter <= 20'd0;
        sdram_write_data_reg <= 16'h0000;
        inst_byte_high <= 8'h00;
        inst_byte_valid <= 1'b0;
        vga_enable <= 1'b0;  // VGA disabled during init
    end else begin
        case (exec_state)
            EXEC_INIT: begin
                // Initialize SDRAM with 0xA301 pattern (16-bit words) at 0x900000
                rx_data_ready <= 1'b0;
                if (init_counter < 8'd32) begin  // 32 words = 64 bytes (0x900000-0x90003F)
                    wr_burst_addr <= 24'h900000 + {14'd0, init_counter, 1'b0};  // Word-aligned
                    sdram_write_data_reg <= 16'hA301;
                    wr_burst_req <= 1'b1;
                    exec_state <= EXEC_INIT_WAIT;
                end else begin
                    // Stack area done, now initialize framebuffer
                    fb_init_counter <= 20'd0;
                    exec_state <= EXEC_INIT_FB;
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

            EXEC_INIT_FB: begin
                // Initialize framebuffer with vertical stripe pattern
                // FB0: 1024×768 pixels = 786,432 pixels at 0x000000
                // Pattern: 8-pixel wide stripes cycling through 8 colors
                rx_data_ready <= 1'b0;

                if (fb_init_counter < 20'd786432) begin  // 1024×768 pixels
                    // Calculate address: FB0_BASE + pixel_index
                    // (memory uses word address: 1 pixel = 1 word = 1 pointer incr)
                    wr_burst_addr <= FB0_BASE + fb_init_counter[18:0];

                    // Generate pattern: 8 colors, 128 pixels each (total 1024 pixels wide)
                    // Color based on X position (fb_init_counter % 1024)
                    // case (fb_init_counter[18:16])  // Bits [9:7] give position/128
                    //     3'd0: sdram_write_data_reg <= 16'hF800;  // Red
                    //     3'd1: sdram_write_data_reg <= 16'h07E0;  // Green
                    //     3'd2: sdram_write_data_reg <= 16'h001F;  // Blue
                    //     3'd3: sdram_write_data_reg <= 16'hFFE0;  // Yellow
                    //     3'd4: sdram_write_data_reg <= 16'h07FF;  // Cyan
                    //     3'd5: sdram_write_data_reg <= 16'hF81F;  // Magenta
                    //     3'd6: sdram_write_data_reg <= 16'hFFFF;  // White
                    //     3'd7: sdram_write_data_reg <= 16'h0000;  // Black
                    // endcase

                    // if (fb_init_counter < 20'd196608)
                    //     sdram_write_data_reg <= 16'hF81F;
                    // else
                    //     sdram_write_data_reg <= 16'h07E0;

                    sdram_write_data_reg <= fb_init_counter[15] ^ fb_init_counter[5] ? 16'h07FF : 16'hF81F;
                    // sdram_write_data_reg <= 16'hFFFF;

                    wr_burst_req <= 1'b1;
                    exec_state <= EXEC_INIT_FB_WAIT;
                end else begin
                    // Framebuffer init done, now read back 0x900000 to verify
                    exec_state <= EXEC_INIT_READ;
                end
            end

            EXEC_INIT_FB_WAIT: begin
                // Provide data when controller requests it
                if (wr_burst_data_req) begin
                    wr_burst_data <= sdram_write_data_reg;
                end

                // Wait for finish
                if (wr_burst_finish) begin
                    wr_burst_req <= 1'b0;
                    fb_init_counter <= fb_init_counter + 1;
                    exec_state <= EXEC_INIT_FB;
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
                    // Enable VGA now that SDRAM init is complete
                    // (VGA will read from uninitialized framebuffer, showing black due to underrun)
                    vga_enable <= 1'b1;
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

// DEBUG: Check why arbiter never grants VGA
// wire [15:0] debug_display;
// assign debug_display[15:10] = 6'h0;
// assign debug_display[9] = vga_enable;
// assign debug_display[8] = vga_sdram_line_req;
// assign debug_display[7] = vga_rd_burst_active;
// assign debug_display[6] = wr_burst_req;
// assign debug_display[5] = rd_burst_req_main;
// assign debug_display[4] = monitor_rd_req;
// assign debug_display[3:2] = vga_fill_state[1:0];
// assign debug_display[1:0] = 2'b0;

// Decode nibbles to 7-seg (show debug info instead of r3)
wire [6:0] seg_nibble0, seg_nibble1, seg_nibble2, seg_nibble3;
wire [6:0] mon_nibble0, mon_nibble1;

// Debug display (16-bit = 4 nibbles)
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

wire vga_sdram_line_req;
reg vga_sdram_line_grant;
wire [23:0] vga_sdram_line_addr;
// reg [15:0] vga_sdram_line_data;
// reg vga_sdram_line_valid;
reg vga_sdram_line_done;

// Vsync pulse for buffer swapping
wire vsync_pulse;

// VGA controller
wire [1:0] vga_buffer_ready;
wire [2:0] vga_fill_state;

vga_controller vga_ctrl(
    .clk_vga(clk_65mhz),
    .clk_sys(clk_100mhz),
    .rst_n(rst_n),
    .enable(vga_enable),
    .vga_out_r(vga_out_r),
    .vga_out_g(vga_out_g),
    .vga_out_b(vga_out_b),
    .vga_out_hs(vga_out_hs),
    .vga_out_vs(vga_out_vs),

    .sdram_line_req(vga_sdram_line_req),
    .sdram_line_grant(vga_sdram_line_grant),
    .sdram_line_addr(vga_sdram_line_addr),
    .sdram_line_data(rd_burst_data[15:0]),
    .sdram_line_valid(rd_burst_data_valid),
    .sdram_line_done(vga_sdram_line_done),
    .fb_base_addr(front_fb_base),
    .vsync_pulse(vsync_pulse),
    .debug_buffer_ready(vga_buffer_ready),
    .debug_fill_state(vga_fill_state)
);

// Double-buffer swap logic
always @(posedge clk_100mhz or negedge rst_n) begin
    if (!rst_n) begin
        front_buffer <= 1'b0;  // Start with FB0 as front
        back_buffer <= 1'b1;   // FB1 as back
        frame_ready <= 1'b0;
        monitor_rd_req <= 1'b0;
    end else begin
        if (vsync_pulse && frame_ready) begin
            // Swap buffers
            front_buffer <= back_buffer;
            back_buffer <= front_buffer;
            frame_ready <= 1'b0;
            // Note: Processor will set frame_ready=1 when done rendering
        end
    end
end

endmodule
