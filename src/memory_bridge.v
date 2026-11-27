`default_nettype none

module obc32_cartridge_memory #(parameter integer PSRAM_ADDRESS_BITS=23) (
    input wire clk, rst_n,
    input wire cpu_cs_n, cpu_sck, cpu_request_safe,
    input wire [3:0] cpu_out, cpu_oe,
    output wire cpu_run,
    input wire host_valid, host_write,
    input wire [23:0] host_addr,
    input wire [31:0] host_wdata,
    output wire host_ready,
    output reg host_error,
    output reg [31:0] host_rdata,
    input wire scan_valid, scan_fetching, scan_accept,
    input wire [19:0] scan_addr,
    output wire scan_ready, scan_error,
    output wire [31:0] scan_rdata,
    input wire [3:0] dq_in,
    output wire [3:0] dq_out, dq_oe,
    output wire flash_cs_n, ram_cs_n, sck
);
    reg active, scan_owner, cooldown, host_done;
    wire grant, flash_available;
    wire p_ready, p_error, p_initializing, p_cs, p_sck;
    wire [31:0] p_rdata;
    wire [3:0] p_out, p_oe;
    assign host_ready = rst_n && host_valid && host_done && flash_available && cpu_run;
    assign scan_ready = active && scan_owner && p_ready && scan_accept;
    assign scan_error = p_error;
    assign scan_rdata = p_rdata;
    wire session_done = grant && !active && !cooldown &&
        !scan_fetching && (host_done || !host_valid) && p_cs;
    obc32_psram_quad #(.PSRAM_ADDRESS_BITS(PSRAM_ADDRESS_BITS)) psram (
        .clk(clk), .rst_n(rst_n), .valid(active),
        .write(!scan_owner && host_write),
        .addr(scan_owner ? {4'b0, scan_addr} : host_addr),
        .wdata(host_wdata), .ready(p_ready), .error(p_error), .rdata(p_rdata),
        .cs_n(p_cs), .sck(p_sck), .dq_in(dq_in), .dq_out(p_out), .dq_oe(p_oe),
        .initializing(p_initializing)
    );
    obc32_cartridge_handoff handoff (
        .clk(clk), .rst_n(rst_n), .cpu_cs_n(cpu_cs_n), .cpu_sck(cpu_sck),
        .cpu_out(cpu_out), .cpu_oe(cpu_oe), .cpu_request_safe(cpu_request_safe),
        .psram_request(scan_fetching || (host_valid && !host_done)),
        .psram_finished(session_done), .psram_initializing(p_initializing),
        .psram_cs_n(p_cs), .psram_sck(p_sck), .psram_out(p_out), .psram_oe(p_oe),
        .cpu_run(cpu_run), .psram_grant(grant), .flash_available(flash_available),
        .flash_cs_n(flash_cs_n), .ram_cs_n(ram_cs_n), .sck(sck),
        .dq_out(dq_out), .dq_oe(dq_oe),
        .handoffs(), .restarts(), .paused_clocks(), .recovery_clocks()
    );
    always @(posedge clk) begin
        if (!rst_n) begin
            active <= 0; scan_owner <= 0; cooldown <= 0; host_done <= 0;
            host_error <= 0; host_rdata <= 0;
        end else begin
            if (host_ready) host_done <= 0;
            if (cooldown) cooldown <= 0;
            if (active && p_ready && (!scan_owner || scan_accept)) begin
                active <= 0; cooldown <= 1;
                if (!scan_owner) begin
                    host_done <= 1; host_error <= p_error; host_rdata <= p_rdata;
                end
            end else if (!active && !cooldown && grant) begin
                if (scan_valid || (host_valid && !host_done && !scan_fetching)) begin
                    active <= 1; scan_owner <= scan_valid;
                end
            end
        end
    end
endmodule

module obc32_transaction_memory #(parameter integer PSRAM_ADDRESS_BITS=23) (
    input wire blocking_fetch,
    input wire pcm_valid, tile_valid,
    input wire [23:0] pcm_addr, tile_addr,
    input wire [31:0] tile_data,
    output wire pcm_ready, tile_ready, aux_error,
    output wire [31:0] pcm_data,
    input wire clk, rst_n,
    input wire fetch_valid, fetch_new_stream, fetch_close,
    input wire [23:0] fetch_addr,
    output wire fetch_ready, fetch_rsp_valid, fetch_error,
    output wire [15:0] fetch_data,
    input wire fetch_rsp_ready,
    input wire host_valid, host_write,
    input wire [23:0] host_addr,
    input wire [31:0] host_wdata,
    output wire host_ready,
    output reg host_error,
    output reg [31:0] host_rdata,
    input wire scan_valid, scan_fetching, scan_accept,
    input wire [19:0] scan_addr,
    output wire scan_ready, scan_error,
    output wire [31:0] scan_rdata,
    input wire [3:0] dq_in,
    output wire [3:0] dq_out, dq_oe,
    output wire flash_cs_n, ram_cs_n, sck
);
    localparam BOOT=3'd0, FLASH=3'd1, TO_RAM=3'd2, RAM=3'd3, TO_FLASH=3'd4;
    reg [2:0] owner;
    reg [1:0] gap;
    reg active, scan_owner, cooldown, host_done;
    reg active_write;
    reg [23:0] active_addr;
    reg [31:0] active_wdata;
    reg pcm_owner, tile_owner, prefer_tile;
    reg normal_turn;
    wire p_ready,p_error,p_initializing,p_cs,p_sck;
    wire f_idle,f_cs,f_sck;
    wire [31:0] p_rdata;
    wire [3:0] p_out,p_oe,f_out,f_oe;
    wire grant = owner == RAM;
    wire ram_owner = owner == BOOT || grant;
    wire flash_owner = owner == FLASH;
    wire pcm_pending = pcm_valid === 1'b1;
    wire tile_pending = tile_valid === 1'b1;
    wire native_pending = host_valid && !host_done;
    wire select_tile = tile_pending && (!native_pending || prefer_tile);
    wire ram_pending = scan_fetching || scan_valid || native_pending ||
                       pcm_pending || tile_pending;
    wire demand_pending = blocking_fetch === 1'b1;
    wire urgent_pending = scan_fetching || scan_valid || pcm_pending;
    wire normal_pending = native_pending || tile_pending;
    // A backpressured response occupies its slot, not the wire. Otherwise alternate
    // blocking Flash responses with normal RAM completions between reservations.
    wire service_ram = urgent_pending ||
        (normal_pending && (!demand_pending || normal_turn ||
                            (fetch_rsp_valid && !fetch_rsp_ready)));
    assign host_ready = rst_n && host_valid && host_done;
    assign scan_ready = rst_n && active && scan_owner && p_ready && scan_accept;
    assign scan_error = p_error;
    assign scan_rdata = p_rdata;
    assign pcm_ready = rst_n && active && pcm_owner && p_ready;
    assign tile_ready = rst_n && active && tile_owner && p_ready;
    assign aux_error = p_error;
    assign pcm_data = p_rdata;
    assign flash_cs_n = !rst_n || !flash_owner || f_cs;
    assign ram_cs_n = !rst_n || !ram_owner || p_cs;
    assign sck = rst_n && (ram_owner ? p_sck : flash_owner && f_sck);
    assign dq_out = ram_owner ? p_out : f_out;
    assign dq_oe = !rst_n ? 4'b0 : ram_owner ? p_oe : flash_owner ? f_oe : 4'b0;

    obc32_flash_halfword flash (
        .clk(clk), .rst_n(rst_n), .req_valid(fetch_valid), .req_addr(fetch_addr),
        .req_new_stream(fetch_new_stream), .close_stream(fetch_close),
        .bus_grant(flash_owner), .restart_blocked(service_ram ||
            (!demand_pending && ram_pending)),
        .req_ready(fetch_ready), .rsp_valid(fetch_rsp_valid), .rsp_error(fetch_error),
        .rsp_data(fetch_data), .rsp_ready(fetch_rsp_ready), .idle(f_idle),
        .cs_n(f_cs), .sck(f_sck), .dq_out(f_out), .dq_oe(f_oe), .dq_in(dq_in)
    );
    obc32_psram_quad #(.PSRAM_ADDRESS_BITS(PSRAM_ADDRESS_BITS)) psram (
        .clk(clk), .rst_n(rst_n), .valid(active), .write(active_write),
        .addr(active_addr), .wdata(active_wdata), .ready(p_ready), .error(p_error),
        .rdata(p_rdata), .cs_n(p_cs), .sck(p_sck), .dq_in(dq_in),
        .dq_out(p_out), .dq_oe(p_oe), .initializing(p_initializing)
    );
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner<=BOOT; gap<=0; active<=0; scan_owner<=0; cooldown<=0; host_done<=0;
            active_write<=0; active_addr<=0; active_wdata<=0; host_error<=0; host_rdata<=0;
            pcm_owner<=0; tile_owner<=0; prefer_tile<=0;
            normal_turn<=0;
        end else begin
            case (owner)
                BOOT: if (!p_initializing && p_cs && !p_sck) owner<=FLASH;
                FLASH: if (service_ram && f_idle && !f_sck) begin owner<=TO_RAM; gap<=2; end
                TO_RAM: if (gap==0) owner<=RAM; else gap<=gap-1'b1;
                RAM: if (!service_ram && !active && !cooldown && p_cs && !p_sck) begin
                    owner<=TO_FLASH; gap<=2;
                end
                TO_FLASH: if (gap==0) owner<=FLASH; else gap<=gap-1'b1;
                default: owner<=BOOT;
            endcase
            if (fetch_rsp_valid && fetch_rsp_ready) normal_turn<=1;
            if (host_ready) host_done<=0;
            if (cooldown) cooldown<=0;
            if (active && p_ready && (!scan_owner || scan_accept)) begin
                active<=0; cooldown<=1;
                if (!scan_owner && !pcm_owner && !tile_owner) begin
                    host_done<=1; host_error<=p_error; host_rdata<=p_rdata;
                    prefer_tile<=1;
                end
                if (!scan_owner && !pcm_owner) normal_turn<=0;
                if (tile_owner) prefer_tile<=0;
            end else if (!active && !cooldown && grant && service_ram &&
                         (scan_valid || (!scan_fetching && (pcm_pending || select_tile || native_pending)))) begin
                active<=1; scan_owner<=scan_valid;
                pcm_owner<=!scan_valid && pcm_pending;
                tile_owner<=!scan_valid && !pcm_pending && select_tile;
                active_addr<=scan_valid ? {4'b0,scan_addr} : pcm_pending ? pcm_addr :
                             select_tile ? tile_addr : host_addr;
                active_write<=!scan_valid && !pcm_pending && (select_tile || host_write);
                active_wdata<=select_tile ? tile_data : host_wdata;
            end
        end
    end
endmodule

module obc32_cpu_data_slot (
    input wire clk, rst_n,
    input wire req_valid, req_io, req_write,
    input wire [23:0] req_addr,
    input wire [31:0] req_data,
    output wire req_ready,
    input wire rsp_ready,
    output wire rsp_valid,
    output reg rsp_error,
    output reg [31:0] rsp_data,
    output wire issued_valid,
    output reg issued_io, issued_write,
    output reg [23:0] issued_addr,
    output reg [31:0] issued_data,
    input wire issued_ready, issued_error,
    input wire [31:0] issued_rdata
);
    localparam EMPTY=2'd0, ISSUED=2'd1, RESPONSE=2'd2;
    reg [1:0] state;
    assign req_ready = rst_n && state == EMPTY;
    assign issued_valid = rst_n && state == ISSUED;
    assign rsp_valid = rst_n && state == RESPONSE;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=EMPTY;
            issued_io<=0; issued_write<=0; issued_addr<=0; issued_data<=0;
            rsp_error<=0; rsp_data<=0;
        end else case (state)
            EMPTY: if (req_valid) begin
                issued_io<=req_io; issued_write<=req_write;
                issued_addr<=req_addr; issued_data<=req_data; state<=ISSUED;
            end
            ISSUED: if (issued_ready) begin
                rsp_error<=issued_error; rsp_data<=issued_rdata; state<=RESPONSE;
            end
            RESPONSE: if (rsp_ready) state<=EMPTY;
            default: state<=EMPTY;
        endcase
    end
endmodule
`default_nettype wire
