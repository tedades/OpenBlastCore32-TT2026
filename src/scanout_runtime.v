`default_nettype none

module obc32_psram_scanout_runtime (
    input wire clk, rst_n, pixel_enable, enable, clear_faults,
    input wire [19:0] framebuffer_base,
    input wire commit,
    input wire [19:0] commit_base,
    input wire commit_mono,
    output wire commit_busy,
    output reg commit_done,
    output reg [19:0] active_base,
    output reg active_mono,
    output wire primed_status, active_status,
    input wire palette_write,
    input wire [3:0] palette_index,
    input wire [5:0] palette_rgb,
    input wire [1:0] palette_coverage,
    input wire alternate_color_write,
    input wire [5:0] alternate_color_data,
    output wire hsync_n, vsync_n,
    output wire [5:0] rgb,
    output wire frame_start, vblank_start,
    output wire memory_valid, memory_accept,
    output wire [19:0] memory_addr,
    input wire memory_ready, memory_error,
    input wire [31:0] memory_rdata,
    output reg underrun, fetch_error,
    output wire fetching, reservation
);
    localparam DISABLED = 0, INITIALIZING = 1, ACTIVE = 2, WAIT_BLANK = 3;
    reg [1:0] state;
    wire [9:0] x, y;
    wire active;
    obc32_fb_raster_runtime raster (
        .clk(clk), .rst_n(rst_n), .pixel_enable(pixel_enable),
        .pixel_x(x), .pixel_y(y), .hsync_n(hsync_n), .vsync_n(vsync_n),
        .active(active), .frame_start(frame_start)
    );

    reg [31:0] fifo [0:7];
    reg [7:0] palette [0:15];
    reg [5:0] alternate_color;
    reg [2:0] head, tail;
    reg [3:0] count;
    reg [7:0] fill_row;
    reg [4:0] fill_word;
    reg [19:0] fill_base;
    reg busy, gap, failed, row_good, draining, pending;
    reg [19:0] pending_base;
    reg pending_mono;
    wire [7:0] display_row = active_mono ? y[8:1] : {1'b0, y[8:2]};
    wire [7:0] next_row = y == 479 ? 8'd0 : display_row + 1'b1;
    wire last_repeat = active_mono ? y[0] : y[1:0] == 3;
    wire [7:0] next_fill_row = last_repeat ? next_row : display_row;
    wire [4:0] last_word = active_mono ? 5'd9 : 5'd19;
    wire base_valid = active_base[1:0] == 0 &&
                      active_base <= 20'hfda80;
    wire row_matches = fill_base == active_base && fill_row == display_row;
    wire row_start_good = count >= 4 && row_matches && !failed;
    wire primed = state == INITIALIZING && count >= 4 &&
                  fill_row == 0 && fill_base == active_base && !failed;
    wire start_pixel = state == INITIALIZING && x == 0 && y == 0 && primed;
    wire valid_pixel = row_matches && count != 0 && !failed &&
                       (x == 0 ? row_start_good : row_good);
    wire [3:0] color = active_mono ? {3'b0, fifo[head][{x[5:4], ~x[3:1]}]} :
                              fifo[head][{x[4:2], 2'b00} +: 4];
    wire word_end = active_mono ? x[5:0] == 63 : x[4:0] == 31;
    wire [1:0] coverage = active_mono ? 2'b00 : palette[color][7:6];
    wire use_base_color = coverage == 2'b00 ||
        (coverage == 2'b01 && (x[0] || !y[0])) ||
        (coverage == 2'b10 && (x[0] == y[0])) ||
        (coverage == 2'b11 && (!x[0] && !y[0]));
    wire word_start = active_mono ? x[5:0] == 0 : x[4:0] == 0;
    wire pop = state == ACTIVE && enable && pixel_enable && active &&
               word_end && count != 0;
    wire line_refill = state == ACTIVE && enable &&
                       pixel_enable && x == 640 && y < 480;
    wire accept = memory_valid && memory_ready;
    wire discard = !enable || draining || pending || commit;
    wire write_current = accept && !discard && !memory_error;

    assign rgb = rst_n && enable && !pending && !commit && active &&
                 (state == ACTIVE || start_pixel) &&
                 valid_pixel ? (use_base_color ? palette[color][5:0] :
                                alternate_color) : 6'b0;
    assign fetching = busy || draining;
    // Full FIFOs yield; accepted reads and drains still retain their reservation.
    assign reservation = fetching && (draining || count < 8);
    assign memory_valid = rst_n && ((busy && !gap && count < 8) || draining);
    assign memory_accept = memory_valid;
    assign memory_addr = fill_base +
                         (active_mono ? ({9'b0, fill_row, 3'b0} + {7'b0, fill_row, 5'b0}) :
                                 ({8'b0, fill_row, 4'b0} + {6'b0, fill_row, 6'b0})) +
                         {13'b0, fill_word, 2'b0};

    assign commit_busy = pending || commit_done;
    assign primed_status = primed;
    assign active_status = state == ACTIVE && enable && !pending && !commit;
    assign vblank_start = pixel_enable && x == 0 && y == 480;
    integer p;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (p = 0; p < 16; p = p + 1) palette[p] <= 0;
            alternate_color <= 0;
            state <= DISABLED;
            head <= 0; tail <= 0; count <= 0;
            fill_row <= 0; fill_word <= 0; fill_base <= 0;
            busy <= 0; gap <= 0; failed <= 0; row_good <= 0; draining <= 0;
            underrun <= 0; fetch_error <= 0;
            pending <= 0; pending_base <= 0; pending_mono <= 0;
            active_base <= 0; active_mono <= 0; commit_done <= 0;
        end else begin
            commit_done <= 0;
            if (palette_write) palette[palette_index] <= {palette_coverage, palette_rgb};
            if (alternate_color_write) alternate_color <= alternate_color_data;
            if (clear_faults) begin underrun <= 0; fetch_error <= 0; end
            if (enable && pixel_enable && x == 0 && y == 0 &&
                (state == DISABLED || state == WAIT_BLANK || pending || commit))
                underrun <= 1;
            if (commit && !pending) begin
                pending <= 1;
                pending_base <= commit_base;
                pending_mono <= commit_mono;
            end
            if (!enable || draining || pending || commit) begin
                if (accept && memory_error) fetch_error <= 1;
                state <= DISABLED;
                row_good <= 0;
                head <= 0; tail <= 0; count <= 0;
                if (draining) begin
                    if (accept) begin draining <= 0; busy <= 0; gap <= 0; end
                end else if (memory_valid && !memory_ready) begin
                    draining <= 1;
                end else begin
                    busy <= 0; gap <= 0;
                end
                if (pending && !draining && !memory_valid) begin
                    active_base <= pending_base;
                    active_mono <= pending_mono;
                    pending <= 0;
                    commit_done <= 1;
                end
            end else if (state == DISABLED) begin
                if (!commit_done) active_base <= framebuffer_base;
                state <= WAIT_BLANK;
            end else if (state == WAIT_BLANK && y >= 480) begin
                state <= INITIALIZING;
                head <= 0; tail <= 0; count <= 0;
                fill_row <= 0; fill_word <= 0; fill_base <= active_base;
                failed <= !base_valid; busy <= base_valid; gap <= 0;
                if (!base_valid) fetch_error <= 1;
            end else if (state != WAIT_BLANK) begin
                if (state == INITIALIZING && pixel_enable && x == 0 && y == 0) begin
                    if (primed) begin state <= ACTIVE; row_good <= 1; end
                    else underrun <= 1;
                end
                if (state == ACTIVE && pixel_enable && x == 0 && y < 480) begin
                    row_good <= row_start_good;
                    if (!row_start_good) underrun <= 1;
                end
                if ((state == ACTIVE || start_pixel) && pixel_enable && active &&
                    word_start && !valid_pixel) underrun <= 1;
                if (line_refill && !busy) begin
                    head <= 0; tail <= 0; count <= 0;
                    fill_row <= next_fill_row; fill_word <= 0;
                    fill_base <= active_base; busy <= base_valid;
                    gap <= 0; failed <= !base_valid;
                    if (!base_valid) fetch_error <= 1;
                end else begin
                    if (line_refill && busy) underrun <= 1;
                    if (gap) gap <= 0;
                    if (accept) begin
                        gap <= 1;
                        if (write_current) begin
                            fifo[tail] <= memory_rdata;
                            tail <= tail + 1'b1;
                        end
                        if (memory_error) begin
                            failed <= 1; fetch_error <= 1; row_good <= 0;
                            busy <= 0;
                            if (state == ACTIVE) underrun <= 1;
                        end else if (fill_word == last_word) begin
                            fill_word <= 0; busy <= 0;
                        end else fill_word <= fill_word + 1'b1;
                    end
                    case ({write_current, pop})
                        2'b10: count <= count + 1'b1;
                        2'b01: begin count <= count - 1'b1; head <= head + 1'b1; end
                        2'b11: head <= head + 1'b1;
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule

module obc32_fb_raster_runtime (
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
