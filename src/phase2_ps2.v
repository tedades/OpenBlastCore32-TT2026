`default_nettype none

module phase2_ps2 #(
    parameter integer FILTER_CYCLES=8,
    parameter integer TIMEOUT_CYCLES=50400,
    parameter integer FIFO_LOG2=4
) (
    input wire clk, rst_n,
    input wire ps2_clk, ps2_data,
    input wire pop,
    output wire [7:0] data,
    output wire empty, full,
    output wire [FIFO_LOG2:0] count,
    output reg [3:0] faults,
    input wire clear_faults
);
    localparam integer FW=(FILTER_CYCLES<2) ? 1 : $clog2(FILTER_CYCLES);
    localparam integer TW=(TIMEOUT_CYCLES<2) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam integer DEPTH=1<<FIFO_LOG2;
    generate if(FILTER_CYCLES<1 || TIMEOUT_CYCLES<=FILTER_CYCLES ||
                FIFO_LOG2<1 || FIFO_LOG2>8) begin : invalid_parameters
        initial $fatal(1,"Invalid PS2 filter/timeout/FIFO parameters");
    end endgenerate
    (* async_reg="true" *) reg clock_meta, clock_sync, data_meta, data_sync;
    reg clock_filtered;
    reg [FW-1:0] filter_count;
    wire falling=clock_filtered && !clock_sync &&
                 filter_count==FILTER_CYCLES-1;
    reg [3:0] bit_index;
    reg [7:0] shift_byte;
    reg parity;
    reg [TW-1:0] age;
    reg [7:0] fifo[0:DEPTH-1];
    reg [FIFO_LOG2-1:0] rd,wr;
    reg [FIFO_LOG2:0] used;
    wire take=pop && !empty;
    wire frame_done=falling && bit_index==10;
    wire frame_ok=frame_done && data_sync && parity;
    wire put=frame_ok && (!full || take);
    assign count=used;
    assign empty=used==0;
    assign full=used==DEPTH;
    assign data=empty ? 8'b0 : fifo[rd];
    always @(posedge clk) begin
        if(!rst_n) begin
            clock_meta<=1; clock_sync<=1; data_meta<=1; data_sync<=1;
            clock_filtered<=1; filter_count<=0;
            bit_index<=0; shift_byte<=0; parity<=0; age<=0;
            rd<=0; wr<=0; used<=0; faults<=0;
        end else begin
            clock_meta<=ps2_clk; clock_sync<=clock_meta;
            data_meta<=ps2_data; data_sync<=data_meta;
            if(clock_sync==clock_filtered) filter_count<=0;
            else if(filter_count==FILTER_CYCLES-1) begin
                clock_filtered<=clock_sync; filter_count<=0;
            end else filter_count<=filter_count+1'b1;

            if(clear_faults) faults<=0;
            if(falling) begin
                age<=0;
                if(bit_index==0) begin
                    if(!data_sync) begin bit_index<=1; parity<=0; end
                    else faults[0]<=1;
                end else if(bit_index<=8) begin
                    shift_byte[bit_index-1]<=data_sync;
                    parity<=parity ^ data_sync;
                    bit_index<=bit_index+1'b1;
                end else if(bit_index==9) begin
                    parity<=parity ^ data_sync;
                    bit_index<=10;
                end else begin
                    bit_index<=0;
                    if(!data_sync) faults[0]<=1;
                    if(!parity) faults[1]<=1;
                    if(frame_ok && full && !take) faults[3]<=1;
                end
            end else if(bit_index!=0) begin
                if(age==TIMEOUT_CYCLES-1) begin
                    bit_index<=0; age<=0; faults[2]<=1;
                end else age<=age+1'b1;
            end
            if(take) rd<=rd+1'b1;
            if(put) begin fifo[wr]<=shift_byte; wr<=wr+1'b1; end
            case({put,take})
                2'b10: used<=used+1'b1;
                2'b01: used<=used-1'b1;
                default: begin end
            endcase
        end
    end
endmodule
`default_nettype wire
