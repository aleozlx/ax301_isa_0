// VGA Controller with SDRAM line buffer fill
// Dual line buffer architecture:
// - Buffer A/B in SRAM (1024 pixels × 16-bit RGB565 each)
// - VGA reads from one buffer while SDRAM fills the other during H-blank
// - Ping-pong between buffers each scanline

module vga_controller(
    input wire clk_vga,          // 65MHz VGA pixel clock
    input wire clk_sys,          // 100MHz system clock (SDRAM domain)
    input wire rst_n,
    input wire enable,           // Enable line fill FSM

    // VGA outputs
    output wire [4:0] vga_out_r,
    output wire [5:0] vga_out_g,
    output wire [4:0] vga_out_b,
    output wire vga_out_hs,
    output wire vga_out_vs,

    // SDRAM burst interface (for line fills)
    output reg sdram_line_req,          // Request line fill
    input wire sdram_line_grant,        // Granted (can proceed)
    output reg [23:0] sdram_line_addr,  // Source address in framebuffer
    input wire [15:0] sdram_line_data,  // Burst data from SDRAM
    input wire sdram_line_valid,        // Data valid signal
    input wire sdram_line_done,         // Burst complete

    // Framebuffer base address (from top module)
    input wire [23:0] fb_base_addr,     // Front buffer base

    // Vsync output for buffer swapping
    output wire vsync_pulse,

    // Debug outputs
    output wire [1:0] debug_buffer_ready,
    output wire [2:0] debug_fill_state
);

// VGA timing signals
wire hs, vs, de;
wire [11:0] active_x;
wire [11:0] active_y;

vga_timing vga_timing_inst(
    .clk(clk_vga),
    .rst(~rst_n),
    .hs(hs),
    .vs(vs),
    .de(de),
    .active_x(active_x),
    .active_y(active_y)
);

// Output assignments
assign vga_out_hs = hs;
assign vga_out_vs = vs;

// RGB output registers
reg [15:0] pixel_out;
assign vga_out_r = pixel_out[15:11];
assign vga_out_g = pixel_out[10:5];
assign vga_out_b = pixel_out[4:0];

