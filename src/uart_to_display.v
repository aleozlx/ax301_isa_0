module uart_to_display(
    input wire clk,           // 50MHz
    input wire rst_n,
    input wire uart_rx,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data
);

// UART RX instance (reuse existing module)
wire [7:0] rx_data;
wire rx_data_valid;
reg rx_data_ready;

uart_rx #(
    .CLK_FRE(50),
    .BAUD_RATE(115200)
) uart_rx_inst (
    .clk(clk),
    .rst_n(rst_n),
    .rx_data(rx_data),
    .rx_data_valid(rx_data_valid),
    .rx_data_ready(rx_data_ready),
    .rx_pin(uart_rx)
);

// Register file
reg [7:0] registers [0:3];  // r0-r3
reg [7:0] display_byte;
integer i;

// Decode instruction
wire [1:0] opcode = rx_data[7:6];
wire [1:0] dest   = rx_data[5:4];
wire [1:0] src    = rx_data[3:2];
wire [3:0] imm    = rx_data[3:0];

// Execute instruction
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 4; i = i + 1)
            registers[i] <= 8'h00;
        display_byte <= 8'h00;
        rx_data_ready <= 1'b1;
    end else begin
        rx_data_ready <= 1'b1; // always ready
        if (rx_data_valid) begin
            case (opcode)
                2'b00: registers[dest] <= {4'b0, imm};                    // MOVI
                2'b01: registers[dest] <= registers[dest] + registers[src]; // ADD
                2'b11: display_byte <= registers[dest];                   // DISP
                // 2'b10: reserved (SUB)
            endcase
        end
    end
end

// Decode nibbles to 7-seg (reuse existing decoder)
wire [6:0] seg_low, seg_high;

seg_decoder dec_low(
    .bin_data(display_byte[3:0]),
    .seg_data(seg_low)
);

seg_decoder dec_high(
    .bin_data(display_byte[7:4]),
    .seg_data(seg_high)
);

// Display scanner (show on rightmost 2 digits)
seg_scan scanner(
    .clk(clk),
    .rst_n(rst_n),
    .seg_sel(seg_sel),
    .seg_data(seg_data),
    .seg_data_0({1'b1, seg_high}),   // rightmost
    .seg_data_1({1'b1, seg_low}),  
    .seg_data_2(8'hFF),             // blank
    .seg_data_3(8'hFF),
    .seg_data_4(8'hFF),
    .seg_data_5(8'hFF)
);

endmodule
