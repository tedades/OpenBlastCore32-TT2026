`default_nettype none
module tt16_pcm (
    input wire clk, rst_n, tick, wr,
    input wire [1:0] sel,
    input wire [31:0] wdata,
    output reg [31:0] rdata,
    output wire valid,
    output reg [23:0] addr,
    input wire ready, fault,
    input wire [31:0] word,
    output reg signed [7:0] sample,
    output reg [1:0] gain
);
    reg [23:0] base;
    reg [15:0] divider, timer;
    reg enabled, playing, underrun, bus_fault, refill;
    reg [31:0] fifo [0:7];
    reg [2:0] head, tail;
    reg [1:0] lane;
    reg [3:0] count;
    reg [15:0] words, left;
    wire play_tick = playing && tick && timer == 0;
    wire consume = play_tick && count != 0;
    wire pop = consume && lane == 3;
    wire push = valid && ready && !fault;
    assign valid = enabled && !bus_fault && left != 0 && count < 8 &&
                   (refill || count <= 2);
    always @* case (sel)
        0:rdata={8'b0,base};
        1:rdata={words,divider};
        2:rdata={21'b0,count[3],gain,count[2:0],bus_fault,underrun,playing,enabled,valid};
        default:rdata={16'b0,left};
    endcase
    always @(posedge clk) begin
        if (!rst_n) begin
            base<=0; addr<=0; divider<=1134; timer<=0; enabled<=0;
            playing<=0; underrun<=0; bus_fault<=0; head<=0; tail<=0;
            lane<=0; count<=0; sample<=0; gain<=0; words<=0; left<=0; refill<=0;
        end else begin
            if (wr && sel==0 && !enabled) base<=wdata[23:0];
            if (wr && sel==1 && !enabled) begin
                divider<=wdata[15:0]<1134 ? 16'd1134 : wdata[15:0];
                words<=wdata[31:16];
            end
            if (wr && sel==2) begin
                gain<=wdata[3:2];
                if (wdata[1]) underrun<=0;
                if (wdata[0] && !enabled) begin
                    if (base[1:0]!=0 || words==0 ||
                        ({1'b0,base}+{7'b0,words,2'b0})>25'h0800000)
                        bus_fault<=1;
                    else begin
                        enabled<=1; left<=words; addr<=base; bus_fault<=0;
                        refill<=1; timer<=0; head<=0; tail<=0; lane<=0;
                    end
                end
            end
            if (valid && ready) begin
                if (fault) begin bus_fault<=1; if (!playing) begin enabled<=0; count<=0; end end
                else begin
                    fifo[tail]<=word; tail<=tail+1'b1;
                    addr<=addr+4; left<=left-1'b1;
                    refill<=count!=7 || pop;
                end
            end
            if (enabled && !playing && (count==8 || (left==0 && count!=0)))
                playing<=1;
            if (playing && tick) timer<=timer==0 ? divider-1'b1 : timer-1'b1;
            if (consume) begin
                sample<=fifo[head][{lane,3'b000}+:8];
                lane<=lane+1'b1;
                if (pop) head<=head+1'b1;
            end
            if (play_tick && count==0) begin
                if (left==0 || bus_fault) begin enabled<=0; playing<=0; end
                else underrun<=1;
            end
            case ({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
        end
    end
endmodule

module tt16_tile (
    input wire clk, rst_n, wr,
    input wire [3:0] sel,
    input wire [31:0] wdata,
    output wire [31:0] rdata,
    output reg valid,
    output wire busy,
    output reg [23:0] addr,
    output wire [31:0] data,
    input wire ready, fault
);
    reg [31:0] rows [0:7];
    reg [7:0] initialized;
    reg [23:0] base;
    reg [2:0] row;
    reg error, generating;
    reg [31:0] accumulator, step;
    reg [2:0] turn_row;
    wire [31:0] next_row;
    genvar lane_index;
    generate for(lane_index=0;lane_index<8;lane_index=lane_index+1) begin : lane_step
        assign next_row[4*lane_index+:4] = row < turn_row ?
            accumulator[4*lane_index+:4] + step[4*lane_index+:4] :
            accumulator[4*lane_index+:4] - step[4*lane_index+:4];
    end endgenerate
    assign data=rows[row];
    assign busy=valid || generating;
    assign rdata={29'b0,&initialized,error,busy};
    always @(posedge clk) begin
        if (!rst_n) begin
            initialized<=0; base<=0; row<=0; error<=0; valid<=0; addr<=0;
            generating<=0; accumulator<=0; step<=0; turn_row<=0;
        end else if (valid) begin
            if (ready) begin
                if (fault || row==7) begin valid<=0; error<=fault; end
                else begin row<=row+1'b1; addr<=addr+80; end
            end
        end else if (generating) begin
            rows[row]<=accumulator;
            if (row==7) begin generating<=0; valid<=1; row<=0; end
            else begin row<=row+1'b1; accumulator<=next_row; end
        end else if (wr) begin
            if (sel<8) begin rows[sel[2:0]]<=wdata; initialized[sel[2:0]]<=1; end
            if (sel==8) base<=wdata[23:0];
            if (sel==9) begin
                error<=!(wdata[0] ? (&initialized[2:0]) && rows[2][31:3]==0 :
                    (&initialized)) || base[1:0]!=0 || base>24'h0ffdcc;
                if ((wdata[0] ? (&initialized[2:0]) && rows[2][31:3]==0 :
                    (&initialized)) && base[1:0]==0 && base<=24'h0ffdcc) begin
                    row<=0; addr<=base; initialized<=0;
                    if (wdata[0]) begin
                        generating<=1;
                        accumulator<=rows[0]; step<=rows[1]; turn_row<=rows[2][2:0];
                    end else valid<=1;
                end
            end
        end
    end
endmodule
`default_nettype wire
