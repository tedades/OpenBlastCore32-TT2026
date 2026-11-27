`default_nettype none
module obc32_cartridge_cpu #(
    parameter integer CLK_DIV = 1,
    parameter integer QSPI = 3,
    parameter integer CONT = 0,
    parameter integer ACK_UNSAFE_CONT_RESET = 0,
    parameter integer SCK_DIV = 2,
    parameter integer LOOPBUF = 0,
    parameter integer LB_LOG2 = 2,
    parameter integer ADDER_STYLE = 0,
    parameter integer COMPRESSED = 0,
    parameter integer LB_ASSOC = 0,
    parameter integer CS_HIGH_CYCLES = 1,
    parameter integer DATA_IO = 0,
    parameter integer ENCODING_V2 = 0,
    parameter integer PSRAM_ADDRESS_BITS = 23,
    parameter [23:0] IRQ_VECTOR = 24'h000010,
    parameter integer LANE_SHIFTS = 0,
    parameter integer TRANSACTION_FETCH = 0,
    parameter integer EXP_ISA = 0
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,
    input  wire       run,
    input  wire       irq,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    output reg        acc_valid,
    output reg        acc_io,
    output reg        acc_write,
    output reg [23:0] acc_addr,
    output reg [31:0] acc_wdata,
    input  wire       acc_ready,
    input  wire       acc_error,
    input  wire [31:0] acc_rdata,
    output wire       fetch_valid,
    input  wire       fetch_ready,
    output reg [23:0] fetch_addr,
    output reg        fetch_new_stream,
    input  wire       fetch_rsp_valid,
    output wire       fetch_rsp_ready,
    input  wire [15:0] fetch_data,
    input  wire       fetch_error,
    output wire       fetch_close,
    output wire       data_req_valid,
    input  wire       data_req_ready,
    output wire       data_rsp_ready
);
    localparam [3:0]
        ST_START = 4'd0,
        ST_CMD   = 4'd1,
        ST_RX    = 4'd2,
        ST_RX_END= 4'd3,
        ST_EXEC  = 4'd4,
        ST_SHIFT = 4'd5,
        ST_HALT  = 4'd6,
        ST_EXPAND= 4'd7,
        ST_DATA_WAIT = 4'd8,
        ST_FETCH_REQ = 4'd9,
        ST_FETCH_RSP = 4'd10;
    localparam integer PC_WIDTH = (COMPRESSED != 0) ? 23 : 22;
    localparam [33:0] PSRAM_ADDRESS_LIMIT = 34'd1 << PSRAM_ADDRESS_BITS;
    localparam [PC_WIDTH-1:0] IRQ_VECTOR_PC = IRQ_VECTOR[PC_WIDTH-1:0];
    reg fetch_second;
    reg data_issued;
    wire [PC_WIDTH-1:0] second_pc = program_counter + 1'b1;
    assign fetch_valid = TRANSACTION_FETCH && rst_n && state == ST_FETCH_REQ;
    assign fetch_rsp_ready = TRANSACTION_FETCH && rst_n && state == ST_FETCH_RSP;
    assign fetch_close = TRANSACTION_FETCH && rst_n && (state == ST_HALT || state == ST_START);
    assign data_req_valid = TRANSACTION_FETCH && rst_n && acc_valid && !data_issued;
    assign data_rsp_ready = TRANSACTION_FETCH && rst_n && acc_valid && data_issued;

    generate if (TRANSACTION_FETCH && (COMPRESSED == 0 || LOOPBUF != 0 ||
                QSPI != 3 || SCK_DIV != 2)) begin : gen_bad_transaction_fetch
        initial $fatal(1, "Transaction fetch requires the configured compressed CPU");
    end endgenerate

    generate if ((PSRAM_ADDRESS_BITS != 20) &&
                 (PSRAM_ADDRESS_BITS != 23) &&
                 (PSRAM_ADDRESS_BITS != 24)) begin : gen_bad_psram_address_bits
        initial $fatal(1, "PSRAM_ADDRESS_BITS must be 20, 23, or 24");
    end endgenerate
    generate if (IRQ_VECTOR >= (1 << PC_WIDTH)) begin : gen_bad_irq_vector
        initial $fatal(1, "IRQ_VECTOR is outside the program-counter range");
    end endgenerate
    generate if ((COMPRESSED != 0) && (QSPI != 2) && (QSPI != 3)) begin : gen_bad_compressed_bus
        initial $fatal(1, "COMPRESSED requires QSPI=2 or QSPI=3");
    end endgenerate
    generate if ((LANE_SHIFTS != 0) && (LANE_SHIFTS != 1)) begin : gen_bad_lane_shifts
        initial $fatal(1, "LANE_SHIFTS must be 0 or 1");
    end endgenerate
    generate if ((LANE_SHIFTS != 0) &&
                 ((COMPRESSED == 0) || (ENCODING_V2 != 2))) begin : gen_bad_lane_shift_encoding
        initial $fatal(1, "LANE_SHIFTS requires COMPRESSED=1 and ENCODING_V2=2");
    end endgenerate
    generate if ((QSPI == 2) && (CONT != 0) && (ACK_UNSAFE_CONT_RESET == 0)) begin : gen_cont_reset_gate
        initial $display("WARNING: QSPI=2 CONT disabled: set ACK_UNSAFE_CONT_RESET=1 only when CPU reset cannot leave Flash continuous-read state stale");
    end endgenerate

    localparam [3:0]
        OP_NOP = 4'h0,
        OP_LDI = 4'h1,
        OP_MOV = 4'h2,
        OP_ADD = 4'h3,
        OP_SUB = 4'h4,
        OP_AND = 4'h5,
        OP_OR  = 4'h6,
        OP_XOR = 4'h7,
        OP_SHL = 4'h8,
        OP_SHR = 4'h9,
        OP_ROL = 4'hA,
        OP_JMP = 4'hB,
        OP_BZ  = 4'hC,
        OP_LANE_SHIFT = 4'hD,
        OP_HALT= 4'hF;

    reg [3:0] state;
    reg [PC_WIDTH-1:0] program_counter;
    reg [31:0] instruction;
    reg instruction_short;
    reg in_irq;
    reg [PC_WIDTH-1:0] epc;
    wire irq_take = irq && !in_irq;
    reg short_jump_pending;
    reg [PC_WIDTH-1:0] short_jump_target_reg;
    wire [PC_WIDTH-1:0] pc_step = (COMPRESSED != 0) ?
                           (instruction_short ? 1 : 2) : 1;
    reg [23:0] address_shift;
    reg [31:0] registers [0:3];
    reg [2:0] config_reg;
    reg [5:0] bit_count;
    reg [4:0] shift_count;
    reg [7:0] divider;
    reg error_flag;

    reg flash_cs_n;
    reg [15:0] cs_high_count;
    reg cs_prev_n;
    reg flash_sck;
    reg flash_mosi;
    reg [2:0] flash_io_hi;   // IO3..IO1 outputs (QSPI=2 only)
    wire lb_en = (LOOPBUF != 0) && (QSPI >= 2);
    reg        lb_mode;             // executing from the cache, flash idle
    reg [(1<<LB_LOG2)-1:0] lb_valid;
    reg [PC_WIDTH-1:0] lb_tag  [0:(1<<LB_LOG2)-1];
    reg [31:0] lb_data [0:(1<<LB_LOG2)-1];
    reg [(1<<LB_LOG2)-1:0] lb_short;
    reg [(1<<LB_LOG2)-1:0] lb_jump_valid;
    reg [PC_WIDTH-1:0] lb_jump_target [0:(1<<LB_LOG2)-1];
    reg [LB_LOG2-1:0] lb_victim;
    wire [LB_LOG2-1:0] lb_idx;
    wire lb_hit;
    wire [PC_WIDTH-1:0] lb_tgt = short_jump_pending ? short_jump_target_reg :
        (opcode == OP_JMP) ? immediate : branch_target[PC_WIDTH-1:0];
    wire lb_tgt_hit;
    wire [LB_LOG2-1:0] lb_fill_idx = ((LB_ASSOC != 0) && !lb_hit) ? lb_victim : lb_idx;
    generate
        if (LB_ASSOC != 0) begin : gen_assoc
            reg hit, target_hit;
            reg [LB_LOG2-1:0] idx;
            integer j;
            always @* begin
                hit = 1'b0;
                target_hit = 1'b0;
                idx = {LB_LOG2{1'b0}};
                for (j = 0; j < (1<<LB_LOG2); j = j + 1) begin
                    if (lb_valid[j] && (lb_tag[j] == program_counter)) begin
                        hit = 1'b1;
                        idx = j;
                    end
                    if (lb_valid[j] && (lb_tag[j] == lb_tgt))
                        target_hit = 1'b1;
                end
            end
            assign lb_hit = hit;
            assign lb_idx = idx;
            assign lb_tgt_hit = target_hit;
        end else begin : gen_direct
            assign lb_idx = program_counter[LB_LOG2-1:0];
            assign lb_hit = lb_valid[lb_idx] &&
                             (lb_tag[lb_idx] == (program_counter >> LB_LOG2));
            assign lb_tgt_hit = lb_valid[lb_tgt[LB_LOG2-1:0]] &&
                                (lb_tag[lb_tgt[LB_LOG2-1:0]] == (lb_tgt >> LB_LOG2));
        end
    endgenerate
    localparam integer CONT_ENABLED =
        (QSPI == 2) && (CONT != 0) && (ACK_UNSAFE_CONT_RESET != 0);
    reg cont_active;         // flash is in continuous-read mode
    wire cmd_skip = (CONT_ENABLED != 0) && cont_active;
    wire [5:0] cmd_idx = 6'd20 - bit_count;
    wire [23:0] addr24 = (COMPRESSED != 0) ?
                         ({1'b0, program_counter} << 1) :
                         ({2'b0, program_counter} << 2);
    wire [3:0] addr_nib = address_shift[23:20];

    // QSPI=3: full-rate 0xEB. SCK = clk gated by a negedge enable, outputs are
    // launched on the falling clock edge, and flash data is sampled on the
    // falling edge one SCK period after the flash launched it.
    reg [3:0] qo;            // IO3..IO0 for the next SCK pulse
    reg rel;                 // CPU releases IO0-IO3 for the next SCK pulse
    reg sck_en;              // issue an SCK pulse in the next cycle
    reg dph;                 // that pulse is a data pulse
    reg en1, dph1;           // pulse issued last cycle (sample is ready)
    reg rx_busy;
    reg [3:0] pulse_left;
    reg [2:0] nib_cnt;
    reg [3:0] qo_n;
    reg rel_n, sck_en_n;
    reg [3:0] samp_n;
    localparam [7:0] CMD_EB = 8'hEB;
    wire cmd_bit = CMD_EB[~bit_count[2:0]];
    reg [7:0] ph;            // SCK_DIV >= 2: position inside the SCK period
    reg sck_r;               // SCK_DIV >= 2: registered SCK
    reg [3:0] samp_h, samp_t;
    wire tick3 = (SCK_DIV <= 1) || (ph == SCK_DIV - 1);
    wire [3:0] samp_use = (SCK_DIV == 2) ? samp_h : samp_t;
    wire sck_pin = (SCK_DIV <= 1) ? (clk & sck_en_n) : sck_r;

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qo_n     <= 4'b1100;
            rel_n    <= 1'b1;
            sck_en_n <= 1'b0;
            samp_n   <= 4'b0;
        end else if (!TRANSACTION_FETCH && run) begin
            qo_n     <= qo;
            rel_n    <= rel;
            sck_en_n <= sck_en;
            samp_n   <= flash_quad;
        end
    end

    wire flash_miso = uio_in[2];
    wire [3:0] flash_quad = {uio_in[5], uio_in[4], uio_in[2], uio_in[1]};
    wire half_tick = (CLK_DIV == 1) ? 1'b1 :
                     (divider == CLK_DIV - 1);
    wire [3:0] opcode = instruction[31:28];
    wire [3:0] destination = instruction[27:24];
    wire [3:0] source_a = instruction[23:20];
    wire [3:0] source_b = instruction[19:16];
    wire [19:0] immediate = instruction[19:0];
    wire extension = EXP_ISA && opcode==0 && instruction[19:16]==4'he;
    wire [3:0] ext_op = instruction[15:12];
    wire [31:0] ext_b = registers[instruction[11:10]];
    wire signed [PC_WIDTH-1:0] ext_disp =
        {{(PC_WIDTH-10){instruction[9]}},instruction[9:0]};
    reg [31:0] packed_result;
    function [15:0] packed_lane;
        input [15:0] a, b;
        input wide, mask, unsigned_compare;
        input [3:0] operation;
        reg signed [16:0] pa, pb, result, low, high;
        begin
            pa=wide ? $signed({a[15],a}) : $signed({{9{a[7]}},a[7:0]});
            pb=wide ? $signed({b[15],b}) : $signed({{9{b[7]}},b[7:0]});
            low=wide ? -17'sd32768 : -17'sd128;
            high=wide ? 17'sd32767 : 17'sd127;
            if (operation==10 || operation==11 || unsigned_compare) begin
                pa=$signed({1'b0,a}); pb=$signed({1'b0,b});
                low=0; high=wide ? 17'sd65535 : 17'sd255;
            end
            result=0;
            case(operation)
                3: result=pa==pb ? -17'sd1 : 0;
                4: result=pa<pb ? -17'sd1 : 0;
                5,6,10,11: begin
                    result=(operation==5 || operation==10) ?
                        pa+pb : pa-pb;
                    // Unsigned 16-bit sum needs all 17 bits as an unsigned value.
                    if (operation==10)
                        result=($unsigned(result)>$unsigned(high)) ? high : result;
                    else
                        result=result>high ? high : result<low ? low : result;
                end
                7: result=pa<pb ? pa : pb;
                8: result=pa>pb ? pa : pb;
                9: result=mask ? pa : pb;
                12: result=pa>pb ? -17'sd1 : 0;
                default:;
            endcase
            packed_lane=result[15:0];
        end
    endfunction
    integer pi;
    always @* begin
        packed_result=0;
        if (instruction[9]) begin
            for(pi=0;pi<2;pi=pi+1)
                packed_result[pi*16+:16]=packed_lane(operand_a[pi*16+:16],
                    ext_b[pi*16+:16],1'b1,1'b0,instruction[8],ext_op);
        end else begin
            for(pi=0;pi<4;pi=pi+1)
                packed_result[pi*8+:8]=packed_lane({8'b0,operand_a[pi*8+:8]},
                    {8'b0,ext_b[pi*8+:8]},1'b0,
                    registers[destination[1:0]][pi*8+7],instruction[8],ext_op);
        end
    end
    wire [PC_WIDTH:0] branch_target =
        {1'b0, program_counter} + {1'b0, pc_step} +
        {{(PC_WIDTH+1-20){immediate[19]}}, immediate};
    wire access_family = (DATA_IO != 0) && (opcode == OP_NOP) &&
                         (instruction[19:16] == 4'hF);
    wire access_io = instruction[15];
    wire access_write = instruction[14];
    wire signed [33:0] access_address =
        $signed({2'b0, operand_a}) +
        $signed({{20{instruction[13]}}, instruction[13:0]});
    wire short_relative_jump = (ENCODING_V2 == 2) && instruction_short &&
        instruction[15:12] == 4'hD && !instruction[8] && instruction[7];
    wire signed [PC_WIDTH+1:0] short_jump_target =
        $signed({2'b0, program_counter}) + 1 +
        $signed({{(PC_WIDTH-8){instruction[11]}},
                 instruction[11:9], instruction[6:0]});
    wire short_jump_target_valid = short_jump_target >= 0 &&
        short_jump_target < (1 << PC_WIDTH);
    wire access_invalid = (destination > 4'd3) ||
        (access_io ? (source_a != 4'b0) :
         ((source_a > 4'd3) || (access_address < 0) ||
          (access_address >= $signed(PSRAM_ADDRESS_LIMIT)) ||
          (access_address[1:0] != 0)));
    reg [1:0] access_destination;

    function [31:0] expand_short;
        input [15:0] h;
        input [PC_WIDTH-1:0] pc;
        reg signed [PC_WIDTH+1:0] relative_target;
        reg [3:0] op;
        begin
            // Reserved short forms execute as illegal instructions, not NOPs.
            expand_short = 32'hD0000000;
            op = 4'h0;

            if (EXP_ISA && (h & 16'hffc0)==16'hd040)
                expand_short={4'h0,2'b0,h[5:4],2'b0,h[5:4],4'he,4'h0,
                              {8{h[3]}},h[3:0]};
            else if (EXP_ISA && (h & 16'hff20)==16'hef00)
                expand_short={8'b0,2'b0,h[7:6],4'he,4'h1,2'b0,
                              {5{h[4]}},h[4:0]};
            else if ((ENCODING_V2 != 0) && h[15:12] == 4'hD && h[8]) begin
                if (DATA_IO != 0)
                    expand_short = {4'h0, 2'b0, h[10:9], 2'b0, h[7:6],
                                    4'hF, 1'b0, h[11], {6{h[5]}}, h[5:0], 2'b00};
            end else if ((ENCODING_V2 == 2) && h[15:12] == 4'hD &&
                         !h[8] && h[7]) begin
                relative_target = $signed({2'b0, pc}) + 1 +
                    $signed({{(PC_WIDTH-8){h[11]}}, h[11:9], h[6:0]});
                if (relative_target >= 0 && relative_target < (1 << PC_WIDTH))
                    expand_short = 32'hB0000000;
            end else
            if (h[15:12] == 4'hD) begin
                case (h[11:9])
                    3'd0: if (h[8:0] == 0) expand_short = 32'h00000000;
                    3'd1: if (h[8:0] == 0) expand_short = 32'hF0000000;
                    3'd2: if ((h[8:6] == 0) && (h[1:0] == 0))
                        expand_short = {4'h2, 2'b0, h[5:4], 2'b0, h[3:2], 20'b0};
                    default: if (h[8:6] == 0)
                        expand_short = {1'b0, h[11:9], 2'b0, h[5:4],
                                        2'b0, h[3:2], 2'b0, h[1:0], 16'b0};
                endcase
            end else if (h[15:12] == 4'hE) begin
                case (h[11:10])
                    2'd0: expand_short = {4'h1, 2'b0, h[9:8], 16'b0, h[7:0]};
                    2'd1: expand_short = {4'hC, 4'b0, 2'b0, h[9:8],
                                          {12{h[7]}}, h[7:0]};
                    2'd2: expand_short = {4'hB, 18'b0, h[9:0]};
                    2'd3: if (!h[5] && (h[9:8] != 2'b11)) begin
                        op = 4'h8 + {2'b0, h[9:8]};
                        expand_short = {op, 2'b0, h[7:6], 2'b0, h[7:6],
                                        15'b0, h[4:0]};
                    end else if ((LANE_SHIFTS != 0) && h[5]) begin
                        expand_short = {OP_LANE_SHIFT, 2'b0, h[7:6],
                                        2'b0, h[7:6], 4'hA, 9'b0,
                                        h[9:8], h[4:0]};
                    end
                endcase
            end
        end
    endfunction
    wire [31:0] operand_a;
    wire [31:0] operand_b;
    wire is_subtract = (opcode == OP_SUB);
    wire [31:0] b_effective = operand_b ^ {32{is_subtract}};
    wire [31:0] arithmetic_result;
    wire [31:0] arithmetic_result_cs;
    wire [31:0] group_sum_zero;
    wire [31:0] group_sum_one;
    wire [7:0] block_propagate;
    wire [7:0] block_generate;
    wire [7:0] prefix_p0;
    wire [7:0] prefix_g0;
    wire [7:0] prefix_p1;
    wire [7:0] prefix_g1;
    wire [7:0] prefix_p2;
    wire [7:0] prefix_g2;
    wire [7:0] prefix_p3;
    wire [7:0] prefix_g3;
    wire [7:0] group_carry;
    wire initial_carry = is_subtract ? 1'b1 : config_reg[2];
    wire [31:0] shift_source =
        (source_a == 4'd8) ? {29'b0, config_reg} :
        (source_a <= 4'd3) ? registers[source_a[1:0]] : 32'b0;
    wire lane_shift_valid = (LANE_SHIFTS != 0) &&
        (instruction[19:16] == 4'hA) && (instruction[15:7] == 0) &&
        (destination <= 4'd3) && (source_a == destination) &&
        ((config_reg[1:0] == 2'b01) || (config_reg[1:0] == 2'b10));
    reg [31:0] alu_result;
    reg alu_invalid;
    wire valid_destination =
        (destination <= 4'd3) || (destination == 4'd8);
    integer i;
    integer lane_i;
    genvar group_index;

    generate
            for (group_index = 0; group_index < 8;
                 group_index = group_index + 1) begin : gen_carry_select
                wire [4:0] sum_zero;
                wire [3:0] a_group;
                wire [3:0] b_group;
                wire group_propagate;
                wire group_generate;
                wire lane_boundary;
                wire prefix_carry;
                wire group_carry_in;

                assign a_group = operand_a[group_index*4 +: 4];
                assign b_group = b_effective[group_index*4 +: 4];
                assign sum_zero = {1'b0, a_group} + {1'b0, b_group};
                assign group_propagate = &(a_group ^ b_group);
                assign group_generate = sum_zero[4];

                assign lane_boundary =
                    ((config_reg[1:0] == 2'b01) &&
                     ((group_index == 2) || (group_index == 4) ||
                      (group_index == 6))) ||
                    ((config_reg[1:0] == 2'b10) && (group_index == 4));

                assign block_propagate[group_index] = lane_boundary
                    ? 1'b0 : group_propagate;
                assign block_generate[group_index] = lane_boundary
                    ? (group_generate |
                       (group_propagate & is_subtract))
                    : group_generate;

                assign group_carry_in = (group_index == 0)
                    ? initial_carry
                    : lane_boundary
                        ? is_subtract
                        : prefix_carry;
                if (group_index == 0) begin : gen_first_group
                    assign prefix_carry = 1'b0;
                end else begin : gen_later_group
                    assign prefix_carry =
                        prefix_g3[group_index - 1] |
                        (prefix_p3[group_index - 1] & initial_carry);
                end

                assign group_sum_zero[group_index*4 +: 4] = sum_zero[3:0];
                assign group_sum_one[group_index*4 +: 4] =
                    sum_zero[3:0] + 4'd1;
                assign arithmetic_result_cs[group_index*4 +: 4] =
                    group_carry_in
                        ? group_sum_one[group_index*4 +: 4]
                        : group_sum_zero[group_index*4 +: 4];
            end
    endgenerate


    // Padded single-chain adder: a spare bit is inserted at each possible
    // lane boundary. Active boundary: both pad bits = is_subtract, so the
    // lower lane's carry is absorbed and the upper lane starts with carry
    // is_subtract. Inactive boundary: pad a=1,b=0 passes the carry through.
    wire [31:0] arithmetic_result_fast;
    generate
        if (ADDER_STYLE == 1) begin : gen_padded_adder
            obc32_padded_adder padded_adder (
                .a(operand_a), .b_eff(b_effective), .sub(is_subtract),
                .cin(initial_carry), .mode(config_reg[1:0]),
                .sum(arithmetic_result_fast));
        end else begin : gen_no_padded_adder
            assign arithmetic_result_fast = 32'b0;
        end
    endgenerate
    assign arithmetic_result = (ADDER_STYLE == 1) ? arithmetic_result_fast
                                                  : arithmetic_result_cs;
    assign prefix_p0 = block_propagate;
    assign prefix_g0 = block_generate;

    generate
            for (group_index = 0; group_index < 8;
                 group_index = group_index + 1) begin : gen_carry_prefix
                if (group_index >= 1) begin : gen_prefix_1
                    assign prefix_p1[group_index] =
                        prefix_p0[group_index] & prefix_p0[group_index - 1];
                    assign prefix_g1[group_index] =
                        prefix_g0[group_index] |
                        (prefix_p0[group_index] & prefix_g0[group_index - 1]);
                end else begin : gen_prefix_1_base
                    assign prefix_p1[group_index] = prefix_p0[group_index];
                    assign prefix_g1[group_index] = prefix_g0[group_index];
                end

                if (group_index >= 2) begin : gen_prefix_2
                    assign prefix_p2[group_index] =
                        prefix_p1[group_index] & prefix_p1[group_index - 2];
                    assign prefix_g2[group_index] =
                        prefix_g1[group_index] |
                        (prefix_p1[group_index] & prefix_g1[group_index - 2]);
                end else begin : gen_prefix_2_base
                    assign prefix_p2[group_index] = prefix_p1[group_index];
                    assign prefix_g2[group_index] = prefix_g1[group_index];
                end

                if (group_index >= 4) begin : gen_prefix_3
                    assign prefix_p3[group_index] =
                        prefix_p2[group_index] & prefix_p2[group_index - 4];
                    assign prefix_g3[group_index] =
                        prefix_g2[group_index] |
                        (prefix_p2[group_index] & prefix_g2[group_index - 4]);
                end else begin : gen_prefix_3_base
                    assign prefix_p3[group_index] = prefix_p2[group_index];
                    assign prefix_g3[group_index] = prefix_g2[group_index];
                end
            end
    endgenerate

    // Explicit muxes (not a function) so simulators re-evaluate on register writes.
    assign operand_a = (source_a == 4'd0) ? registers[0] :
                       (source_a == 4'd1) ? registers[1] :
                       (source_a == 4'd2) ? registers[2] :
                       (source_a == 4'd3) ? registers[3] :
                       (source_a == 4'd8) ? {29'b0, config_reg} : 32'b0;
    assign operand_b = (source_b == 4'd0) ? registers[0] :
                       (source_b == 4'd1) ? registers[1] :
                       (source_b == 4'd2) ? registers[2] :
                       (source_b == 4'd3) ? registers[3] :
                       (source_b == 4'd8) ? {29'b0, config_reg} : 32'b0;


    always @* begin
        alu_result = 32'b0;
        alu_invalid = (config_reg[1:0] == 2'b11);

        if (!alu_invalid) begin
            case (opcode)
                OP_ADD, OP_SUB: alu_result = arithmetic_result;
                OP_AND: alu_result = operand_a & operand_b;
                OP_OR:  alu_result = operand_a | operand_b;
                OP_XOR: alu_result = operand_a ^ operand_b;
                OP_SHL: alu_result = {shift_source[30:0], 1'b0};
                OP_SHR: alu_result = {1'b0, shift_source[31:1]};
                OP_ROL: alu_result = {shift_source[30:0], shift_source[31]};
                OP_LANE_SHIFT: begin
                    if ((LANE_SHIFTS != 0) && (config_reg[1:0] == 2'b01)) begin
                        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                            case (instruction[6:5])
                                2'b00: alu_result[lane_i*8 +: 8] =
                                    {shift_source[lane_i*8 +: 7], 1'b0};
                                2'b01: alu_result[lane_i*8 +: 8] =
                                    {1'b0, shift_source[lane_i*8+1 +: 7]};
                                2'b10: alu_result[lane_i*8 +: 8] =
                                    {shift_source[lane_i*8 +: 7],
                                     shift_source[lane_i*8+7]};
                                2'b11: alu_result[lane_i*8 +: 8] =
                                    {shift_source[lane_i*8+7],
                                     shift_source[lane_i*8+1 +: 7]};
                            endcase
                        end
                    end else if ((LANE_SHIFTS != 0) &&
                                 (config_reg[1:0] == 2'b10)) begin
                        for (lane_i = 0; lane_i < 2; lane_i = lane_i + 1) begin
                            case (instruction[6:5])
                                2'b00: alu_result[lane_i*16 +: 16] =
                                    {shift_source[lane_i*16 +: 15], 1'b0};
                                2'b01: alu_result[lane_i*16 +: 16] =
                                    {1'b0, shift_source[lane_i*16+1 +: 15]};
                                2'b10: alu_result[lane_i*16 +: 16] =
                                    {shift_source[lane_i*16 +: 15],
                                     shift_source[lane_i*16+15]};
                                2'b11: alu_result[lane_i*16 +: 16] =
                                    {shift_source[lane_i*16+15],
                                     shift_source[lane_i*16+1 +: 15]};
                            endcase
                        end
                    end
                end
                default: alu_result = 32'b0;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_START;
            fetch_addr     <= 0;
            fetch_new_stream <= 0;
            fetch_second   <= 0;
            data_issued    <= 0;
            program_counter<= {PC_WIDTH{1'b0}};
            instruction    <= 32'b0;
            instruction_short <= 1'b0;
            in_irq         <= 1'b0;
            epc            <= {PC_WIDTH{1'b0}};
            address_shift  <= 20'b0;
            config_reg     <= 3'b0;
            bit_count      <= 6'b0;
            shift_count    <= 5'b0;
            divider        <= 8'b0;
            error_flag     <= 1'b0;
            acc_valid      <= 1'b0;
            acc_io         <= 1'b0;
            acc_write      <= 1'b0;
            acc_addr       <= 24'b0;
            acc_wdata      <= 32'b0;
            access_destination <= 2'b0;
            flash_cs_n     <= 1'b1;
            cs_high_count  <= 16'hFFFF;
            cs_prev_n      <= 1'b0; // Hold QSPI pads released through reset recovery.
            flash_sck      <= 1'b0;
            flash_mosi     <= 1'b0;
            flash_io_hi    <= 3'b110;
            cont_active    <= 1'b0;
            qo             <= 4'b1100;
            rel            <= 1'b1;
            sck_en         <= 1'b0;
            lb_mode        <= 1'b0;
            lb_valid       <= {(1<<LB_LOG2){1'b0}};
            lb_short       <= {(1<<LB_LOG2){1'b0}};
            lb_jump_valid  <= {(1<<LB_LOG2){1'b0}};
            lb_victim      <= {LB_LOG2{1'b0}};
            short_jump_pending <= 1'b0;
            short_jump_target_reg <= {PC_WIDTH{1'b0}};
            dph            <= 1'b0;
            en1            <= 1'b0;
            dph1           <= 1'b0;
            rx_busy        <= 1'b0;
            pulse_left     <= 4'b0;
            nib_cnt        <= 3'b0;
            ph             <= SCK_DIV - 1;
            sck_r          <= 1'b0;
            samp_h         <= 4'b0;
            samp_t         <= 4'b0;
            for (i = 0; i < 4; i = i + 1)
                registers[i] <= 32'b0;
        end else if (TRANSACTION_FETCH || run) begin
            if (!TRANSACTION_FETCH) begin
            if (!flash_cs_n)
                cs_high_count <= 16'b0;
            else if (cs_high_count != 16'hFFFF)
                cs_high_count <= cs_high_count + 1'b1;
            cs_prev_n <= flash_cs_n;
            if (tick3) begin
                en1    <= sck_en;
                dph1   <= dph;
                samp_t <= samp_h;
            end
            if (SCK_DIV >= 2) begin
                ph <= tick3 ? 8'd0 : ph + 1'b1;
                if (state == ST_START)
                    ph <= SCK_DIV - 1;
                sck_r <= sck_en_n && (ph < SCK_DIV / 2);
                if (ph == SCK_DIV / 2)
                    samp_h <= flash_quad;
            end
            end
            case (state)
                ST_START: begin
                    if (TRANSACTION_FETCH) begin
                        if (ena) begin
                            fetch_addr <= addr24;
                            fetch_new_stream <= 1;
                            fetch_second <= 0;
                            state <= ST_FETCH_REQ;
                        end
                    end else begin
                    qo         <= 4'b1100;
                    rel        <= 1'b0;
                    sck_en     <= 1'b0;
                    dph        <= 1'b0;
                    rx_busy    <= 1'b0;
                    divider    <= 8'b0;
                    flash_cs_n <= 1'b1;
                    flash_sck  <= 1'b0;
                    flash_mosi <= 1'b0;
                    flash_io_hi <= 3'b110;
                    if (ena && ((CS_HIGH_CYCLES <= 1) ||
                                (cs_high_count >= CS_HIGH_CYCLES - 1))) begin
                        address_shift <= (QSPI >= 2) ? addr24 : {4'b0, program_counter};
                        bit_count  <= (QSPI == 3) ? 6'd0 :
                                      (QSPI == 2) ? (cmd_skip ? 6'd11 : 6'd19) :
                                      (QSPI != 0) ? 6'd39 : 6'd31;
                        flash_cs_n <= 1'b0;
                        state      <= ST_CMD;
                        if (QSPI == 2) begin
                            if (cmd_skip) begin
                                {flash_io_hi, flash_mosi} <= addr24[23:20];
                                address_shift <= {addr24[19:0], 4'b0};
                            end else begin
                                flash_mosi  <= 1'b1;
                                flash_io_hi <= 3'b110;
                            end
                        end
                    end
                    end
                end

                ST_FETCH_REQ: if (fetch_ready) state <= ST_FETCH_RSP;
                ST_FETCH_RSP: if (fetch_rsp_valid) begin
                    if (fetch_error) begin
                        error_flag <= 1;
                        state <= ST_HALT;
                    end else if (fetch_second) begin
                        instruction <= {instruction[15:0], fetch_data};
                        state <= ST_EXPAND;
                    end else begin
                        instruction <= {16'b0, fetch_data};
                        instruction_short <= fetch_data[15:12] == 4'hD ||
                                             fetch_data[15:12] == 4'hE;
                        if (fetch_data[15:12] == 4'hD || fetch_data[15:12] == 4'hE)
                            state <= ST_EXPAND;
                        else begin
                            fetch_addr <= {second_pc, 1'b0};
                            fetch_new_stream <= second_pc == 0;
                            fetch_second <= 1;
                            state <= ST_FETCH_REQ;
                        end
                    end
                end

                ST_CMD: begin
                    if (QSPI == 3) begin
                      if (tick3) begin
                        sck_en    <= 1'b1;
                        dph       <= 1'b0;
                        bit_count <= bit_count + 1'b1;
                        if (bit_count < 6'd8)
                            qo <= {2'b11, 1'b0, cmd_bit};
                        else if (bit_count < 6'd14) begin
                            qo <= addr_nib;
                            address_shift <= {address_shift[19:0], 4'b0};
                        end else if (bit_count == 6'd14)
                            qo <= 4'hF;
                        else
                            qo <= 4'h0;
                        if (bit_count >= 6'd16)
                            rel <= 1'b1;
                        if (bit_count == 6'd19) begin
                            rx_busy <= 1'b0;
                            state   <= ST_RX;
                        end
                      end
                    end else if (half_tick) begin
                        divider <= 8'b0;
                        if (!flash_sck) begin
                            flash_sck <= 1'b1;
                        end else begin
                            flash_sck <= 1'b0;
                            if (bit_count == 6'b0) begin
                                bit_count <= (QSPI != 0) ? 6'd7 : 6'd31;
                                instruction <= 32'b0;
                                flash_mosi <= 1'b0;
                                flash_io_hi <= 3'b110;
                                if (QSPI == 2) begin
                                    bit_count <= 6'd7;
                                    cont_active <= (CONT_ENABLED != 0);
                                end
                                state <= ST_RX;
                            end else begin
                                bit_count <= bit_count - 1'b1;
                                if (QSPI == 2) begin
                                    if (cmd_idx < 6'd8) begin
                                        flash_mosi  <= 8'hEB >> (6'd7 - cmd_idx);
                                        flash_io_hi <= 3'b110;
                                    end else if (cmd_idx < 6'd14) begin
                                        {flash_io_hi, flash_mosi} <= addr_nib;
                                        address_shift <= {address_shift[19:0], 4'b0};
                                    end else if (cmd_idx == 6'd14) begin
                                        {flash_io_hi, flash_mosi} <=
                                            (CONT_ENABLED != 0) ? 4'hA : 4'hF;
                                    end else begin
                                        {flash_io_hi, flash_mosi} <= 4'h0;
                                    end
                                end else if ((QSPI != 0) && (bit_count >= 6'd33))
                                    flash_mosi <= 8'h6B >> (bit_count - 6'd33);
                                else if ((QSPI == 0) &&
                                         ((bit_count == 6'd26) ||
                                          (bit_count == 6'd25)))
                                    flash_mosi <= 1'b1;
                                else if ((bit_count <= ((QSPI != 0) ? 6'd30 : 6'd22)) &&
                                         (bit_count >= ((QSPI != 0) ? 6'd11 : 6'd3))) begin
                                    flash_mosi <= address_shift[19];
                                    address_shift <= {address_shift[18:0], 1'b0};
                                end else begin
                                    flash_mosi <= 1'b0;
                                end
                            end
                        end
                    end else begin
                        divider <= divider + 1'b1;
                    end
                end

                ST_RX: begin
                    if (TRANSACTION_FETCH) begin
                        fetch_addr <= addr24;
                        fetch_new_stream <= program_counter == 0;
                        fetch_second <= 0;
                        state <= ST_FETCH_REQ;
                    end else if (lb_en && lb_mode) begin
                        if (lb_hit) begin
                            instruction <= lb_data[lb_idx];
                            instruction_short <= lb_short[lb_idx];
                            short_jump_pending <= lb_jump_valid[lb_idx];
                            if (lb_jump_valid[lb_idx])
                                short_jump_target_reg <= lb_jump_target[lb_idx];
                            state       <= ST_EXEC;
                        end else begin
                            lb_mode <= 1'b0;
                            state   <= ST_START;
                        end
                    end else if (QSPI == 3) begin
                      if (tick3) begin
                        if (!rx_busy) begin
                            rx_busy    <= 1'b1;
                            sck_en     <= 1'b1;
                            dph        <= 1'b1;
                            pulse_left <= 4'd7;
                            nib_cnt    <= 3'b0;
                            instruction_short <= 1'b0;
                        end else if (pulse_left != 4'b0) begin
                            pulse_left <= pulse_left - 1'b1;
                        end else begin
                            sck_en <= 1'b0;
                            dph    <= 1'b0;
                        end
                        if (en1 && dph1) begin
                            instruction <= {instruction[27:0], (SCK_DIV <= 1) ? samp_n : samp_use};
                            nib_cnt     <= nib_cnt + 1'b1;
                            if ((COMPRESSED != 0) && (nib_cnt == 0)) begin
                                instruction_short <= (((SCK_DIV <= 1) ? samp_n : samp_use) == 4'hD) ||
                                                     (((SCK_DIV <= 1) ? samp_n : samp_use) == 4'hE);
                                if ((((SCK_DIV <= 1) ? samp_n : samp_use) == 4'hD) ||
                                    (((SCK_DIV <= 1) ? samp_n : samp_use) == 4'hE))
                                    pulse_left <= 4'd1;
                            end
                            if (nib_cnt == (((COMPRESSED != 0) && instruction_short) ? 3'd3 : 3'd7)) begin
                                rx_busy <= 1'b0;
                                state   <= (COMPRESSED != 0) ? ST_EXPAND : ST_EXEC;
                            end
                        end
                      end
                    end else if (half_tick) begin
                        divider <= 8'b0;
                        if (!flash_sck) begin
                            flash_sck <= 1'b1;
                            instruction <= (QSPI != 0) ?
                                {instruction[27:0], flash_quad} :
                                {instruction[30:0], flash_miso};
                            if (bit_count == 6'b0)
                                state <= ST_RX_END;
                            else if ((COMPRESSED != 0) && (bit_count == 6'd7)) begin
                                instruction_short <= (flash_quad == 4'hD) || (flash_quad == 4'hE);
                                bit_count <= ((flash_quad == 4'hD) || (flash_quad == 4'hE)) ? 6'd2 : 6'd6;
                            end else
                                bit_count <= bit_count - 1'b1;
                        end else begin
                            flash_sck <= 1'b0;
                        end
                    end else begin
                        divider <= divider + 1'b1;
                    end
                end

                ST_RX_END: begin
                    if (half_tick) begin
                        divider <= 8'b0;
                        flash_sck <= 1'b0;
                        bit_count <= (QSPI != 0) ? 6'd7 : 6'd31;
                        state <= (COMPRESSED != 0) ? ST_EXPAND : ST_EXEC;
                    end else begin
                        divider <= divider + 1'b1;
                    end
                end

                ST_EXPAND: begin
                    if (instruction_short) begin
                        instruction <= expand_short(instruction[15:0], program_counter);
                        if (short_relative_jump && short_jump_target_valid) begin
                            short_jump_pending <= 1'b1;
                            short_jump_target_reg <= short_jump_target[PC_WIDTH-1:0];
                        end else begin
                            short_jump_pending <= 1'b0;
                        end
                    end
                    state <= ST_EXEC;
                end

                ST_EXEC: begin
                    divider <= 8'b0;
                    if (lb_en && !lb_mode) begin
                        lb_valid[lb_fill_idx] <= 1'b1;
                        lb_tag[lb_fill_idx]   <= (LB_ASSOC != 0) ?
                                                program_counter : (program_counter >> LB_LOG2);
                        lb_data[lb_fill_idx]  <= instruction;
                        lb_short[lb_fill_idx] <= instruction_short;
                        lb_jump_valid[lb_fill_idx] <= short_jump_pending;
                        lb_jump_target[lb_fill_idx] <= short_jump_target_reg;
                        if ((LB_ASSOC != 0) && !lb_hit)
                            lb_victim <= lb_victim + 1'b1;
                    end
                    if (irq_take) begin
                        epc <= program_counter;
                        in_irq <= 1'b1;
                        program_counter <= IRQ_VECTOR_PC;
                        flash_cs_n <= 1'b1;
                        flash_sck <= 1'b0;
                        flash_mosi <= 1'b0;
                        lb_mode <= 1'b0;
                        short_jump_pending <= 1'b0;
                        state <= ST_START;
                    end else case (opcode)
                        OP_NOP: begin
                            if (extension) begin
                                program_counter<=program_counter+pc_step;
                                state<=ST_RX;
                                if (destination>3 || source_a>3)
                                    error_flag<=1;
                                else case(ext_op)
                                    0: registers[destination[1:0]]<=operand_a+
                                        {{20{instruction[11]}},instruction[11:0]};
                                    1,2: if ((ext_op==1 && operand_a!=0) ||
                                             (ext_op==2 && operand_a==ext_b)) begin
                                        program_counter<=program_counter+pc_step+ext_disp;
                                        state<=ST_START;
                                    end
                                    3,4,5,6,7,8,9,10,11,12:
                                        if (instruction[7:0]!=0 ||
                                            (instruction[8] && ext_op!=4 && ext_op!=12) ||
                                            (instruction[9] && ext_op==9))
                                            error_flag<=1;
                                        else registers[destination[1:0]]<=packed_result;
                                    default: error_flag<=1;
                                endcase
                            end else if (access_family && !access_invalid) begin
                                acc_valid <= 1'b1;
                                acc_io <= access_io;
                                acc_write <= access_write;
                                acc_addr <= access_io ? {10'b0, instruction[13:0]} :
                                                         access_address[23:0];
                                acc_wdata <= access_write ? registers[destination[1:0]] : 32'b0;
                                access_destination <= destination[1:0];
                                state <= ST_DATA_WAIT;
                            end else begin
                                if (access_family)
                                    error_flag <= 1'b1;
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end
                        end

                        OP_LDI: begin
                            if (destination <= 4'd3)
                                registers[destination[1:0]] <=
                                    {12'b0, immediate};
                            else if (destination == 4'd8)
                                config_reg <= immediate[2:0];
                            else if (destination != 4'hF)
                                error_flag <= 1'b1;
                            program_counter <= program_counter + pc_step;
                            state <= ST_RX;
                        end

                        OP_MOV: begin
                            if (destination <= 4'd3)
                                registers[destination[1:0]] <= operand_a;
                            else if (destination == 4'd8)
                                config_reg <= operand_a[2:0];
                            else if (destination != 4'hF)
                                error_flag <= 1'b1;
                            program_counter <= program_counter + pc_step;
                            state <= ST_RX;
                        end

                        OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR: begin
                            if (alu_invalid) begin
                                error_flag <= 1'b1;
                                if (destination <= 4'd3)
                                    registers[destination[1:0]] <= 32'b0;
                                else if (destination == 4'd8)
                                    config_reg <= 3'b0;
                            end else if (destination <= 4'd3) begin
                                registers[destination[1:0]] <= alu_result;
                            end else if (destination == 4'd8) begin
                                config_reg <= alu_result[2:0];
                            end else if (destination != 4'hF) begin
                                error_flag <= 1'b1;
                            end
                            program_counter <= program_counter + pc_step;
                            state <= ST_RX;
                        end

                        OP_SHL, OP_SHR, OP_ROL: begin
                            if (alu_invalid) begin
                                error_flag <= 1'b1;
                                if (destination <= 4'd3)
                                    registers[destination[1:0]] <= 32'b0;
                                else if (destination == 4'd8)
                                    config_reg <= 3'b0;
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else if (!valid_destination &&
                                         (destination != 4'hF)) begin
                                error_flag <= 1'b1;
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else if (destination == 4'hF) begin
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else if (immediate[4:0] == 5'b0) begin
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else begin
                                shift_count <= immediate[4:0];
                                state <= ST_SHIFT;
                            end
                        end

                        OP_LANE_SHIFT: begin
                            if (!lane_shift_valid) begin
                                error_flag <= 1'b1;
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else if (instruction[4:0] == 5'b0) begin
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else begin
                                shift_count <= instruction[4:0];
                                state <= ST_SHIFT;
                            end
                        end

                        OP_JMP: begin
                            program_counter <= short_jump_pending ?
                                               short_jump_target_reg : immediate;
                            short_jump_pending <= 1'b0;
                            flash_cs_n <= 1'b1;
                            flash_sck <= 1'b0;
                            flash_mosi <= 1'b0;
                            lb_mode <= lb_en && lb_tgt_hit;
                            state <= (lb_en && lb_tgt_hit) ? ST_RX : ST_START;
                        end

                        OP_BZ: begin
                            if (operand_a == 32'b0) begin
                                program_counter <= branch_target[PC_WIDTH-1:0];
                                flash_cs_n <= 1'b1;
                                flash_sck <= 1'b0;
                                flash_mosi <= 1'b0;
                                lb_mode <= lb_en && lb_tgt_hit;
                                state <= (lb_en && lb_tgt_hit) ? ST_RX : ST_START;
                            end else begin
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end
                        end

                        OP_HALT: begin
                            if (instruction[0] && in_irq) begin
                                in_irq <= 1'b0;
                                program_counter <= epc;
                                flash_cs_n <= 1'b1;
                                flash_sck <= 1'b0;
                                flash_mosi <= 1'b0;
                                lb_mode <= 1'b0;
                                short_jump_pending <= 1'b0;
                                state <= ST_START;
                            end else if (instruction[0]) begin
                                error_flag <= 1'b1;
                                program_counter <= program_counter + pc_step;
                                state <= ST_RX;
                            end else begin
                                flash_cs_n <= 1'b1;
                                flash_sck <= 1'b0;
                                flash_mosi <= 1'b0;
                                state <= ST_HALT;
                            end
                        end

                        default: begin
                            error_flag <= 1'b1;
                            program_counter <= program_counter + pc_step;
                            state <= ST_RX;
                        end
                    endcase
                end

                ST_DATA_WAIT: begin
                    if (data_req_valid && data_req_ready) data_issued <= 1;
                    if (acc_valid && acc_ready && (!TRANSACTION_FETCH || data_rsp_ready)) begin
                        if (acc_error)
                            error_flag <= 1'b1;
                        else if (!acc_write)
                            registers[access_destination] <= acc_rdata;
                        acc_valid <= 1'b0;
                        data_issued <= 0;
                        program_counter <= program_counter + pc_step;
                        state <= ST_RX;
                    end
                end

                ST_SHIFT: begin
                    if (destination <= 4'd3)
                        registers[destination[1:0]] <= alu_result;
                    else if (destination == 4'd8)
                        config_reg <= alu_result[2:0];

                    if (shift_count == 5'd1) begin
                        shift_count <= 5'b0;
                        program_counter <= program_counter + pc_step;
                        state <= ST_RX;
                    end else begin
                        shift_count <= shift_count - 1'b1;
                    end
                end

                ST_HALT: begin
                    rel <= 1'b0;
                    qo  <= 4'b1100;
                    flash_cs_n <= 1'b1;
                    flash_sck <= 1'b0;
                    flash_mosi <= 1'b0;
                end

                default: begin
                    acc_valid <= 1'b0;
                    state <= ST_START;
                    flash_cs_n <= 1'b1;
                    flash_sck <= 1'b0;
                    flash_mosi <= 1'b0;
                    error_flag <= 1'b1;
                end
            endcase
        end
    end

    // QSPI bus ownership: the CPU drives IO0 only while sending the command
    // and address. It releases IO0-IO3 from the first dummy clock until one
    // clock after CS_n has returned high, so the flash never fights the CPU
    // during the data burst (including EXEC/SHIFT pauses inside the burst) or
    // while it releases the bus after CS_n rises.
    wire quad_released = (QSPI != 0) && (!flash_cs_n || !cs_prev_n) &&
                         ((state != ST_CMD) || (bit_count <= ((QSPI == 2) ? 6'd3 : 6'd7)));
    wire quad_hi = (QSPI != 0);
    wire io1_drive = (QSPI == 2) && !flash_cs_n && !quad_released;
    // QSPI=1: IO2/IO3 (flash WP#/HOLD#) are driven high outside the data
    // burst, and uio[7:6] drive the Pmod RAM chip selects high (deselected).
    // QSPI=2: IO1-IO3 carry address/mode nibbles during the command phase.
    assign uio_out = (QSPI == 3) ?
                     {2'b11, qo_n[3:2], sck_pin, qo_n[1:0], flash_cs_n} :
                     {{2{quad_hi}},
                      (QSPI == 2) ? flash_io_hi[2:1] : {2{quad_hi}},
                      flash_sck,
                      (QSPI == 2) ? flash_io_hi[0] : 1'b0,
                      flash_mosi, flash_cs_n};
    assign uio_oe  = (QSPI == 3) ?
                     {2'b11, ~rel_n, ~rel_n, 1'b1, ~rel_n & ~flash_cs_n, ~rel_n, 1'b1} :
                     {{2{quad_hi}}, {2{quad_hi & ~quad_released}}, 1'b1, io1_drive,
                      ~quad_released, 1'b1};
    assign uo_out  = {state == ST_HALT, error_flag, registers[0][5:0]};

    wire unused_inputs = &{1'b0, ui_in};

endmodule


// Padded single-chain adder: a spare bit is inserted at each possible lane
// boundary. Active boundary: both pad bits = sub, so the lower lane's carry is
// absorbed and the upper lane starts with carry = sub. Inactive boundary: pad
// a=1,b=0 passes the carry through.
module obc32_padded_adder (
    input  wire [31:0] a,
    input  wire [31:0] b_eff,
    input  wire        sub,
    input  wire        cin,
    input  wire [1:0]  mode,
    output wire [31:0] sum
);
    wire bnd8  = (mode == 2'b01);
    wire bnd16 = (mode == 2'b01) || (mode == 2'b10);
    wire bnd24 = (mode == 2'b01);
    wire [34:0] pad_a = {a[31:24], bnd24 ? sub : 1'b1,
                         a[23:16], bnd16 ? sub : 1'b1,
                         a[15:8],  bnd8  ? sub : 1'b1, a[7:0]};
    wire [34:0] pad_b = {b_eff[31:24], bnd24 ? sub : 1'b0,
                         b_eff[23:16], bnd16 ? sub : 1'b0,
                         b_eff[15:8],  bnd8  ? sub : 1'b0, b_eff[7:0]};
    wire [35:0] pad_sum = {pad_a, 1'b1} + {pad_b, cin};
    assign sum = {pad_sum[35:28], pad_sum[26:19], pad_sum[17:10], pad_sum[8:1]};
endmodule
`default_nettype wire
