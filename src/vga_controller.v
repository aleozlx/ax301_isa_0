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

    // SRAM dual line buffer interface
    output reg [10:0] sram_wr_addr,     // Write address (0-1023 for each buffer)
    output reg [15:0] sram_wr_data,     // Write data (RGB565)
    output reg sram_wr_en,              // Write enable
    output reg sram_buf_sel,            // Buffer select for write (0=A, 1=B)
    output reg [10:0] sram_rd_addr,     // Read address
    output wire sram_rd_buf_sel,        // Buffer select for read (0=A, 1=B)
    input wire [15:0] sram_rd_data,     // Read data

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
reg [4:0] vga_r;
reg [5:0] vga_g;
reg [4:0] vga_b;

assign vga_out_r = vga_r;
assign vga_out_g = vga_g;
assign vga_out_b = vga_b;

wire [5:0] vga_underrun_dbg = {2'b11, active_x[9:7]};

// Vsync edge detection
reg vs_d;
always @(posedge clk_vga) vs_d <= vs;
assign vsync_pulse = ~vs_d & vs;  // Rising edge

// Ping-pong buffer control (which buffer VGA reads from)
reg vga_buf_sel;  // 0=A, 1=B (opposite of sram_buf_sel during active display)
assign sram_rd_buf_sel = vga_buf_sel;

// H-blank detection (edge-triggered)
reg de_d;
wire h_blank_start = de_d & ~de;  // Falling edge of display enable

always @(posedge clk_vga or negedge rst_n) begin
    if (!rst_n) begin
        de_d <= 1'b0;
    end else begin
        de_d <= de;
    end
end

// Synchronize buffer_ready to VGA clock domain
reg [1:0] buffer_ready_vga, buffer_ready_vga_d;
always @(posedge clk_vga) begin
    buffer_ready_vga <= buffer_ready;
    buffer_ready_vga_d <= buffer_ready_vga;
end

// VGA scanout (reads from SRAM line buffer)
always @(posedge clk_vga or negedge rst_n) begin
    if (!rst_n) begin
        sram_rd_addr <= 11'h000;
        vga_r <= 5'b00000;
        vga_g <= 6'b000000;
        vga_b <= 5'b00000;
        vga_buf_sel <= 1'b0;
    end else begin
        // Toggle buffer at start of each line
        if (active_x == 12'd0 && active_y != 12'd0 && de) begin
            vga_buf_sel <= ~vga_buf_sel;
        end

        if (de) begin
            // During active video, read from current buffer
            sram_rd_addr <= active_x[10:0];

            // Check if buffer is ready (underrun detection)
            // if (buffer_ready_vga_d[vga_buf_sel]) begin
                // Normal: buffer has valid data
                vga_r <= sram_rd_data[15:11];  // Red 5 bits
                vga_g <= sram_rd_data[10:5];   // Green 6 bits
                vga_b <= sram_rd_data[4:0];    // Blue 5 bits
            // end else begin
            //     // Underrun: buffer not ready, output MAGENTA for debug
            //     if (active_y[5] ^ active_x[7]) begin
            //         if (active_y[1]) begin
            //             vga_r <= 5'b00000;
            //             vga_g <= {1'b1, vga_underrun_dbg};
            //             vga_b <= 5'b00000;
            //         end else begin
            //             vga_r <= vga_underrun_dbg;
            //             vga_g <= 6'b111111;
            //             vga_b <= 5'b11111;
            //         end
            //     end else begin
            //         vga_b <= 5'b11111;
            //         if (active_y[1]) begin
            //             vga_r <= 5'b00000;
            //             vga_g <= {1'b1, vga_underrun_dbg};
            //         end else begin
            //             vga_r <= vga_underrun_dbg;
            //             vga_g <= 6'b000000;
            //         end
            //     end
            // end
        end else begin
            // Blanking period - output black
            vga_r <= 5'b00000;
            vga_g <= 6'b000000;
            vga_b <= 5'b00000;
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

reg [11:0] next_line_y;       // Which line to fetch next
reg [10:0] burst_pixel_count; // Pixels received in current burst

// Buffer ready flags (1=buffer has valid data, 0=being filled/empty)
reg [1:0] buffer_ready;  // [1]=buffer_b, [0]=buffer_a
assign debug_buffer_ready = buffer_ready;
assign debug_fill_state = fill_state;

// Cross clock domain: detect line start (active_x goes to 0)
reg [11:0] active_x_sys, active_x_sys_d;
reg [11:0] active_y_sys;
always @(posedge clk_sys) begin
    active_x_sys <= active_x;
    active_x_sys_d <= active_x_sys;
    active_y_sys <= active_y;
end
wire line_start_sys_pulse = (active_x_sys == 12'd0) && (active_x_sys_d != 12'd0);

// Track previous active_y to detect line changes
reg [11:0] prev_active_y_sys;

always @(posedge clk_sys or negedge rst_n) begin
    if (!rst_n) begin
        fill_state <= FILL_IDLE;
        sdram_line_req <= 1'b0;
        sdram_line_addr <= 24'h000000;
        sram_wr_addr <= 11'h000;
        sram_wr_data <= 16'h0000;
        sram_wr_en <= 1'b0;
        sram_buf_sel <= 1'b0;
        next_line_y <= 12'd0;
        burst_pixel_count <= 11'd0;
        buffer_ready <= 2'b00;  // Both buffers start empty
        prev_active_y_sys <= 12'd0;
    end else begin
        // Update prev_active_y tracker
        prev_active_y_sys <= active_y_sys;

        case (fill_state)
            FILL_IDLE: begin
                sram_wr_en <= 1'b0;

                // Start fetching next_line_y when active_y changes (new line started)
                // This ensures buffer is ready when VGA needs it
                // Only run if enabled
                if (enable && (active_y_sys != prev_active_y_sys) && next_line_y < 12'd768) begin
                    // Calculate address for next_line_y
                    // Address = fb_base_addr + (next_line_y * 2048)
                    sdram_line_addr <= fb_base_addr + ({next_line_y, 11'b0});  // y * 2048

                    // Prepare to fill opposite buffer
                    sram_buf_sel <= ~sram_buf_sel;
                    sram_wr_addr <= 11'h000;
                    burst_pixel_count <= 11'd0;

                    // Mark buffer as not ready while filling
                    buffer_ready[~sram_buf_sel] <= 1'b0;

                    fill_state <= FILL_REQ;
                end
            end

            FILL_REQ: begin
                // Request SDRAM burst
                sdram_line_req <= 1'b1;

                if (sdram_line_grant) begin
                    fill_state <= FILL_BURST;
                end
            end

            FILL_BURST: begin
                // Receive burst data and write to SRAM
                if (sdram_line_valid) begin
                    sram_wr_data <= sdram_line_data;
                    sram_wr_en <= 1'b1;
                    sram_wr_addr <= burst_pixel_count;
                    burst_pixel_count <= burst_pixel_count + 1;
                end else begin
                    sram_wr_en <= 1'b0;
                end

                // Check if burst complete
                if (sdram_line_done) begin
                    sdram_line_req <= 1'b0;
                    sram_wr_en <= 1'b0;

                    // Increment line counter
                    if (next_line_y < 12'd767)
                        next_line_y <= next_line_y + 1;
                    else
                        next_line_y <= 12'd0;  // Wrap to top

                    fill_state <= FILL_DONE;
                end
            end

            FILL_DONE: begin
                // Mark buffer as ready
                buffer_ready[sram_buf_sel] <= 1'b1;

                // Wait a cycle, then return to idle
                fill_state <= FILL_IDLE;
            end
        endcase
    end
end

endmodule
