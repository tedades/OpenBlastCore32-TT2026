`timescale 1ns/1ps
`default_nettype none

// Experimental QSPI=3 stream suspension. No instruction/data cache:
// only command/address and serial-position state survives a handoff.
module obc32_cartridge_handoff (
    input wire clk,rst_n,
    input wire cpu_cs_n,cpu_sck,
    input wire [3:0] cpu_out,cpu_oe,
    input wire cpu_request_safe,
    input wire psram_request,psram_finished,psram_initializing,
    input wire psram_cs_n,psram_sck,
    input wire [3:0] psram_out,psram_oe,
    output wire cpu_run,
    output wire psram_grant,
    output wire flash_available,
    output wire flash_cs_n,ram_cs_n,sck,
    output wire [3:0] dq_out,dq_oe,
    output reg [31:0] handoffs,restarts,paused_clocks,recovery_clocks
);
    localparam BOOT=0,FLASH=1,QUIESCE=2,RELEASE=3,RAM=4,
        TURN=5,HEADER=6,PRIME=7,RESUME=8;
    reg [3:0] state;
    reg run_cpu;
    reg previous_cs,previous_sck;
    reg [5:0] logical_edges;
    reg [23:0] base_address;
    reg [23:0] nibble_count;
    reg [23:0] resume_address;
    reg resume_odd,resume_selected;
    reg [5:0] header_edges;
    reg [2:0] gap;
    reg restart_sck,restart_cs;
    reg [3:0] restart_out,restart_oe;
    wire restart_owner=state==HEADER || state==PRIME || state==RESUME;
    wire ram_owner=state==BOOT || state==RAM;
    assign cpu_run=run_cpu && (!cpu_cs_n || flash_high_cycles==4);
    assign psram_grant=state==RAM;
    assign flash_available=state==FLASH;
    assign flash_cs_n=restart_owner ? restart_cs :
        state==FLASH || state==QUIESCE ? cpu_cs_n : 1'b1;
    assign ram_cs_n=ram_owner ? psram_cs_n : 1'b1;
    assign sck=restart_owner ? restart_sck :
        ram_owner ? psram_sck :
        state==FLASH || state==QUIESCE ? cpu_sck : 1'b0;
    wire [3:0] host_out=restart_owner ? restart_out : cpu_out;
    wire [3:0] host_oe=restart_owner ? restart_oe :
        (state==FLASH || state==QUIESCE) ? cpu_oe : 4'b0;
    assign dq_out=ram_owner ? psram_out : host_out;
    assign dq_oe=ram_owner ? psram_oe : host_oe;
    // Logical CPU CS history can predate restoration of the physical pin.
    reg [2:0] flash_high_cycles;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) flash_high_cycles<=0;
        else if(!flash_cs_n) flash_high_cycles<=0;
        else if(flash_high_cycles<4) flash_high_cycles<=flash_high_cycles+1'b1;
    end
    always @(negedge clk or negedge rst_n) begin
        if(!rst_n) begin
            run_cpu<=0;previous_cs<=1;previous_sck<=0;
            logical_edges<=0;base_address<=0;nibble_count<=0;
        end else begin
            previous_cs<=cpu_cs_n;previous_sck<=cpu_sck;
            if(cpu_cs_n) begin logical_edges<=0;nibble_count<=0;end
            else begin
                if(previous_cs) begin logical_edges<=0;base_address<=0;nibble_count<=0;end
                if(cpu_sck && !previous_sck) begin
                    if(logical_edges<20) logical_edges<=logical_edges+1'b1;
                    if(logical_edges>=8 && logical_edges<14)
                        base_address<={base_address[19:0],cpu_out};
                end
                if(!cpu_sck && previous_sck && logical_edges>=20)
                    nibble_count<=nibble_count+1'b1;
            end
            if(state==BOOT) run_cpu<=0;
            else if(state==FLASH) run_cpu<=1;
            else if(state==QUIESCE && !cpu_sck && cpu_request_safe &&
                    (cpu_cs_n || (logical_edges==20 && nibble_count!=0)))
                run_cpu<=0;
            else if(state==RESUME && gap==0) run_cpu<=1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=BOOT;gap<=0;header_edges<=0;
            restart_sck<=0;restart_cs<=1;restart_out<=0;restart_oe<=0;
            resume_address<=0;resume_odd<=0;resume_selected<=0;
            handoffs<=0;restarts<=0;paused_clocks<=0;recovery_clocks<=0;
        end else begin
            if(!run_cpu) paused_clocks<=paused_clocks+1'b1;
            if(state==TURN || state==HEADER || state==PRIME || state==RESUME)
                recovery_clocks<=recovery_clocks+1'b1;
            case(state)
                BOOT: if(!psram_initializing && psram_cs_n) state<=FLASH;
                FLASH: if(psram_request) state<=QUIESCE;
                QUIESCE: if(!run_cpu) begin
                    resume_selected<=!cpu_cs_n;
                    resume_address<=base_address+((nibble_count-1)>>1);
                    resume_odd<=(nibble_count-1)&1;
                    handoffs<=handoffs+1'b1;gap<=2;state<=RELEASE;
                end
                RELEASE: if(gap==0) state<=RAM;else gap<=gap-1'b1;
                RAM: if(psram_finished && psram_cs_n) begin gap<=2;state<=TURN;end
                TURN: if(gap!=0) gap<=gap-1'b1;
                    else if(resume_selected) begin
                        restart_cs<=0;restart_sck<=0;restart_oe<=1;
                        restart_out<=4'b0001;header_edges<=0;
                        restarts<=restarts+1'b1;state<=HEADER;
                    end else begin gap<=1;state<=RESUME;end
                HEADER: begin
                    restart_sck<=!restart_sck;
                    if(!restart_sck) header_edges<=header_edges+1'b1;
                    else if(header_edges==20) begin
                        // The final header falling edge launches the first data nibble.
                        if(resume_odd) state<=PRIME;
                        else begin gap<=2;state<=RESUME;end
                    end else if(header_edges<8) begin
                        restart_out<=(8'heb >> (7-header_edges)) & 1'b1;
                        restart_oe<=1;
                    end else if(header_edges<14) begin
                        restart_out<=resume_address >> ((13-header_edges)*4);
                        restart_oe<=15;
                    end else if(header_edges<16) begin restart_out<=0;restart_oe<=15;end
                    else begin restart_out<=0;restart_oe<=0;end
                end
                PRIME: begin
                    restart_sck<=!restart_sck;
                    if(restart_sck) begin gap<=2;state<=RESUME;end
                end
                RESUME: if(gap!=0) gap<=gap-1'b1;
                    else if(run_cpu) state<=FLASH;
                default: state<=BOOT;
            endcase
        end
    end
endmodule

// Integrated Flash controller. Each accepted, even byte address requests one
// halfword. Sample the current nibble before the falling SCK update launches
// the next one; this retains the original two-clock device response budget.
module obc32_flash_halfword (
    input wire clk, rst_n,
    input wire req_valid, req_new_stream, close_stream, bus_grant,
    input wire restart_blocked,
    input wire [23:0] req_addr,
    output wire req_ready,
    output reg rsp_valid, rsp_error,
    output reg [15:0] rsp_data,
    input wire rsp_ready,
    output wire idle,
    output reg cs_n, sck,
    output reg [3:0] dq_out, dq_oe,
    input wire [3:0] dq_in
);
    localparam IDLE=3'd0, QUEUED=3'd1, HEADER=3'd2, DATA=3'd3, RESPONSE=3'd4;
    reg [2:0] state, cs_high;
    reg [23:0] addr, next_addr;
    reg force_new, stream_next_valid, restart_mode;
    reg [4:0] header_edges;
    reg [2:0] data_edges;
    reg slot_ready;
    wire [7:0] command = 8'heb;
    wire sequential_addr = stream_next_valid && !force_new && addr == next_addr;
    assign req_ready = rst_n && slot_ready;
    assign idle = state != HEADER && state != DATA;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=IDLE; cs_n<=1; sck<=0; dq_out<=0; dq_oe<=0; cs_high<=0;
            addr<=0; next_addr<=0; force_new<=0; stream_next_valid<=0; restart_mode<=0;
            header_edges<=0; data_edges<=0; rsp_valid<=0; rsp_error<=0; rsp_data<=0;
            slot_ready<=1;
        end else begin
            if (!cs_n) cs_high<=0;
            else if (cs_high<4) cs_high<=cs_high+1'b1;
            if (idle && (close_stream || restart_blocked || !bus_grant)) begin
                cs_n<=1;
                dq_oe<=0;
            end
            case (state)
                IDLE: if (req_valid && req_ready) begin
                    addr<=req_addr;
                    force_new<=req_new_stream;
                    slot_ready<=0;
                    state<=QUEUED;
                end
                QUEUED: if (addr[0]) begin
                    rsp_valid<=1; rsp_error<=1; rsp_data<=0; state<=RESPONSE;
                end else if (bus_grant && !restart_blocked && !close_stream) begin
                    if (!cs_n && sequential_addr) begin
                        state<=DATA; data_edges<=0;
                    end else if (!cs_n) begin
                        cs_n<=1; dq_oe<=0;
                    end else if (cs_high==4) begin
                        state<=HEADER; cs_n<=0; header_edges<=0;
                        restart_mode<=sequential_addr;
                        dq_out<={3'b110,command[7]}; dq_oe<=4'b1101;
                    end
                end
                HEADER: begin
                    sck<=!sck;
                    if (!sck) header_edges<=header_edges+1'b1;
                    else if (header_edges==20) begin
                        state<=DATA; data_edges<=0;
                    end else if (header_edges<8)
                        dq_out<={3'b110,command[3'd7-header_edges[2:0]]};
                    else if (header_edges<14) begin
                        dq_out<=addr >> ((13-header_edges)*4); dq_oe<=15;
                    end else if (header_edges<16) begin
                        dq_out<=header_edges==14 && !restart_mode ? 4'hf : 4'h0;
                    end else begin
                        dq_out<=0; dq_oe<=0;
                    end
                end
                DATA: begin
                    sck<=!sck;
                    if (sck) begin
                        rsp_data<={rsp_data[11:0],dq_in};
                        data_edges<=data_edges+1'b1;
                        if (data_edges==3) begin
                            rsp_valid<=1; rsp_error<=0; state<=RESPONSE;
                            next_addr<=addr+24'd2;
                            stream_next_valid<=addr!=24'hfffffe;
                        end
                    end
                end
                RESPONSE: if (rsp_ready) begin
                    rsp_valid<=0; slot_ready<=1; state<=IDLE;
                end
                default: begin
                    state<=RESPONSE; cs_n<=1; sck<=0; dq_oe<=0;
                    rsp_valid<=1; rsp_error<=1; rsp_data<=0; slot_ready<=0;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