wire [5:0] vga_underrun_dbg = {2'b11, active_x[9:7]};

// Vsync edge detection
reg vs_d;
always @(posedge clk_vga) vs_d <= vs;
assign vsync_pulse = ~vs_d & vs;  // Rising edge

// Dual line buffers (internal) - 2KB each, RGB565 format
(* ramstyle = "M10K" *) reg [15:0] line_buffer_a [0:1023];
(* ramstyle = "M10K" *) reg [15:0] line_buffer_b [0:1023];

// Ping-pong buffer control
wire vga_buf_sel = active_y[0];
reg wr_buf_sel_vga, wr_buf_sel_vga_once;
reg [11:0] fill_y_vga;

// VGA scanout (reads from internal line buffer)
// reg buffer_ready [1:0];

always @(posedge clk_vga or negedge rst_n) begin
    if (!rst_n) begin
        // there is no time to prefetch @ active_y == 0
        wr_buf_sel_vga_once <= 0;
        wr_buf_sel_vga <= 1;
        fill_y_vga <= 12'd1;
    end else begin
        if (de) begin

            // // Underrun detection
            // if (buffer_ready[vga_buf_sel]) begin
                // Output pixel from buffer
                if (vga_buf_sel)
                    pixel_out <= line_buffer_b[active_x[10:0]];
                else
                    pixel_out <= line_buffer_a[active_x[10:0]];
            // end else begin
            //     // Underrun patterm (preserved this code for reference)
            //     if (active_y[5] ^ active_x[7]) begin
            //         if (active_y[1]) begin
            //             pixel_out[15:11] <= 5'b00000;
            //             pixel_out[10:5] <= {1'b1, vga_underrun_dbg};
            //             pixel_out[4:0] <= 5'b00000;
            //         end else begin
            //             pixel_out[15:11] <= vga_underrun_dbg;
            //             pixel_out[10:5] <= 6'b111111;
            //             pixel_out[4:0] <= 5'b11111;
            //         end
            //     end else begin
            //         pixel_out[4:0] <= 5'b11111;
            //         if (active_y[1]) begin
            //             pixel_out[15:11] <= 5'b00000;
            //             pixel_out[10:5] <= {1'b1, vga_underrun_dbg};
            //         end else begin
            //             pixel_out[15:11] <= vga_underrun_dbg;
            //             pixel_out[10:5] <= 6'b000000;
            //         end
            //     end

            //     pixel_out <= 16'd0;
            // end
            
            wr_buf_sel_vga_once <= 1;
        end else begin
            // Blanking period - output black
            pixel_out <= 16'd0;

            // 24 cycles budget (H_FP) to swap line buffers based on active_y
            // vga_buf_sel points to current scan out buffer (just finished)
            // next scanout buffer is ~vga_buf_sel (once active_y updates)
            // next fill buffer is the one after that (vga_buf_sel again)
            if (wr_buf_sel_vga_once) begin
                if (active_y == 12'd766) fill_y_vga <= 12'd0;
                else fill_y_vga <= active_y + 12'd2;
                wr_buf_sel_vga <= vga_buf_sel;
                wr_buf_sel_vga_once <= 0;
            end
        end
    end
end

// Line fill FSM (runs at 100MHz system clock)
// Starts filling NEXT line when current line display begins
// Has full scanline time (20.67 μs) to complete burst (7.7 μs)
reg [2:0] fill_state;
localparam FILL_IDLE = 3'd0;
localparam FILL_REQ = 3'd1;
localparam FILL_BURST = 3'd2;
localparam FILL_DONE = 3'd3;

// reg [11:0] next_line_y;       // Which line to fetch next
// wire wr_buf_sel = next_line_y[0];
// reg [10:0] burst_pixel_count; // Pixels received in current burst

// Debug outputs
assign debug_buffer_ready = 2'b11;  // Buffers always managed automatically
assign debug_fill_state = fill_state;

// Cross clock domain: detect line start (active_x goes to 0)
// reg [11:0] active_x0, active_x1;
reg line_start;
reg wr_buf_sel /*sync2*/, wr_buf_sel_sync1, wr_buf_sel_prev;
reg [11:0] fill_y;

always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
        // active_x0 <= 12'd0;
        // active_x1 <= 12'd0;
        line_start <= 0;
        wr_buf_sel <= 0;
        wr_buf_sel_sync1 <= 0;
        wr_buf_sel_prev <= 0;
    end else begin
        wr_buf_sel_sync1 <= wr_buf_sel_vga;
        wr_buf_sel <= wr_buf_sel_sync1;
        wr_buf_sel_prev <= wr_buf_sel;
        if (wr_buf_sel != wr_buf_sel_prev && !line_start) begin
            fill_y <= fill_y_vga;
            line_start <= 1;

            // active_x1 <= active_x;
            // active_x0 <= active_x1;
            // if (active_x1 < active_x0) begin
            //     line_start <= 1;
            //     if (active_y < 12'd767)
            //         next_line_y <= active_y + 1;
            //     else
            //         next_line_y <= 12'd0;
            // end
        end else begin
            line_start <= 0;  // wait until next line even if missed
        end
    end
end

reg [10:0] wr_addr;
localparam BLK_EN = 1'b1;
localparam BLK_SIZE = 8'd256;  // words
localparam kBlockWait = 4'd2;  // cycles
reg [3:0] block_idx;
reg [3:0] block_wait;

always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
        fill_state <= FILL_IDLE;
        sdram_line_req <= 1'b0;
        sdram_line_addr <= 24'h000000;
        wr_addr <= 11'd0;
        block_wait <= 4'd0;
    end else begin

        case (fill_state)
            FILL_IDLE: begin
                // Start fetching next line when active_y changes
                // Only run if enabled
                if (enable && line_start) begin
                    block_idx <= 1'd0;
                    wr_addr <= 11'd0;
                    // buffer_ready[wr_buf_sel] = 1'b0;
                    block_wait <= 4'd0;
                    fill_state <= FILL_REQ;
                end
            end

            FILL_REQ: begin
                if (block_wait != 4'd0) begin
                    block_wait <= block_wait - 4'd1;
                end else begin
                    // Request SDRAM burst
                    sdram_line_req <= 1'b1;

                    // Calculate framebuffer address: fb_base_addr + (line_y * 1024)
                    // (memory uses word address)
                    sdram_line_addr <= fb_base_addr + ({fill_y, 10'b0}) + ({block_idx, 8'b0});

                    if (sdram_line_grant) begin
                        fill_state <= FILL_BURST;
                    end
                end
            end

            FILL_BURST: begin
                // Receive burst data - written to line buffer automatically
                if (sdram_line_valid) begin
                    // if (wr_buf_sel) begin
                    if (wr_buf_sel) begin
                        line_buffer_b[wr_addr] <= sdram_line_data;
                    end else begin
                        line_buffer_a[wr_addr] <= sdram_line_data;
                    end
                    wr_addr <= wr_addr + 1;
                    // burst_pixel_count <= burst_pixel_count + 1;
                end

                // Check if burst complete
                if (sdram_line_done) begin
                    sdram_line_req <= 1'b0;

                    if (BLK_EN && block_idx < 4'd4) begin
                        block_idx <= block_idx + 4'd1;
                        block_wait <= kBlockWait;
                        fill_state <= FILL_REQ;
                    end else begin
                        // buffer_ready[wr_buf_sel] <= 1'b1;
                        fill_state <= FILL_IDLE;
                    end
                    
                end
            end
        endcase
    end
end

endmodule
