`timescale 1ns/1ps
`default_nettype none

// Optional four-channel square-wave PSG DATA_IO target.
module obc32_fb_psg (
    input wire clk,
    input wire tick,
    input wire rst_n,
    input wire cpu_rst_n,
    input wire acc_valid,
    input wire acc_io,
    input wire acc_write,
    input wire [19:0] acc_addr,
    input wire [31:0] acc_wdata,
    output wire acc_ready,
    output wire acc_error,
    output wire [31:0] acc_rdata,
    output wire audio,
    output wire [5:0] mix_level,
    output wire signed [7:0] bipolar
);
    reg pending, completed, response_error;
    reg captured_io, captured_write;
    reg [19:0] captured_addr;
    reg [31:0] captured_wdata;

    wire address_supported = acc_addr >= 20'h00030 && acc_addr <= 20'h00033;
    wire request_supported = acc_io && acc_write && address_supported;

    assign acc_ready = rst_n && cpu_rst_n && acc_valid &&
                       pending && !completed;
    assign acc_error = response_error;
    assign acc_rdata = 32'b0;

    wire write_complete = acc_ready && !response_error &&
                          captured_io && captured_write;

    reg enabled [0:3];
    reg [15:0] half_period [0:3];
    reg [3:0] volume [0:3];
    reg phase [0:3];
    reg [15:0] phase_counter [0:3];
    reg [11:0] duration_left [0:3];
    reg [15:0] duration_counter [0:3];

    wire [5:0] channel_level0 =
        (enabled[0] && phase[0]) ? {2'b0, volume[0]} : 6'b0;
    wire [5:0] channel_level1 =
        (enabled[1] && phase[1]) ? {2'b0, volume[1]} : 6'b0;
    wire [5:0] channel_level2 =
        (enabled[2] && phase[2]) ? {2'b0, volume[2]} : 6'b0;
    wire [5:0] channel_level3 =
        (enabled[3] && phase[3]) ? {2'b0, volume[3]} : 6'b0;
    wire [5:0] mixer_sum = channel_level0 + channel_level1 +
                           channel_level2 + channel_level3;
    integer channel;
    assign mix_level = mixer_sum;
    wire signed [7:0] b0 = $signed({4'b0,volume[0]});
    wire signed [7:0] b1 = $signed({4'b0,volume[1]});
    wire signed [7:0] b2 = $signed({4'b0,volume[2]});
    wire signed [7:0] b3 = $signed({4'b0,volume[3]});
    assign bipolar = (enabled[0] ? phase[0] ? b0 : -b0 : 8'sd0) +
                     (enabled[1] ? phase[1] ? b1 : -b1 : 8'sd0) +
                     (enabled[2] ? phase[2] ? b2 : -b2 : 8'sd0) +
                     (enabled[3] ? phase[3] ? b3 : -b3 : 8'sd0);

    reg [5:0] pwm_counter;
    assign audio = rst_n && (mixer_sum != 0) &&
                   (pwm_counter < mixer_sum);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            completed <= 1'b1;
            response_error <= 1'b0;
            captured_io <= 1'b0;
            captured_write <= 1'b0;
            captured_addr <= 20'b0;
            captured_wdata <= 32'b0;
            pwm_counter <= 6'b0;
            for (channel = 0; channel < 4; channel = channel + 1) begin
                enabled[channel] <= 1'b0;
                half_period[channel] <= 16'b0;
                volume[channel] <= 4'b0;
                phase[channel] <= 1'b0;
                phase_counter[channel] <= 16'b0;
                duration_left[channel] <= 12'b0;
                duration_counter[channel] <= 16'b0;
            end
        end else begin
            if (tick) pwm_counter <= pwm_counter + 1'b1;

            if (!cpu_rst_n) begin
                pending <= 1'b0;
                completed <= acc_valid;
                response_error <= 1'b0;
            end else if (!acc_valid) begin
                pending <= 1'b0;
                completed <= 1'b0;
                response_error <= 1'b0;
            end else if (!pending && !completed) begin
                pending <= 1'b1;
                captured_io <= acc_io;
                captured_write <= acc_write;
                captured_addr <= acc_addr;
                captured_wdata <= acc_wdata;
                response_error <= !request_supported;
            end else if (acc_ready) begin
                pending <= 1'b0;
                completed <= 1'b1;
            end

            if (tick) for (channel = 0; channel < 4; channel = channel + 1) begin
                if (enabled[channel]) begin
                    if (phase_counter[channel] == half_period[channel] - 1'b1) begin
                        phase_counter[channel] <= 16'b0;
                        phase[channel] <= !phase[channel];
                    end else begin
                        phase_counter[channel] <= phase_counter[channel] + 1'b1;
                    end

                    if (duration_left[channel] != 0) begin
                        if (duration_counter[channel] == 16'hffff) begin
                            duration_counter[channel] <= 16'b0;
                            if (duration_left[channel] == 1) begin
                                enabled[channel] <= 1'b0;
                                phase[channel] <= 1'b0;
                                phase_counter[channel] <= 16'b0;
                                duration_left[channel] <= 12'b0;
                            end else begin
                                duration_left[channel] <= duration_left[channel] - 1'b1;
                            end
                        end else begin
                            duration_counter[channel] <= duration_counter[channel] + 1'b1;
                        end
                    end
                end
            end

            if (write_complete) begin
                case (captured_addr[1:0])
                    2'd0: begin
                        half_period[0] <= captured_wdata[15:0];
                        volume[0] <= captured_wdata[19:16];
                        enabled[0] <= (captured_wdata[15:0] != 0) &&
                                       (captured_wdata[19:16] != 0);
                        phase[0] <= 1'b0;
                        phase_counter[0] <= 16'b0;
                        duration_left[0] <= captured_wdata[31:20];
                        duration_counter[0] <= 16'b0;
                    end
                    2'd1: begin
                        half_period[1] <= captured_wdata[15:0];
                        volume[1] <= captured_wdata[19:16];
                        enabled[1] <= (captured_wdata[15:0] != 0) &&
                                       (captured_wdata[19:16] != 0);
                        phase[1] <= 1'b0;
                        phase_counter[1] <= 16'b0;
                        duration_left[1] <= captured_wdata[31:20];
                        duration_counter[1] <= 16'b0;
                    end
                    2'd2: begin
                        half_period[2] <= captured_wdata[15:0];
                        volume[2] <= captured_wdata[19:16];
                        enabled[2] <= (captured_wdata[15:0] != 0) &&
                                       (captured_wdata[19:16] != 0);
                        phase[2] <= 1'b0;
                        phase_counter[2] <= 16'b0;
                        duration_left[2] <= captured_wdata[31:20];
                        duration_counter[2] <= 16'b0;
                    end
                    2'd3: begin
                        half_period[3] <= captured_wdata[15:0];
                        volume[3] <= captured_wdata[19:16];
                        enabled[3] <= (captured_wdata[15:0] != 0) &&
                                       (captured_wdata[19:16] != 0);
                        phase[3] <= 1'b0;
                        phase_counter[3] <= 16'b0;
                        duration_left[3] <= captured_wdata[31:20];
                        duration_counter[3] <= 16'b0;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
