`default_nettype none

module phase2_vga_raster (
    input wire pixel_clk, rst_n,
    output reg [9:0] pixel_x, pixel_y,
    output wire hsync_n, vsync_n, active,
    output wire frame_start
);
    always @(posedge pixel_clk) begin
        if (!rst_n) begin
            pixel_x <= 0;
            pixel_y <= 0;
        end else if (pixel_x == 799) begin
            pixel_x <= 0;
            pixel_y <= (pixel_y == 524) ? 10'd0 : pixel_y + 1'b1;
        end else begin
            pixel_x <= pixel_x + 1'b1;
        end
    end
    assign active = (pixel_x < 640) && (pixel_y < 480);
    assign hsync_n = !((pixel_x >= 656) && (pixel_x < 752));
    assign vsync_n = !((pixel_y >= 490) && (pixel_y < 492));
    assign frame_start = (pixel_x == 0) && (pixel_y == 0);
endmodule

module phase2_vga_pattern #(
    parameter integer SCALE_LOG2 = 2
) (
    input wire pixel_clk, rst_n,
    output wire hsync_n, vsync_n, active, frame_start,
    output wire [9:0] pixel_x, pixel_y,
    output wire [8:0] logical_x, logical_y,
    output wire [3:0] red, green, blue
);
    generate if (SCALE_LOG2 != 1 && SCALE_LOG2 != 2) begin : invalid_scale
        initial $fatal(1, "phase2_vga_pattern supports scale x2 or x4 only");
    end endgenerate
    phase2_vga_raster raster (
        .pixel_clk(pixel_clk), .rst_n(rst_n), .pixel_x(pixel_x), .pixel_y(pixel_y),
        .hsync_n(hsync_n), .vsync_n(vsync_n), .active(active), .frame_start(frame_start)
    );
    assign logical_x = pixel_x >> SCALE_LOG2;
    assign logical_y = pixel_y >> SCALE_LOG2;
    wire border = logical_x == 0 || logical_y == 0 ||
                  logical_x == ((640 >> SCALE_LOG2) - 1) ||
                  logical_y == ((480 >> SCALE_LOG2) - 1);
    assign red = !active ? 4'h0 : border ? 4'hf : logical_x[3:0];
    assign green = !active ? 4'h0 : border ? 4'hf : logical_y[3:0];
    assign blue = !active ? 4'h0 : border ? 4'hf :
                  ((logical_x[4] ^ logical_y[4]) ? 4'hf : 4'h0);
endmodule
`default_nettype wire
