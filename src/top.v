`default_nettype none

// Experimental TT harness payload. No program, assets, framebuffer or pad cells.
module tt_um_openblastcore32_tt16 #(
    parameter integer PSRAM_ADDRESS_BITS=23,
    parameter integer LANE_SHIFTS=1,
    parameter integer PAD_BYTES=32,
    parameter integer COVERAGE=1,
    parameter integer AUDIO=1,
    parameter integer TILE=1,
    parameter integer EXP_ISA=1,
    parameter integer REPLAY=1
) (
    input wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input wire [7:0] uio_in,
    output wire [7:0] uio_out, uio_oe,
    input wire ena, clk, rst_n
);
    wire cv, ci, cw, cr, ce, sv, sr, se, mv, mi, mw, mr, me;
    wire [23:0] ca, ma;
    wire [31:0] cd, cq, sq, md, mq;
    wire [7:0] cpu_status;
    wire pad_m_valid, pad_m_ready, pad_m_error;
    wire [31:0] pad_m_data;
    wire timer_irq, cpu_request_blocked;
    wire fetch_valid, fetch_ready, fetch_new_stream, fetch_close;
    wire fetch_rsp_valid, fetch_rsp_ready, flash_fetch_error;
    wire [23:0] fetch_addr;
    wire [15:0] fetch_data;
    wire req_valid, req_ready, rsp_ready;
    wire iv, ii, iw, ir, ie;
    wire [23:0] cpu_addr;
    wire [31:0] id, iq;
    obc32_cartridge_cpu #(
        .QSPI(3), .SCK_DIV(2), .CLK_DIV(1), .CS_HIGH_CYCLES(4),
        .COMPRESSED(1), .DATA_IO(1), .ENCODING_V2(2), .LOOPBUF(0), .CONT(0),
        .PSRAM_ADDRESS_BITS(PSRAM_ADDRESS_BITS), .LANE_SHIFTS(LANE_SHIFTS),
        .TRANSACTION_FETCH(1), .EXP_ISA(EXP_ISA)
    ) cpu (
        .clk(clk), .rst_n(rst_n), .run(1'b1), .ena(ena), .irq(timer_irq), .ui_in(8'b0),
        .uo_out(cpu_status), .uio_in(8'b0), .uio_out(), .uio_oe(),
        .acc_valid(cv), .acc_io(ci), .acc_write(cw), .acc_addr(cpu_addr), .acc_wdata(cd),
        .acc_ready(cr), .acc_error(ce), .acc_rdata(cq),
        .fetch_valid(fetch_valid), .fetch_ready(fetch_ready), .fetch_addr(fetch_addr),
        .fetch_new_stream(fetch_new_stream), .fetch_close(fetch_close),
        .fetch_rsp_valid(fetch_rsp_valid), .fetch_rsp_ready(fetch_rsp_ready),
        .fetch_data(fetch_data), .fetch_error(flash_fetch_error),
        .data_req_valid(req_valid), .data_req_ready(req_ready), .data_rsp_ready(rsp_ready)
    );
    obc32_cpu_data_slot data_slot (
        .clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
        .req_io(ci), .req_write(cw), .req_addr(cpu_addr), .req_data(cd),
        .rsp_valid(cr), .rsp_ready(rsp_ready), .rsp_error(ce), .rsp_data(cq),
        .issued_valid(iv), .issued_io(ii), .issued_write(iw), .issued_addr(ca), .issued_data(id),
        .issued_ready(ir), .issued_error(ie), .issued_rdata(iq)
    );
    study_data_scratchpad #(.BYTES(PAD_BYTES)) pad (
        .clk(clk), .rst_n(rst_n), .run(1'b1),
        .valid(iv), .io(ii), .write(iw), .addr(ca), .wdata(id),
        .ready(ir), .error(ie), .rdata(iq), .m_valid(pad_m_valid),
        .m_ready(pad_m_ready), .m_error(pad_m_error), .m_rdata(pad_m_data)
    );
    deluxe_service_mux #(.ENABLED(1)) service (
        .clk(clk), .rst_n(rst_n), .c_valid(pad_m_valid), .c_io(ii), .c_write(iw),
        .c_addr(ca), .c_wdata(id), .c_ready(pad_m_ready), .c_error(pad_m_error), .c_rdata(pad_m_data),
        .m_valid(sv), .m_ready(sr), .m_error(se), .m_rdata(sq)
    );
    obc32_dma_subsystem #(.ADDRESS_BITS(PSRAM_ADDRESS_BITS)) dma (
        .clk(clk), .rst_n(rst_n), .c_valid(sv), .c_io(ii), .c_write(iw),
        .c_addr(ca), .c_wdata(id), .c_ready(sr), .c_error(se), .c_rdata(sq),
        .m_valid(mv), .m_io(mi), .m_write(mw), .m_addr(ma), .m_wdata(md),
        .m_ready(mr), .m_error(me), .m_rdata(mq),
        .cpu_request_blocked(cpu_request_blocked),
        .dma_busy(), .dma_done(), .dma_error(), .dma_code(), .dma_transferred()
    );
    wire p_ready, p_error;
    wire [31:0] p_data;
    wire scan_valid, scan_ready, scan_error, scan_accept;
    wire fetching, scan_reservation, underrun, fetch_error;
    wire [19:0] scan_addr;
    wire [31:0] scan_data;
    wire [3:0] dq_out, dq_oe;
    wire flash_cs, ram_cs, serial_clock;
    wire pcm_valid, pcm_ready, tile_valid, tile_busy, tile_ready, aux_error;
    wire [23:0] pcm_addr, tile_addr;
    wire [31:0] pcm_data, tile_data;
    wire f_req, f_restart, f_ready, f_rsp, f_error, f_consume;
    wire blocking_fetch;
    wire [23:0] f_addr;
    wire [15:0] f_data;
    generate if (REPLAY) begin : buffered
        tt16_replay replay (
            .clk(clk), .rst_n(rst_n), .close_stream(fetch_close),
            .req(fetch_valid), .restart(fetch_new_stream), .addr(fetch_addr), .ready(fetch_ready),
            .rsp(fetch_rsp_valid), .error(flash_fetch_error), .data(fetch_data), .consume(fetch_rsp_ready),
            .flash_req(f_req), .flash_restart(f_restart), .flash_addr(f_addr),
            .blocking_fetch(blocking_fetch),
            .flash_ready(f_ready), .flash_rsp(f_rsp), .flash_error(f_error),
            .flash_data(f_data), .flash_consume(f_consume)
        );
    end else begin : bypass
        assign f_req=fetch_valid;
        assign blocking_fetch=fetch_valid || f_rsp || !f_ready;
        assign f_restart=fetch_new_stream;
        assign f_addr=fetch_addr;
        assign f_consume=fetch_rsp_ready;
        assign fetch_ready=f_ready;
        assign fetch_rsp_valid=f_rsp;
        assign flash_fetch_error=f_error;
        assign fetch_data=f_data;
    end endgenerate
    obc32_transaction_memory #(.PSRAM_ADDRESS_BITS(PSRAM_ADDRESS_BITS)) memory (
        .pcm_valid(AUDIO && pcm_valid), .pcm_addr(pcm_addr), .pcm_ready(pcm_ready),
        .pcm_data(pcm_data), .tile_valid(TILE && tile_valid), .tile_addr(tile_addr),
        .tile_data(tile_data), .tile_ready(tile_ready), .aux_error(aux_error),
        .clk(clk), .rst_n(rst_n), .fetch_valid(f_req), .fetch_addr(f_addr),
        .blocking_fetch(blocking_fetch),
        .fetch_new_stream(f_restart), .fetch_close(fetch_close), .fetch_ready(f_ready),
        .fetch_rsp_valid(f_rsp), .fetch_rsp_ready(f_consume),
        .fetch_data(f_data), .fetch_error(f_error),
        .host_valid(mv && !mi), .host_write(mw), .host_addr(ma), .host_wdata(md),
        .host_ready(p_ready), .host_error(p_error), .host_rdata(p_data),
        .scan_valid(scan_valid), .scan_fetching(scan_reservation), .scan_accept(scan_accept),
        .scan_addr(scan_addr),
        .scan_ready(scan_ready), .scan_error(scan_error), .scan_rdata(scan_data),
        .dq_in({uio_in[5:4],uio_in[2:1]}), .dq_out(dq_out), .dq_oe(dq_oe),
        .flash_cs_n(flash_cs), .ram_cs_n(ram_cs), .sck(serial_clock)
    );
    reg video_enable;
    reg [19:0] framebuffer_base;
    reg [19:0] staged_base;
    reg staged_mono;
    wire config_busy, config_done, active_mono, video_primed, video_active;
    wire [19:0] active_base;
    reg [15:0] frame_count;
    reg pixel_enable;
    (* async_reg="true" *) reg [1:0] gpio_meta, gpio_sync;
    wire frame_start, vblank_start, hs, vs;
    wire [5:0] rgb;
    // DMA is memory-only (d_io is tied low), so peripheral I/O always uses ca.
    // Decode it directly to keep the DMA/CPU address mux off scanout controls.
    wire palette_select = mi && ca >= 24'h70 && ca <= 24'h7f;
    wire alternate_select = COVERAGE && mi && ca == 24'h68;
    wire pcm_select = AUDIO && mi && ca >= 24'h34 && ca <= 24'h37;
    wire tile_select = TILE && mi && ca >= 24'h50 && ca <= 24'h59;
    wire base_select = mi && ca == 24'h6a;
    wire control_select = mi && ca == 24'h6b;
    wire status_select = mi && ca == 24'h6c;
    wire staged_base_select = mi && ca == 24'h6d;
    wire staged_mode_select = mi && ca == 24'h6e;
    wire commit_select = mi && ca == 24'h6f;
    wire frame_select = mi && ca == 24'h10;
    wire keyboard_data_select = mi && ca == 24'h28;
    wire keyboard_status_select = mi && ca == 24'h29;
    wire gpio_select = mi && ca == 24'h2a;
    wire timer_select = mi && ca >= 24'h14 && ca <= 24'h19;
    wire registers_select = pcm_select || tile_select || palette_select || alternate_select || base_select || control_select ||
        status_select || staged_base_select || staged_mode_select || commit_select ||
        frame_select || keyboard_data_select || keyboard_status_select || gpio_select ||
        timer_select;
    wire register_error =
        (palette_select && (!mw || (COVERAGE ? |md[31:8] : |md[31:6]))) ||
        (alternate_select && (!mw || |md[31:6])) ||
        (tile_select && mw && tile_busy) ||
        (pcm_select && mw && ca == 24'h37) ||
        (base_select && mw && (video_enable || config_busy || config_done || |md[31:20] ||
                               |md[1:0] || md[19:0] > 20'hfda80)) ||
        (control_select && mw && |md[31:2]) ||
        (staged_base_select && mw && (|md[31:20] || |md[1:0] ||
                                      md[19:0] > 20'hfda80)) ||
        (staged_mode_select && mw && |md[31:1]) ||
        (commit_select && mw && (md != 1 || config_busy)) ||
        ((status_select || frame_select || keyboard_data_select || gpio_select) && mw) ||
        (keyboard_status_select && mw && md != 1) ||
        (timer_select && ca == 24'h14 && mw) ||
        (timer_select && ca == 24'h17 && mw && |md[31:2]) ||
        (timer_select && ca == 24'h18 && mw && |md[31:2]) ||
        (timer_select && ca == 24'h16 && mw && |md[31:2]);
    wire register_accept = rst_n && mv && mr && registers_select && !register_error;
    wire clear_faults = register_accept && control_select && mw && md[1];
    obc32_psram_scanout_runtime video (
        .clk(clk), .rst_n(rst_n), .pixel_enable(pixel_enable),
        .enable(video_enable), .clear_faults(clear_faults),
        .framebuffer_base(framebuffer_base),
        .commit(register_accept && commit_select && mw),
        .commit_base(staged_base), .commit_mono(staged_mono),
        .commit_busy(config_busy), .commit_done(config_done),
        .active_base(active_base), .active_mono(active_mono),
        .primed_status(video_primed), .active_status(video_active),
        .palette_write(register_accept && palette_select && mw),
        .palette_index(ca[3:0]), .palette_rgb(md[5:0]),
        .palette_coverage(COVERAGE ? md[7:6] : 2'b00),
        .alternate_color_write(register_accept && alternate_select && mw),
        .alternate_color_data(md[5:0]),
        .hsync_n(hs), .vsync_n(vs), .rgb(rgb), .frame_start(frame_start),
        .vblank_start(vblank_start),
        .memory_valid(scan_valid), .memory_accept(scan_accept), .memory_addr(scan_addr),
        .memory_ready(scan_ready), .memory_error(scan_error), .memory_rdata(scan_data),
        .underrun(underrun), .fetch_error(fetch_error), .fetching(fetching),
        .reservation(scan_reservation)
    );
    wire gamepad_select = mi && ca == 24'h20;
    wire gamepad_ready, gamepad_error;
    wire [31:0] gamepad_data;
    phase2_gamepad_io gamepad (
        .clk(clk), .rst_n(rst_n), .pmod_latch(ui_in[4]),
        .pmod_clk(ui_in[5]), .pmod_data(ui_in[6]),
        .acc_valid(mv && gamepad_select), .acc_io(mi), .acc_write(mw),
        .acc_addr(ca[19:0]), .acc_wdata(md), .acc_ready(gamepad_ready),
        .acc_error(gamepad_error), .acc_rdata(gamepad_data)
    );
    wire psg_select = mi && ca >= 24'h30 && ca <= 24'h33;
    wire psg_ready, psg_error, audio, legacy_audio;
    wire [31:0] psg_data;
    wire signed [7:0] psg_bipolar, pcm_sample;
    wire [1:0] pcm_gain;
    wire [31:0] pcm_status, tile_status;
    reg [7:0] pwm_phase, pwm_level;
    wire signed [9:0] extended_pcm = {{2{pcm_sample[7]}},pcm_sample};
    wire signed [9:0] scaled_pcm = pcm_gain==0 ? 10'sd0 :
        pcm_gain==1 ? extended_pcm >>> 2 : pcm_gain==2 ? extended_pcm >>> 1 : extended_pcm;
    wire signed [9:0] mix = 10'sd128 + scaled_pcm +
        $signed({{2{psg_bipolar[7]}},psg_bipolar});
    wire [7:0] clipped_mix = mix<0 ? 8'd0 : mix>255 ? 8'd255 : mix[7:0];
    wire [11:0] pwm_scaled = {clipped_mix,4'b0} - {4'b0,clipped_mix};
    assign audio = AUDIO ? rst_n && pwm_phase < pwm_level : legacy_audio;
    always @(posedge clk) begin
        if (!rst_n) begin pwm_phase<=0; pwm_level<=0; end
        else begin
            pwm_phase<=pwm_phase==8'd239 ? 8'd0 : pwm_phase+1'b1;
            if (pwm_phase==8'd239) pwm_level<=pwm_scaled[11:4];
        end
    end
    tt16_pcm pcm (
        .clk(clk), .rst_n(rst_n), .tick(pixel_enable),
        .wr(register_accept && pcm_select && mw), .sel(ca[1:0]), .wdata(md),
        .rdata(pcm_status), .valid(pcm_valid), .addr(pcm_addr), .ready(pcm_ready),
        .fault(aux_error), .word(pcm_data), .sample(pcm_sample), .gain(pcm_gain)
    );
    tt16_tile tile (
        .clk(clk), .rst_n(rst_n), .wr(register_accept && tile_select && mw),
        .sel(ca[3:0]), .wdata(md), .rdata(tile_status), .valid(tile_valid), .busy(tile_busy),
        .addr(tile_addr), .data(tile_data), .ready(tile_ready), .fault(aux_error)
    );
    obc32_fb_psg psg (
        .clk(clk), .rst_n(rst_n), .tick(pixel_enable), .cpu_rst_n(rst_n),
        .acc_valid(mv && psg_select), .acc_io(mi), .acc_write(mw),
        .acc_addr(ca[19:0]), .acc_wdata(md), .acc_ready(psg_ready),
        .acc_error(psg_error), .acc_rdata(psg_data), .audio(legacy_audio), .mix_level(),
        .bipolar(psg_bipolar)
    );
    wire [7:0] keyboard_data;
    wire [4:0] keyboard_count;
    wire [3:0] keyboard_faults;
    wire keyboard_empty, keyboard_full;
    phase2_ps2 #(.FILTER_CYCLES(16), .TIMEOUT_CYCLES(100000)) keyboard (
        .clk(clk), .rst_n(rst_n), .ps2_clk(ui_in[2]), .ps2_data(ui_in[0]),
        .pop(register_accept && keyboard_data_select && !mw && !keyboard_empty),
        .data(keyboard_data), .empty(keyboard_empty), .full(keyboard_full),
        .count(keyboard_count), .faults(keyboard_faults),
        .clear_faults(register_accept && keyboard_status_select && mw)
    );
    wire [31:0] timer_data;
    obc32_timer_irq timer (
        .clk(clk), .rst_n(rst_n), .vblank_start(vblank_start),
        .wr(register_accept && timer_select && mw), .sel(ca[2:0] - 3'd4),
        .wdata(md), .rdata(timer_data), .irq(timer_irq)
    );
    wire [31:0] register_data = pcm_select ? pcm_status : tile_select ? tile_status :
        timer_select ? timer_data :
        base_select ? {12'b0,framebuffer_base} :
        control_select ? {28'b0,fetching,fetch_error,underrun,video_enable} :
        status_select ? {24'b0,cpu_status} :
        staged_base_select ? {12'b0,staged_base} :
        staged_mode_select ? {31'b0,staged_mono} :
        commit_select ? {28'b0,video_active,video_primed,active_mono,config_busy} :
        frame_select ? {16'b0,frame_count} :
        keyboard_data_select ? {23'b0,!keyboard_empty,keyboard_data} :
        keyboard_status_select ?
            {18'b0,keyboard_full,keyboard_empty,keyboard_faults,3'b0,keyboard_count} :
        gpio_select ? {30'b0,gpio_sync} : 32'b0;
    assign mr = !mi ? p_ready : gamepad_select ? gamepad_ready :
                psg_select ? psg_ready : mv;
    assign me = !mi ? p_error : gamepad_select ? gamepad_error :
                psg_select ? psg_error : !registers_select || register_error;
    assign mq = !mi ? p_data : gamepad_select ? gamepad_data :
                psg_select ? psg_data : register_data;
    always @(posedge clk) begin
        if (!rst_n) pixel_enable <= 0;
        else pixel_enable <= !pixel_enable;
    end
    always @(posedge clk) begin
        if (!rst_n) begin gpio_meta <= 0; gpio_sync <= 0; end
        else begin gpio_meta <= {ui_in[3],ui_in[1]}; gpio_sync <= gpio_meta; end
    end
    always @(posedge clk) begin
        if (!rst_n) begin
            video_enable <= 0; framebuffer_base <= 0; frame_count <= 0;
            staged_base <= 0; staged_mono <= 0;
        end
        else begin
            if (frame_start) frame_count <= frame_count + 1'b1;
            if (config_done) framebuffer_base <= active_base;
            if (register_accept && mw && base_select) framebuffer_base <= md[19:0];
            if (register_accept && mw && control_select) video_enable <= md[0];
            if (register_accept && mw && staged_base_select) staged_base <= md[19:0];
            if (register_accept && mw && staged_mode_select) staged_mono <= md[0];
        end
    end
    // rgb[5:4]=R, [3:2]=G, [1:0]=B; TT Tiny VGA has interleaved bits.
    assign uo_out = {hs,rgb[0],rgb[2],rgb[4],vs,rgb[1],rgb[3],rgb[5]};
    assign uio_out = {audio,ram_cs,dq_out[3:2],serial_clock,dq_out[1:0],flash_cs};
    assign uio_oe = {2'b11,dq_oe[3:2],1'b1,dq_oe[1:0],1'b1};
endmodule
`default_nettype wire
