`default_nettype none
module deluxe_service_mux #(parameter integer ENABLED=0) (
    input wire clk,rst_n,
    input wire c_valid,c_io,c_write,
    input wire [23:0] c_addr,
    input wire [31:0] c_wdata,
    output wire c_ready,c_error,
    output wire [31:0] c_rdata,
    output wire m_valid,
    input wire m_ready,m_error,
    input wire [31:0] m_rdata
);
    wire selected=c_io && c_addr>=24'd8 && c_addr<=24'd13;
    generate if(ENABLED!=0) begin : enabled
        wire ready,error;
        wire [31:0] rdata;
        multiplier_service service(
            .clk(clk),.rst_n(rst_n),.valid(c_valid && selected),
            .write(c_write),.addr(c_addr),.wdata(c_wdata),
            .ready(ready),.error(error),.rdata(rdata),
            .busy(),.result_valid());
        assign m_valid=c_valid && !selected;
        assign c_ready=selected ? ready : m_ready;
        assign c_error=selected ? error : m_error;
        assign c_rdata=selected ? rdata : m_rdata;
    end else begin : disabled
        assign m_valid=c_valid;
        assign c_ready=m_ready;
        assign c_error=m_error;
        assign c_rdata=m_rdata;
    end endgenerate
endmodule
`default_nettype wire
