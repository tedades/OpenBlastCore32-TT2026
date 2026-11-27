`default_nettype none

module obc32_timer_irq (
    input wire clk, rst_n,
    input wire vblank_start,
    input wire wr,
    input wire [2:0] sel,
    input wire [31:0] wdata,
    output reg [31:0] rdata,
    output wire irq
);
    reg [31:0] count, compare, scratch;
    reg armed, late;
    reg [1:0] pending, enable;
    wire [31:0] delta = wdata - count;
    wire future_ok = !delta[31] && |delta;
    wire fire = armed && count == compare;
    wire [1:0] ack = (wr && sel == 3'd3) ? wdata[1:0] : 2'b00;
    wire [1:0] set = {vblank_start, fire};

    always @(posedge clk) begin
        if (!rst_n) begin
            count <= 0; compare <= 0; armed <= 0; late <= 0;
            pending <= 0; enable <= 0; scratch <= 0;
        end else begin
            if (wr && sel == 3'd5) scratch <= wdata;
            count <= count + 1'b1;
            pending <= (pending & ~ack) | set;
            if (fire) armed <= 0;
            if (wr && sel == 3'd1) begin
                compare <= wdata; armed <= future_ok; late <= !future_ok;
            end
            if (wr && sel == 3'd2) begin
                if (wdata[0]) armed <= 0;
                if (wdata[1]) late <= 0;
            end
            if (wr && sel == 3'd4) enable <= wdata[1:0];
        end
    end
    assign irq = |(pending & enable);
    always @* begin
        case (sel)
            3'd0: rdata = count;
            3'd1: rdata = compare;
            3'd2: rdata = {30'b0, late, armed};
            3'd3: rdata = {30'b0, pending};
            3'd5: rdata = scratch;
            default: rdata = {30'b0, enable};
        endcase
    end
endmodule
`default_nettype wire
