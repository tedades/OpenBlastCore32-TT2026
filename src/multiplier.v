`timescale 1ns/1ps
`default_nettype none

// Standalone experiment, not an instruction or production CPU peripheral.
module iterative_multiplier (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [31:0] a,
    input wire [31:0] b,
    output reg busy,
    output reg done,
    output reg [63:0] product
);
    reg [31:0] multiplicand;
    reg [4:0] step;
    wire [32:0] sum = {1'b0, product[63:32]} +
                      {1'b0, (product[0] ? multiplicand : 32'b0)};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            multiplicand <= 0;
            product <= 0;
            step <= 0;
            busy <= 0;
            done <= 0;
        end else begin
            done <= 0;
            if (busy) begin
                // Combined accumulator/multiplier shift needs only a 33-bit sum.
                product <= {sum, product[31:1]};
                if (step == 31) begin
                    busy <= 0;
                    done <= 1;
                end else begin
                    step <= step + 1'b1;
                end
            end else if (start) begin
                multiplicand <= a;
                product <= {32'b0, b};
                step <= 0;
                busy <= 1;
            end
        end
    end
endmodule

// Unregistered comparison point: no intrinsic cycle latency or clock frequency.
module combinational_multiplier (
    input wire [31:0] a,
    input wire [31:0] b,
    output wire [63:0] product
);
    assign product = a * b;
endmodule

`default_nettype wire
