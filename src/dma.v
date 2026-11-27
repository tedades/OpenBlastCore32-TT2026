`default_nettype none

// Experimental word-copy master. The single data register is a transfer
// holding register, not a cache or a queue. Descriptors must not overlap.
module obc32_copy_dma #(parameter integer ADDRESS_BITS=23) (
    input wire clk, rst_n, start,
    input wire [31:0] source, destination, length,
    output wire busy,
    output reg done, error,
    output reg [3:0] error_code,
    output reg [31:0] transferred,
    output wire acc_valid, acc_io, acc_write,
    output wire [23:0] acc_addr,
    output wire [31:0] acc_wdata,
    input wire acc_ready, acc_error,
    input wire [31:0] acc_rdata
);
    localparam IDLE=3'd0, READ=3'd1, READ_GAP=3'd2, WRITE=3'd3, WRITE_GAP=3'd4;
    reg [2:0] state;
    reg [23:0] src, dst;
    reg [31:0] remaining, held_data;
    localparam [32:0] ADDRESS_LIMIT = 33'd1 << ADDRESS_BITS;
    wire [32:0] src_end={1'b0,source}+{1'b0,length};
    wire [32:0] dst_end={1'b0,destination}+{1'b0,length};
    wire unaligned=|source[1:0] || |destination[1:0] || |length[1:0];
    wire out_of_range={1'b0,source}>=ADDRESS_LIMIT ||
        {1'b0,destination}>=ADDRESS_LIMIT ||
        src_end>ADDRESS_LIMIT || dst_end>ADDRESS_LIMIT;
    wire overlap=length!=0 && {1'b0,source}<dst_end && {1'b0,destination}<src_end;
    assign busy=state!=IDLE;
    assign acc_valid=rst_n && (state==READ || state==WRITE);
    assign acc_io=1'b0;
    assign acc_write=state==WRITE;
    assign acc_addr=state==WRITE ? dst : src;
    assign acc_wdata=state==WRITE ? held_data : 32'b0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;done<=0;error<=0;error_code<=0;transferred<=0;
            src<=0;dst<=0;remaining<=0;held_data<=0;
        end else case(state)
            IDLE: if(start) begin
                done<=0;error<=0;error_code<=0;transferred<=0;
                if(unaligned || out_of_range || overlap) begin
                    done<=1;error<=1;
                    error_code<=unaligned ? 4'd1 : out_of_range ? 4'd2 : 4'd3;
                end else if(length==0) done<=1;
                else begin
                    src<=source[23:0];dst<=destination[23:0];remaining<=length;
                    state<=READ;
                end
            end
            READ: if(acc_ready) begin
                if(acc_error) begin state<=IDLE;done<=1;error<=1;error_code<=4;end
                else begin held_data<=acc_rdata;state<=READ_GAP;end
            end
            READ_GAP: state<=WRITE;
            WRITE: if(acc_ready) begin
                if(acc_error) begin state<=IDLE;done<=1;error<=1;error_code<=5;end
                else begin
                    transferred<=transferred+4;
                    remaining<=remaining-4;
                    if(remaining==4) begin state<=IDLE;done<=1;end
                    else begin src<=src+4;dst<=dst+4;state<=WRITE_GAP;end
                end
            end
            WRITE_GAP: state<=READ;
            default: begin state<=IDLE;done<=1;error<=1;error_code<=6;end
        endcase
    end
    generate if ((ADDRESS_BITS != 20) &&
                 (ADDRESS_BITS != 23) &&
                 (ADDRESS_BITS != 24)) begin : gen_bad_dma_address_bits
        initial $fatal(1, "ADDRESS_BITS must be 20, 23, or 24");
    end endgenerate
endmodule

// Explicit IN/OUT port IDs, not LD/ST byte addresses. The CPU's existing
// DATA_IO interface already distinguishes these spaces.
module obc32_dma_registers (
    input wire clk, rst_n,
    input wire acc_valid, acc_io, acc_write,
    input wire [23:0] acc_addr,
    input wire [31:0] acc_wdata,
    output wire acc_ready,
    output reg acc_error,
    output reg [31:0] acc_rdata,
    output reg start,
    output reg [31:0] source, destination, length,
    input wire busy, done, error,
    input wire [3:0] error_code,
    input wire [31:0] transferred
);
    reg pending,completed;
    assign acc_ready=rst_n && acc_valid && pending && !completed;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pending<=0;completed<=0;acc_error<=0;acc_rdata<=0;start<=0;
            source<=0;destination<=0;length<=0;
        end else begin
            start<=0;
            if(!acc_valid) begin pending<=0;completed<=0;end
            else if(!pending && !completed) begin
                pending<=1;acc_error<=0;acc_rdata<=0;
                if(!acc_io) acc_error<=1;
                else if(acc_write) begin
                    acc_error<=busy || start ||
                        !(acc_addr>=24'h60 && acc_addr<=24'h63) ||
                        (acc_addr==24'h63 && acc_wdata!=1);
                end else case(acc_addr)
                    24'h60:acc_rdata<=source;
                    24'h61:acc_rdata<=destination;
                    24'h62:acc_rdata<=length;
                    24'h64:acc_rdata<={24'b0,error_code,1'b0,error,done,busy};
                    24'h65:acc_rdata<=transferred;
                    default:acc_error<=1;
                endcase
            end else if(acc_ready) begin
                pending<=0;completed<=1;
                if(!acc_error && acc_write) case(acc_addr)
                    24'h60:source<=acc_wdata;
                    24'h61:destination<=acc_wdata;
                    24'h62:length<=acc_wdata;
                    24'h63:start<=1;
                endcase
            end
        end
    end
endmodule

// Round robin per transaction, never per cycle. A grant survives stalls;
// every completion is followed by a downstream valid-low edge.
module obc32_dma_arbiter (
    input wire clk,rst_n,
    input wire c_valid,c_io,c_write,
    input wire [23:0] c_addr,
    input wire [31:0] c_wdata,
    output wire c_ready,c_error,
    output wire [31:0] c_rdata,
    input wire d_valid,d_io,d_write,
    input wire [23:0] d_addr,
    input wire [31:0] d_wdata,
    output wire d_ready,d_error,
    output wire [31:0] d_rdata,
    output wire m_valid,m_io,m_write,
    output wire [23:0] m_addr,
    output wire [31:0] m_wdata,
    input wire m_ready,m_error,
    input wire [31:0] m_rdata,
    output wire dma_granted
);
    reg granted,owner,prefer_dma;
    assign dma_granted=rst_n && granted && owner;
    assign m_valid=rst_n && granted && (owner ? d_valid : c_valid);
    assign m_io=owner ? d_io : c_io;
    assign m_write=owner ? d_write : c_write;
    assign m_addr=owner ? d_addr : c_addr;
    assign m_wdata=owner ? d_wdata : c_wdata;
    assign c_ready=m_valid && !owner && m_ready;
    assign d_ready=m_valid && owner && m_ready;
    assign c_error=c_ready && m_error;
    assign d_error=d_ready && m_error;
    assign c_rdata=m_rdata;
    assign d_rdata=m_rdata;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin granted<=0;owner<=0;prefer_dma<=0;end
        else if(granted) begin
            if(m_valid && m_ready) begin granted<=0;prefer_dma<=!owner;end
        end else if(c_valid || d_valid) begin
            granted<=1;
            owner<=d_valid && (!c_valid || prefer_dma);
        end
    end
endmodule

module obc32_dma_subsystem #(
    parameter integer ENABLE_DMA=1,
    parameter integer ADDRESS_BITS=23
) (
    input wire clk,rst_n,
    input wire c_valid,c_io,c_write,
    input wire [23:0] c_addr,
    input wire [31:0] c_wdata,
    output wire c_ready,c_error,
    output wire [31:0] c_rdata,
    output wire m_valid,m_io,m_write,
    output wire [23:0] m_addr,
    output wire [31:0] m_wdata,
    input wire m_ready,m_error,
    input wire [31:0] m_rdata,
    output wire cpu_request_blocked,
    output wire dma_busy,dma_done,dma_error,
    output wire [3:0] dma_code,
    output wire [31:0] dma_transferred
);
    generate if(ENABLE_DMA!=0) begin : enabled
        wire regs_select=c_io && c_addr>=24'h60 && c_addr<=24'h65;
        wire reg_ready,reg_error,start,d_valid,d_io,d_write,d_ready,d_error;
        wire [31:0] reg_data,source,destination,length,d_wdata,d_rdata;
        wire [23:0] d_addr;
        wire arb_ready,arb_error,dma_granted;
        wire [31:0] arb_data;
        // Expose an I/O request stalled specifically behind the retained DMA owner.
        assign cpu_request_blocked=c_valid && !regs_select && dma_granted && d_valid;
        assign c_ready=regs_select ? reg_ready : arb_ready;
        assign c_error=regs_select ? reg_error : arb_error;
        assign c_rdata=regs_select ? reg_data : arb_data;
        obc32_dma_registers registers(
            .clk(clk),.rst_n(rst_n),.acc_valid(c_valid&&regs_select),.acc_io(c_io),
            .acc_write(c_write),.acc_addr(c_addr),.acc_wdata(c_wdata),
            .acc_ready(reg_ready),.acc_error(reg_error),.acc_rdata(reg_data),
            .start(start),.source(source),.destination(destination),.length(length),
            .busy(dma_busy),.done(dma_done),.error(dma_error),
            .error_code(dma_code),.transferred(dma_transferred));
        obc32_copy_dma #(.ADDRESS_BITS(ADDRESS_BITS)) dma(
            .clk(clk),.rst_n(rst_n),.start(start),.source(source),.destination(destination),
            .length(length),.busy(dma_busy),.done(dma_done),.error(dma_error),
            .error_code(dma_code),.transferred(dma_transferred),
            .acc_valid(d_valid),.acc_io(d_io),.acc_write(d_write),.acc_addr(d_addr),
            .acc_wdata(d_wdata),.acc_ready(d_ready),.acc_error(d_error),.acc_rdata(d_rdata));
        obc32_dma_arbiter arbiter(
            .clk(clk),.rst_n(rst_n),.c_valid(c_valid&&!regs_select),.c_io(c_io),
            .c_write(c_write),.c_addr(c_addr),.c_wdata(c_wdata),
            .c_ready(arb_ready),.c_error(arb_error),.c_rdata(arb_data),
            .d_valid(d_valid),.d_io(d_io),.d_write(d_write),.d_addr(d_addr),.d_wdata(d_wdata),
            .d_ready(d_ready),.d_error(d_error),.d_rdata(d_rdata),
            .m_valid(m_valid),.m_io(m_io),.m_write(m_write),.m_addr(m_addr),.m_wdata(m_wdata),
            .m_ready(m_ready),.m_error(m_error),.m_rdata(m_rdata),
            .dma_granted(dma_granted));
    end else begin : disabled
        assign cpu_request_blocked=1'b0;
        assign m_valid=c_valid && rst_n;
        assign m_io=c_io;
        assign m_write=c_write;
        assign m_addr=c_addr;
        assign m_wdata=c_wdata;
        assign c_ready=m_ready && rst_n;
        assign c_error=m_error;
        assign c_rdata=m_rdata;
        assign dma_busy=0;
        assign dma_done=0;
        assign dma_error=0;
        assign dma_code=0;
        assign dma_transferred=0;
    end endgenerate
endmodule
`default_nettype wire
