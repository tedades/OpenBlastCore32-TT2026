`default_nettype none

// Eight-word circular FIFO; each physical row is streamed from PSRAM.
module obc32_psram_scanout (
    input wire clk, rst_n, pixel_enable, enable, clear_faults,
    input wire [19:0] framebuffer_base,
    input wire palette_write,
    input wire [3:0] palette_index,
    input wire [5:0] palette_rgb,
    output wire hsync_n, vsync_n,
    output wire [5:0] rgb,
    output wire frame_start,
    output wire vblank_start,
    output wire memory_valid,
    output wire memory_accept,
    output wire [19:0] memory_addr,
    input wire memory_ready, memory_error,
    input wire [31:0] memory_rdata,
    output reg underrun, fetch_error,
    output wire fetching
);
    localparam FIFO_DEPTH = 8;
    wire [9:0] x, y;
    wire active;
    obc32_fb_raster raster (
        .clk(clk), .rst_n(rst_n), .pixel_enable(pixel_enable),
        .pixel_x(x), .pixel_y(y), .hsync_n(hsync_n), .vsync_n(vsync_n),
        .active(active), .frame_start(frame_start)
    );

    reg [31:0] fifo [0:FIFO_DEPTH-1];
    reg [5:0] palette [0:15];
    reg [2:0] head, tail;
    reg [3:0] count;
    reg [6:0] fill_row;
    reg [4:0] fill_word;
    reg busy, gap, failed, row_good;
    reg [19:0] fill_base;
    wire [6:0] display_row = y[8:2];
    wire [6:0] next_row = y == 479 ? 7'd0 : y[8:2] + 1'b1;
    wire [4:0] display_word = x[9:5];
    wire display_valid = enable && fill_base == framebuffer_base &&
                         count != 0 && fill_row == display_row;
    wire [3:0] color = fifo[head][{x[4:2], 2'b00} +: 4];
    wire [6:0] next_fill_row = y[1:0] == 3 ? next_row : display_row;
    wire line_refill = pixel_enable && x == 640 && y < 480;
    wire accept = memory_valid && memory_ready;
    wire pop = enable && pixel_enable && active && x[4:0] == 31 && count != 0;
    wire keep_response = enable && fill_base == framebuffer_base;
    wire write_current = accept && keep_response;

    assign rgb = rst_n && enable && active && row_good && display_valid ?
                 palette[color] : 6'b0;
    assign fetching = busy;
    assign vblank_start = pixel_enable && x == 0 && y == 480;
    assign memory_valid = rst_n && busy && !gap && count < FIFO_DEPTH;
    assign memory_accept = memory_valid;
    assign memory_addr = fill_base + {7'b0, fill_row, 6'b0} +
                         {9'b0, fill_row, 4'b0} + {13'b0, fill_word, 2'b0};

    integer p;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (p = 0; p < 16; p = p + 1) palette[p] <= 0;
            head <= 0; tail <= 0; count <= 0; fill_row <= 0;
            fill_word <= 0; busy <= 0; gap <= 0; failed <= 0;
            fill_base <= 0; row_good <= 0; underrun <= 0; fetch_error <= 0;
        end else begin
            if (palette_write) palette[palette_index] <= palette_rgb;
            if (clear_faults) begin underrun <= 0; fetch_error <= 0; end
            if (!enable || fill_base != framebuffer_base) begin
                row_good <= 0;
                head <= 0;
                tail <= 0;
                count <= 0;
            end
            if (enable && pixel_enable && x == 0 && y < 480) begin
                row_good <= count >= 4 && fill_row == display_row && !failed;
                if (count < 4 || fill_row != display_row || failed)
                    underrun <= 1;
            end
            if (enable && pixel_enable && active && x[4:0] == 0 && count == 0) begin
                row_good <= 0;
                underrun <= 1;
            end
            if (line_refill) begin
                if (busy) underrun <= 1;
                else begin
                    head <= 0;
                    tail <= 0;
                    count <= 0;
                    fill_row <= next_fill_row;
                    fill_word <= 0;
                    fill_base <= framebuffer_base;
                    busy <= enable && framebuffer_base[1:0] == 0 &&
                            framebuffer_base <= 20'hfda80;
                    gap <= 0;
                    failed <= 0;
                    if (enable && (framebuffer_base[1:0] != 0 ||
                                   framebuffer_base > 20'hfda80))
                        fetch_error <= 1;
                end
            end else begin
                if (gap) gap <= 0;
                if (accept) begin
                    gap <= 1;
                    if (write_current) begin
                        fifo[tail] <= memory_error ? 32'b0 : memory_rdata;
                        tail <= tail + 1'b1;
                    end
                    if (memory_error) begin
                        failed <= 1;
                        fetch_error <= 1;
                        row_good <= 0;
                    end
                    if (fill_word == 19) begin
                        fill_word <= 0;
                        busy <= 0;
                    end else fill_word <= fill_word + 1'b1;
                end
                if (!keep_response) begin
                    head <= 0;
                    tail <= 0;
                    count <= 0;
                end else begin
                    case ({write_current, pop})
                        2'b10: count <= count + 1'b1;
                        2'b01: begin
                            count <= count - 1'b1;
                            head <= head + 1'b1;
                        end
                        2'b11: head <= head + 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule

module obc32_fb_raster (
    input wire clk, rst_n, pixel_enable,
    output reg [9:0] pixel_x, pixel_y,
    output wire hsync_n, vsync_n, active, frame_start
);
    always @(posedge clk) begin
        if (!rst_n) begin pixel_x <= 0; pixel_y <= 0; end
        else if (pixel_enable) begin
            if (pixel_x == 799) begin
                pixel_x <= 0;
                pixel_y <= pixel_y == 524 ? 10'd0 : pixel_y + 1'b1;
            end else pixel_x <= pixel_x + 1'b1;
        end
    end
    assign active = pixel_x < 640 && pixel_y < 480;
    assign hsync_n = !(pixel_x >= 656 && pixel_x < 752);
    assign vsync_n = !(pixel_y >= 490 && pixel_y < 492);
    assign frame_start = pixel_enable && pixel_x == 0 && pixel_y == 0;
endmodule

`default_nettype wire
