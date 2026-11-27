`default_nettype none
module tt16_replay (
    input wire clk, rst_n, close_stream,
    input wire req, restart,
    input wire [23:0] addr,
    output wire ready,
    output reg rsp, error,
    output reg [15:0] data,
    input wire consume,
    output wire flash_req, flash_restart,
    output wire blocking_fetch,
    output wire [23:0] flash_addr,
    input wire flash_ready, flash_rsp, flash_error,
    input wire [15:0] flash_data,
    output wire flash_consume
);
    reg [1:0] valid [0:7];
    reg [18:0] tags [0:7];
    reg [31:0] buffer [0:7];
    reg [23:0] following, flight_addr;
    reg hint, flight, speculative, waiting, stale;
    wire [2:0] index=addr[4:2], fill_index=flight_addr[4:2];
    wire hit=valid[index][addr[1]] && tags[index]==addr[23:5] && !addr[0];
    wire demand=req && !rsp && !waiting && !hit;
    // Include a miss stalled behind an already accepted speculative fill.
    // waiting retains demand intent after the upstream request handshake.
    assign blocking_fetch=rst_n && (waiting || (req && !rsp && !hit));
    assign flash_req=!flight && (demand || (!req && hint && !close_stream));
    assign flash_addr=demand ? addr : following;
    assign flash_restart=demand && restart;
    assign flash_consume=flight && flash_rsp;
    assign ready=!rsp && !waiting && (hit || (!flight && flash_ready));
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i=0;i<8;i=i+1) valid[i]<=0;
            following<=0; flight_addr<=0; hint<=0; flight<=0;
            speculative<=0; waiting<=0; stale<=0; rsp<=0; data<=0; error<=0;
        end else begin
            if (close_stream || (req && restart)) begin
                hint<=0;
                if (flight && speculative) stale<=1;
            end
            if (rsp && consume) rsp<=0;
            if (req && ready) begin
                if (hit) begin
                    rsp<=1;
                    data<=addr[1] ? buffer[index][31:16] : buffer[index][15:0];
                    error<=0;
                end
                else waiting<=1;
            end
            if (flash_req && flash_ready) begin
                flight<=1; speculative<=!demand; stale<=0;
                flight_addr<=flash_addr; hint<=0;
            end
            if (flash_consume) begin
                flight<=0;
                if (!flash_error && !(speculative && (stale || close_stream || (req && restart)))) begin
                    if (valid[fill_index]==0 || tags[fill_index]!=flight_addr[23:5])
                        valid[fill_index]<=flight_addr[1] ? 2'b10 : 2'b01;
                    else
                        valid[fill_index][flight_addr[1]]<=1;
                    tags[fill_index]<=flight_addr[23:5];
                    if (flight_addr[1]) buffer[fill_index][31:16]<=flash_data;
                    else buffer[fill_index][15:0]<=flash_data;
                end
                if (!speculative) begin
                    rsp<=1; data<=flash_data; error<=flash_error; waiting<=0;
                    hint<=!flash_error && flight_addr!=24'hfffffe && !close_stream;
                    following<=flight_addr+2;
                end
            end
        end
    end
endmodule
`default_nettype wire
