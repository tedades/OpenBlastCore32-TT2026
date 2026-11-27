`timescale 1ns/1ps
`default_nettype none
module multiplier_service (
    input wire clk, rst_n,
    input wire valid, write,
    input wire [23:0] addr,
    input wire [31:0] wdata,
    output reg ready, error,
    output reg [31:0] rdata,
    output wire busy,
    output reg result_valid
);
    reg [31:0] operand_a, operand_b;
    reg have_a, have_b, running, low_read;
    wire done;
    wire [63:0] product;
    wire start = valid && ready && !error && write && addr==10;
    iterative_multiplier multiplier (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a(operand_a), .b(operand_b),
        .busy(busy), .done(done), .product(product)
    );
    always @* begin
        ready=valid;
        error=0;
        rdata=0;
        case (addr)
            8,9: error=!write || running || result_valid;
            10: error=!write || wdata!=1 || !have_a || !have_b || running || result_valid;
            11: begin
                error=write;
                rdata={30'b0,result_valid,running};
            end
            12: begin
                error=write || (!running && !result_valid);
                ready=valid && (error || result_valid);
                rdata=product[31:0];
            end
            13: begin
                error=write || !result_valid || !low_read;
                rdata=product[63:32];
            end
            default: error=1;
        endcase
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            operand_a<=0; operand_b<=0;
            have_a<=0; have_b<=0; running<=0;
            result_valid<=0; low_read<=0;
        end else begin
            if (done) begin
                result_valid<=1;
                running<=0;
            end
            if (valid && ready && !error) begin
                if (write && addr==8) begin operand_a<=wdata; have_a<=1; end
                if (write && addr==9) begin operand_b<=wdata; have_b<=1; end
                if (start) begin
                    running<=1;
                    have_a<=0; have_b<=0; low_read<=0;
                end
                if (!write && addr==12) low_read<=1;
                if (!write && addr==13) begin result_valid<=0; low_read<=0; end
            end
        end
    end
endmodule
`default_nettype wire
