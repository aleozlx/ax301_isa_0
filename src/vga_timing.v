// Simplified VGA timing generator for 1024x768@60Hz
// Based on ALINX color_bar.v reference design
// Generates only timing signals (hs, vs, de) and pixel coordinates

`include "video_define.v"

module vga_timing(
    input                 clk,           // 65MHz pixel clock
    input                 rst,           // reset signal high active
    output                hs,            // horizontal synchronization
    output                vs,            // vertical synchronization
    output                de,            // video data enable
    output[11:0]          active_x,      // current pixel X position (0-1023)
    output[11:0]          active_y       // current pixel Y position (0-767)
);

// 1024x768@60Hz timing parameters
`ifdef  VIDEO_1024_768
parameter H_ACTIVE = 16'd1024;
parameter H_FP = 16'd24;
parameter H_SYNC = 16'd136;
parameter H_BP = 16'd160;
parameter V_ACTIVE = 16'd768;
parameter V_FP  = 16'd3;
parameter V_SYNC  = 16'd6;
parameter V_BP  = 16'd29;
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;
`endif

parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;

reg hs_reg;
reg vs_reg;
reg hs_reg_d0;
reg vs_reg_d0;
reg[11:0] h_cnt;
reg[11:0] v_cnt;
reg[11:0] active_x_reg;
reg[11:0] active_y_reg;
reg h_active;
reg v_active;
wire video_active;
reg video_active_d0;

assign hs = hs_reg_d0;
assign vs = vs_reg_d0;
assign video_active = h_active & v_active;
assign de = video_active_d0;
assign active_x = active_x_reg;
assign active_y = active_y_reg;

// Delay sync signals by 1 clock
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1) begin
        hs_reg_d0 <= 1'b0;
        vs_reg_d0 <= 1'b0;
        video_active_d0 <= 1'b0;
    end else begin
        hs_reg_d0 <= hs_reg;
        vs_reg_d0 <= vs_reg;
        video_active_d0 <= video_active;
    end
end

// Horizontal counter
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        h_cnt <= 12'd0;
    else if(h_cnt == H_TOTAL - 1)
        h_cnt <= 12'd0;
    else
        h_cnt <= h_cnt + 12'd1;
end

// Horizontal active position
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        active_x_reg <= 12'd0;
    else if(h_cnt >= H_FP + H_SYNC + H_BP - 1)
        active_x_reg <= h_cnt - (H_FP[11:0] + H_SYNC[11:0] + H_BP[11:0] - 12'd1);
    else
        active_x_reg <= active_x_reg;
end

// Vertical counter
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        v_cnt <= 12'd0;
    else if(h_cnt == H_FP  - 1)
        if(v_cnt == V_TOTAL - 1)
            v_cnt <= 12'd0;
        else
            v_cnt <= v_cnt + 12'd1;
    else
        v_cnt <= v_cnt;
end

// Vertical active position
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        active_y_reg <= 12'd0;
    else if((v_cnt >= V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))
        active_y_reg <= v_cnt - (V_FP[11:0] + V_SYNC[11:0] + V_BP[11:0] - 12'd1);
    else if((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1))
        active_y_reg <= 12'd0;
    else
        active_y_reg <= active_y_reg;
end

// Horizontal sync
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        hs_reg <= 1'b0;
    else if(h_cnt == H_FP - 1)
        hs_reg <= HS_POL;
    else if(h_cnt == H_FP + H_SYNC - 1)
        hs_reg <= ~hs_reg;
    else
        hs_reg <= hs_reg;
end

// Horizontal active
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        h_active <= 1'b0;
    else if(h_cnt == H_FP + H_SYNC + H_BP - 1)
        h_active <= 1'b1;
    else if(h_cnt == H_TOTAL - 1)
        h_active <= 1'b0;
    else
        h_active <= h_active;
end

// Vertical sync
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        vs_reg <= 1'd0;
    else if((v_cnt == V_FP - 1) && (h_cnt == H_FP - 1))
        vs_reg <= VS_POL;
    else if((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_FP - 1))
        vs_reg <= ~vs_reg;
    else
        vs_reg <= vs_reg;
end

// Vertical active
always@(posedge clk or posedge rst) begin
    if(rst == 1'b1)
        v_active <= 1'd0;
    else if((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))
        v_active <= 1'b1;
    else if((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1))
        v_active <= 1'b0;
    else
        v_active <= v_active;
end

endmodule
