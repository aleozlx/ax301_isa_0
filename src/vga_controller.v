// VGA Controller with fixed SRAM line buffer
// Reads 2KB line buffer (1024 pixels × 16-bit RGB565) and displays on all scanlines
// Provides "barcode" visual debugging - processor writes to SRAM, immediately visible

module vga_controller(
    input wire clk_vga,          // 65MHz VGA pixel clock
    input wire clk_sys,          // 100MHz system clock (for SRAM access)
    input wire rst_n,

    // VGA outputs
    output wire [4:0] vga_out_r,
    output wire [5:0] vga_out_g,
    output wire [4:0] vga_out_b,
    output wire vga_out_hs,
    output wire vga_out_vs,

    // SRAM line buffer interface (read-only from VGA side)
    output reg [15:0] sram_rd_addr,
    input wire [15:0] sram_rd_data
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

// Line buffer: 2KB SRAM at 0x0000-0x07FF
// 1024 pixels × 16-bit RGB565 = 2048 bytes
// Read same buffer for ALL scanlines (repeating pattern)

reg [15:0] pixel_data;

always @(posedge clk_vga or negedge rst_n) begin
    if (!rst_n) begin
        sram_rd_addr <= 16'h0000;
        pixel_data <= 16'h0000;
        vga_r <= 5'b00000;
        vga_g <= 6'b000000;
        vga_b <= 5'b00000;
    end else begin
        if (de) begin
            // During active video, read from line buffer
            // Address: 0x0000 + (active_x * 2) for 16-bit RGB565
            // active_x ranges 0-1023, so address 0x0000-0x07FE (even addresses only)
            sram_rd_addr <= {5'b00000, active_x[9:0], 1'b0};  // Word-aligned address

            // Convert RGB565 → 5-6-5 VGA output
            // SRAM data format: RGB565 [R4:R0][G5:G0][B4:B0]
            vga_r <= sram_rd_data[15:11];  // Red 5 bits
            vga_g <= sram_rd_data[10:5];   // Green 6 bits
            vga_b <= sram_rd_data[4:0];    // Blue 5 bits
        end else begin
            // Blanking period - output black
            vga_r <= 5'b00000;
            vga_g <= 6'b000000;
            vga_b <= 5'b00000;
        end
    end
end

endmodule
