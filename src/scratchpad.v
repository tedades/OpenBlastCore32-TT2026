`default_nettype none
module study_data_scratchpad #(
    parameter integer BYTES=0
) (
    input wire clk, rst_n, run,
    input wire valid, io, write,
    input wire [23:0] addr,
    input wire [31:0] wdata,
    output wire ready, error,
    output wire [31:0] rdata,
    output wire m_valid,
    input wire m_ready, m_error,
    input wire [31:0] m_rdata
);
    generate if(BYTES==0) begin : off
        assign m_valid=valid;
        assign ready=m_ready;
        assign error=m_error;
        assign rdata=m_rdata;
    end else begin : on
        localparam integer WORDS=BYTES/4;
        localparam integer INDEX_BITS=$clog2(WORDS);
        localparam [23:0] BASE=24'h025000;
        wire selected=!io && addr>=BASE && addr<BASE+BYTES;
        wire [INDEX_BITS-1:0] index=addr[INDEX_BITS+1:2];
        reg [31:0] words [0:WORDS-1];
        reg [WORDS-1:0] written;
        reg done, fault;
        reg [31:0] result;
        assign m_valid=valid && !selected;
        assign ready=selected ? rst_n && valid && done && run : m_ready;
        assign error=selected ? fault : m_error;
        assign rdata=selected ? result : m_rdata;
        always @(posedge clk) begin
            if(!rst_n) begin
                written<=0; done<=0; fault<=0; result<=0;
            end else if(ready && selected) begin
                done<=0;
            end else if(valid && selected && run && !done) begin
                done<=1;
                fault<=|addr[1:0] || (!write && !written[index]);
                result<=0;
                if(addr[1:0]==0) begin
                    if(write) begin
                        words[index]<=wdata;
                        written[index]<=1;
                    end else if(written[index]) result<=words[index];
                end
            end
        end
    end endgenerate
endmodule
`default_nettype wire
