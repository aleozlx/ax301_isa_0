// Top level for simple SDRAM test
module sdram_test_top(
    input wire clk,           // 50MHz input
    input wire rst_n,
    output wire [5:0] seg_sel,
    output wire [7:0] seg_data,

    // SDRAM physical interface
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
    .c0(pll_unused),
    .c1(clk_100mhz)
);

// SDRAM controller interface wires
wire wr_burst_req;
wire [15:0] wr_burst_data;
wire [9:0] wr_burst_len;
wire [23:0] wr_burst_addr;
wire wr_burst_data_req;
wire wr_burst_finish;

wire rd_burst_req;
wire [9:0] rd_burst_len;
wire [23:0] rd_burst_addr;
wire [15:0] rd_burst_data;
wire rd_burst_data_valid;
wire rd_burst_finish;

// Test result
wire [7:0] test_result;

// SDRAM controller
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

// Simple SDRAM test module
sdram_simple_test test_inst (
    .clk(clk_100mhz),
    .rst_n(rst_n),
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
    .test_result(test_result)
);

// Display result on 7-segment
wire [6:0] seg_low, seg_high;

seg_decoder dec_low(
    .bin_data(test_result[3:0]),
    .seg_data(seg_low)
);

seg_decoder dec_high(
    .bin_data(test_result[7:4]),
    .seg_data(seg_high)
);

seg_scan scanner(
    .clk(clk),
    .rst_n(rst_n),
    .seg_sel(seg_sel),
    .seg_data(seg_data),
    .seg_data_0({1'b1, seg_high}),
    .seg_data_1({1'b1, seg_low}),
    .seg_data_2(8'hFF),
    .seg_data_3(8'hFF),
    .seg_data_4(8'hFF),
    .seg_data_5(8'hFF)
);

endmodule
