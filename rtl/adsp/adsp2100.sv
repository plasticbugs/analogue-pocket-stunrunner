//------------------------------------------------------------------------------
// ADSP-2100 core for the Stun Runner core.
//
// A faithful port of MAME's adsp2100.cpp / 2100ops.hxx (BSD-3, Aaron Giles)
// to synthesisable SystemVerilog. Only the plain ADSP-2100 is modelled: no
// timer, no SPORTs, no I/O space, no overlays; four external interrupt pins.
//
// Execution model: one instruction per `cen` pulse (8 MHz on the board), run
// as a 6-clock micro-sequence on `clk`:
//
//   S_IDLE    wait for cen; program RAM is presented PC (also interrupt entry)
//   S_WAIT    RAM latency
//   S_LATCH   opcode valid on the RAM output: latch it into `ir`
//   S_ISSUE   evaluate the DO-UNTIL loop end (touches PC/loop/counter stacks
//             and CNTR, so those land on this edge, one clock before the
//             instruction's own effects), issue the memory / IO access, and
//             register the ALU / shifter / multiplier results (register-only
//             operands, pre-instruction values).
//   S_MEM     read data valid; MAC accumulate + round; an IO read may stall.
//   S_WB      write back registers, flags, DAG post-modify, PC, stacks.
//
// Memory writes issued at S_ISSUE carry the pre-instruction register value,
// which is what MAME does (data_write before alu_op). Data moves and memory
// loads are applied after the compute-unit result in S_WB, so a load that
// targets the unit's own destination wins, exactly as in the C++ ordering.
//
// Area: the datapath is shared rather than duplicated per instruction form.
// One 17-bit adder (with operand inversion) does every ALU add/subtract and
// DIVQ; one 64->32 funnel shifter does every LSHIFT/ASHIFT/NORM direction and
// fill; one leading-zero counter serves EXP/EXPADJ; one 3-input 48-bit adder
// is the MAC accumulator; the register file is an active set plus a shadow
// set swapped on MSTAT.BANK changes instead of bank-indexed pairs.
//
// Program RAM (8K x 24) and data RAM (8K x 16) live here as true dual-port
// block RAMs; port B of each is the 68010's load/handshake path.
//
// IDLE (op 0x02 with bit 15) is a NOP here, as it effectively is in MAME.
//------------------------------------------------------------------------------
`default_nettype none

module adsp2100 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,            // 8 MHz instruction-cycle enable
    input  logic        halt,           // /HALT or /BR low: stop at the next instruction boundary

    // program memory port B (68010): 8K x 24
    input  logic [12:0] pm_ext_addr,
    input  logic        pm_ext_we,
    input  logic [23:0] pm_ext_wdata,
    output logic [23:0] pm_ext_rdata,   // 1-cycle latency
    // data memory port B (68010): 8K x 16
    input  logic [12:0] dm_ext_addr,
    input  logic        dm_ext_we,
    input  logic [15:0] dm_ext_wdata,
    output logic [15:0] dm_ext_rdata,   // 1-cycle latency

    // data-space I/O (0x2000-0x2fff); at most one access per instruction
    output logic [11:0] io_addr,
    output logic        io_rd,          // one-clock pulse
    output logic        io_wr,          // one-clock pulse, io_wdata valid with it
    output logic [15:0] io_wdata,
    input  logic [15:0] io_rdata,       // sampled from the 2nd clock after io_rd while io_wait is low
    input  logic        io_wait,        // must be valid from the clock after io_rd

    // external interrupt pins IRQ0..3 (level; ICNTL selects edge latching)
    input  logic  [3:0] irq,
    input  logic        flag_in,
    output logic        flag_out,

    output logic [13:0] dbg_pc,
    output logic        dbg_instr_done  // one-clock pulse when an instruction retires
);

    // ---------------------------------------------------------------------
    // Status bit positions
    // ---------------------------------------------------------------------
    localparam int AZ = 0, AN = 1, AV = 2, AC = 3, AS = 4, AQ = 5, MV = 6, SS = 7;
    localparam int MS_BANK = 0, MS_REV = 1, MS_STICKYV = 2, MS_SAT = 3;
    localparam int SS_PCEMPTY = 0, SS_PCOVER = 1, SS_CNTEMPTY = 2, SS_CNTOVER = 3,
                   SS_STEMPTY = 4, SS_STOVER = 5, SS_LPEMPTY = 6, SS_LPOVER = 7;

    // ---------------------------------------------------------------------
    // Memories
    // ---------------------------------------------------------------------
    // Two independent ports; the 68010's ext port is only ever used while the
    // ADSP is halted, so it never races the core port. `no_rw_check` tells
    // Quartus not to add read-during-write bypass logic (there is no RDW that
    // matters here), which is what lets both memories infer as M10K block RAM
    // rather than 300k+ flip-flops. Keep this form: the merged single-block
    // write-through template does NOT infer on Quartus 18.1.
    (* ramstyle = "no_rw_check" *) logic [23:0] pmem [8192] /* verilator public_flat_rw */;
    (* ramstyle = "no_rw_check" *) logic [15:0] dmem [8192] /* verilator public_flat_rw */;

    logic [12:0] pm_a_addr;
    logic        pm_a_we;
    logic [23:0] pm_a_wdata;
    logic [23:0] pm_a_q;
    logic [12:0] dm_a_addr;
    logic        dm_a_we;
    logic [15:0] dm_a_wdata;
    logic [15:0] dm_a_q;

    always_ff @(posedge clk) begin
        if (pm_a_we) pmem[pm_a_addr] <= pm_a_wdata;
        pm_a_q <= pmem[pm_a_addr];
    end
    always_ff @(posedge clk) begin
        if (pm_ext_we) pmem[pm_ext_addr] <= pm_ext_wdata;
        pm_ext_rdata <= pmem[pm_ext_addr];
    end
    always_ff @(posedge clk) begin
        if (dm_a_we) dmem[dm_a_addr] <= dm_a_wdata;
        dm_a_q <= dmem[dm_a_addr];
    end
    always_ff @(posedge clk) begin
        if (dm_ext_we) dmem[dm_ext_addr] <= dm_ext_wdata;
        dm_ext_rdata <= dmem[dm_ext_addr];
    end

    // ---------------------------------------------------------------------
    // Architectural state (public for the Verilator bench)
    // Active register set (the bank MSTAT.BANK currently selects) and the
    // shadow set; a BANK change swaps the two.
    // ---------------------------------------------------------------------
    logic [15:0] r_ax0 /* verilator public_flat_rw */, x_ax0 /* verilator public_flat_rw */;
    logic [15:0] r_ax1 /* verilator public_flat_rw */, x_ax1 /* verilator public_flat_rw */;
    logic [15:0] r_ay0 /* verilator public_flat_rw */, x_ay0 /* verilator public_flat_rw */;
    logic [15:0] r_ay1 /* verilator public_flat_rw */, x_ay1 /* verilator public_flat_rw */;
    logic [15:0] r_ar  /* verilator public_flat_rw */, x_ar  /* verilator public_flat_rw */;
    logic [15:0] r_af  /* verilator public_flat_rw */, x_af  /* verilator public_flat_rw */;
    logic [15:0] r_mx0 /* verilator public_flat_rw */, x_mx0 /* verilator public_flat_rw */;
    logic [15:0] r_mx1 /* verilator public_flat_rw */, x_mx1 /* verilator public_flat_rw */;
    logic [15:0] r_my0 /* verilator public_flat_rw */, x_my0 /* verilator public_flat_rw */;
    logic [15:0] r_my1 /* verilator public_flat_rw */, x_my1 /* verilator public_flat_rw */;
    logic [15:0] r_mr0 /* verilator public_flat_rw */, x_mr0 /* verilator public_flat_rw */;
    logic [15:0] r_mr1 /* verilator public_flat_rw */, x_mr1 /* verilator public_flat_rw */;
    logic [15:0] r_mr2 /* verilator public_flat_rw */, x_mr2 /* verilator public_flat_rw */;
    logic [15:0] r_mf  /* verilator public_flat_rw */, x_mf  /* verilator public_flat_rw */;
    logic [15:0] r_si  /* verilator public_flat_rw */, x_si  /* verilator public_flat_rw */;
    logic [15:0] r_se  /* verilator public_flat_rw */, x_se  /* verilator public_flat_rw */;
    logic [15:0] r_sb  /* verilator public_flat_rw */, x_sb  /* verilator public_flat_rw */;
    logic [15:0] r_sr0 /* verilator public_flat_rw */, x_sr0 /* verilator public_flat_rw */;
    logic [15:0] r_sr1 /* verilator public_flat_rw */, x_sr1 /* verilator public_flat_rw */;

    logic [13:0] r_i [8] /* verilator public_flat_rw */;
    logic [13:0] r_m [8] /* verilator public_flat_rw */;
    logic [13:0] r_l [8] /* verilator public_flat_rw */;
    logic [13:0] r_base [8] /* verilator public_flat_rw */;

    logic [13:0] pc /* verilator public_flat_rw */;
    logic [13:0] loop_end /* verilator public_flat_rw */;     // 0x3fff when the loop stack is empty
    logic  [3:0] loop_cond /* verilator public_flat_rw */;
    logic [13:0] cntr /* verilator public_flat_rw */;
    logic  [7:0] astat /* verilator public_flat_rw */;
    logic  [7:0] sstat /* verilator public_flat_rw */;
    logic  [3:0] mstat /* verilator public_flat_rw */;
    logic  [7:0] px /* verilator public_flat_rw */;
    logic  [3:0] imask /* verilator public_flat_rw */;
    logic  [4:0] icntl /* verilator public_flat_rw */;
    logic  [3:0] irq_latch;
    logic  [3:0] irq_prev;
    logic        fo;

    logic [13:0] pc_stack [16] /* verilator public_flat_rw */;
    logic  [4:0] pc_sp /* verilator public_flat_rw */;
    logic [17:0] loop_stack [4] /* verilator public_flat_rw */;
    logic  [2:0] loop_sp /* verilator public_flat_rw */;
    logic [13:0] cntr_stack [4] /* verilator public_flat_rw */;
    logic  [2:0] cntr_sp /* verilator public_flat_rw */;
    logic [15:0] stat_stack [4] /* verilator public_flat_rw */;   // {mstat[3:0], imask[3:0], astat[7:0]}
    logic  [2:0] stat_sp /* verilator public_flat_rw */;

    assign dbg_pc = pc;
    assign flag_out = fo;

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    // MAME mask_table: clears the low bits a circular buffer of length L may
    // span (L in (2^k, 2^(k+1)] -> clear k+1 low bits).
    function automatic logic [13:0] lmask_of(input logic [13:0] l);
        if      (l > 14'h2000) lmask_of = 14'h0000;
        else if (l > 14'h1000) lmask_of = 14'h2000;
        else if (l > 14'h0800) lmask_of = 14'h3000;
        else if (l > 14'h0400) lmask_of = 14'h3800;
        else if (l > 14'h0200) lmask_of = 14'h3c00;
        else if (l > 14'h0100) lmask_of = 14'h3e00;
        else if (l > 14'h0080) lmask_of = 14'h3f00;
        else if (l > 14'h0040) lmask_of = 14'h3f80;
        else if (l > 14'h0020) lmask_of = 14'h3fc0;
        else if (l > 14'h0010) lmask_of = 14'h3fe0;
        else if (l > 14'h0008) lmask_of = 14'h3ff0;
        else if (l > 14'h0004) lmask_of = 14'h3ff8;
        else if (l > 14'h0002) lmask_of = 14'h3ffc;
        else if (l > 14'h0001) lmask_of = 14'h3ffe;
        else                   lmask_of = 14'h3fff;
    endfunction

    function automatic logic [13:0] bitrev14(input logic [13:0] v);
        for (int k = 0; k < 14; k++) bitrev14[k] = v[13-k];
    endfunction

    // DAG post-modify: i = (i + m) & 0x3fff, then wrap into [base, base+l)
    function automatic logic [13:0] dag_modify(input logic [13:0] i, input logic [13:0] m,
                                               input logic [13:0] base, input logic [13:0] l);
        logic [13:0] n;
        logic [14:0] lim;
        n = i + m;
        lim = {1'b0, base} + {1'b0, l};
        if (n < base)               dag_modify = n + l;
        else if ({1'b0, n} >= lim)  dag_modify = n - l;
        else                        dag_modify = n;
    endfunction

    // condition codes 0..13 and 15 (14 = CE is handled by the caller)
    function automatic logic cond_flags(input logic [3:0] c, input logic [7:0] st);
        logic az, an, av, ac, as_, mv;
        az = st[AZ]; an = st[AN]; av = st[AV]; ac = st[AC]; as_ = st[AS]; mv = st[MV];
        case (c)
            4'h0: cond_flags = az;
            4'h1: cond_flags = ~az;
            4'h2: cond_flags = ~((an ^ av) | az);
            4'h3: cond_flags = (an ^ av) | az;
            4'h4: cond_flags = an ^ av;
            4'h5: cond_flags = ~(an ^ av);
            4'h6: cond_flags = av;
            4'h7: cond_flags = ~av;
            4'h8: cond_flags = ac;
            4'h9: cond_flags = ~ac;
            4'ha: cond_flags = as_;
            4'hb: cond_flags = ~as_;
            4'hc: cond_flags = mv;
            4'hd: cond_flags = ~mv;
            4'he: cond_flags = 1'b0;
            default: cond_flags = 1'b1;
        endcase
    endfunction

    function automatic logic [31:0] rev32(input logic [31:0] v);
        for (int k = 0; k < 32; k++) rev32[k] = v[31-k];
    endfunction

    function automatic logic [5:0] clz32(input logic [31:0] v);
        clz32 = 6'd32;
        for (int k = 31; k >= 0; k--) if (v[k] && clz32 == 6'd32) clz32 = 6'd31 - k[5:0];
    endfunction

    // ---------------------------------------------------------------------
    // Register-file reads (active set)
    // ---------------------------------------------------------------------
    function automatic logic [15:0] read_reg0(input logic [3:0] n);
        case (n)
            4'h0: read_reg0 = r_ax0; 4'h1: read_reg0 = r_ax1; 4'h2: read_reg0 = r_mx0; 4'h3: read_reg0 = r_mx1;
            4'h4: read_reg0 = r_ay0; 4'h5: read_reg0 = r_ay1; 4'h6: read_reg0 = r_my0; 4'h7: read_reg0 = r_my1;
            4'h8: read_reg0 = r_si;  4'h9: read_reg0 = r_se;  4'ha: read_reg0 = r_ar;  4'hb: read_reg0 = r_mr0;
            4'hc: read_reg0 = r_mr1; 4'hd: read_reg0 = r_mr2; 4'he: read_reg0 = r_sr0; default: read_reg0 = r_sr1;
        endcase
    endfunction
    // groups 1/2: I (zero-extended 14), M (sign-extended 14), L, L
    function automatic logic [15:0] read_reg12(input logic [3:0] n, input logic dag2);
        logic [2:0] idx;
        idx = {dag2, n[1:0]};
        case (n[3:2])
            2'd0: read_reg12 = {2'b00, r_i[idx]};
            2'd1: read_reg12 = {{2{r_m[idx][13]}}, r_m[idx]};
            default: read_reg12 = {2'b00, r_l[idx]};
        endcase
    endfunction
    wire [13:0] pc_top   = (pc_sp != 5'd0) ? pc_stack[pc_sp[3:0] - 4'd1] : pc_stack[0];
    wire [13:0] cntr_top = (cntr_sp != 3'd0) ? cntr_stack[cntr_sp[1:0] - 2'd1] : cntr_stack[0];
    wire [15:0] stat_top = (stat_sp != 3'd0) ? stat_stack[stat_sp[1:0] - 2'd1] : stat_stack[0];
    function automatic logic [15:0] read_reg3(input logic [3:0] n);
        case (n)
            4'h0: read_reg3 = {8'h00, astat};
            4'h1: read_reg3 = {12'h000, mstat};
            4'h2: read_reg3 = {8'h00, sstat};
            4'h3: read_reg3 = {12'h000, imask};
            4'h4: read_reg3 = {11'h000, icntl};
            4'h5: read_reg3 = {2'b00, cntr};
            4'h6: read_reg3 = r_sb;
            4'h7: read_reg3 = {8'h00, px};
            4'hf: read_reg3 = {2'b00, pc_top};
            default: read_reg3 = 16'h0000;
        endcase
    endfunction
    function automatic logic [15:0] read_reg(input logic [1:0] grp, input logic [3:0] n);
        case (grp)
            2'd0: read_reg = read_reg0(n);
            2'd1: read_reg = read_reg12(n, 1'b0);
            2'd2: read_reg = read_reg12(n, 1'b1);
            default: read_reg = read_reg3(n);
        endcase
    endfunction

    // x-operand select shared by the ALU, MAC and shifter (codes 2..7 are the
    // same registers; 0/1 differ per unit)
    function automatic logic [15:0] xsel(input logic [2:0] s, input logic [15:0] r0, input logic [15:0] r1);
        case (s)
            3'd0: xsel = r0; 3'd1: xsel = r1; 3'd2: xsel = r_ar; 3'd3: xsel = r_mr0;
            3'd4: xsel = r_mr1; 3'd5: xsel = r_mr2; 3'd6: xsel = r_sr0; default: xsel = r_sr1;
        endcase
    endfunction

    // ---------------------------------------------------------------------
    // Decode (combinational on the latched instruction `ir`)
    // ---------------------------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_WAIT, S_LATCH, S_DEC, S_ISSUE, S_MEM, S_WB} state_e;
    state_e st;

    logic [23:0] ir;
    wire  [7:0]  opc = ir[23:16];
    wire  [3:0]  cc  = ir[3:0];            // condition field where applicable
    wire  [3:0]  fn  = ir[16:13];          // ALU/MAC function
    wire  [2:0]  xs  = ir[10:8];
    wire  [1:0]  ys  = ir[12:11];

    logic cls_alu, cls_mac, cls_shift;     // which compute unit runs
    logic unit_to_ar_mr;                   // 1: result to AR / MR, 0: to AF / MF
    logic cls_cond;                        // the unit runs only if cond(cc)
    logic dm_rd, dm_wr, dm_dag1, dm_dag2, dm_imm;
    logic pm_rd, pm_wr, pm_hi_fields;
    logic mv_we;                           // register write from move / load / immediate
    logic [1:0] mv_grp;
    logic [3:0] mv_reg;
    logic mv_src_reg, mv_src_pm, mv_src_imm, mv_after;
    logic [1:0] mv_src_grp;
    logic [3:0] mv_src_reg_n;
    logic [15:0] mv_imm;
    logic dual;
    logic [1:0] dual_ddst, dual_pdst;
    logic cls_cond_any;                    // the condition field is evaluated (CE side effect)

    always_comb begin
        // 1-bit datapath enables + control-flow class flags. Only single-bit
        // signals here, so this decodes cheaply; the multi-bit ir-field
        // selections are pulled out below (continuous assigns keyed on the
        // opcode nibble) so they do not force a 256:1 decode of the whole
        // opcode.
        cls_alu = 0; cls_mac = 0; cls_shift = 0; unit_to_ar_mr = 1; cls_cond = 0;
        dm_rd = 0; dm_wr = 0; dm_dag1 = 0; dm_dag2 = 0; dm_imm = 0;
        pm_rd = 0; pm_wr = 0; pm_hi_fields = 0;
        mv_we = 0; mv_src_reg = 0; mv_src_pm = 0; mv_src_imm = 0; mv_after = 0;
        dual = 0; cls_cond_any = 0;
        casez (opc)
            8'h02: cls_cond_any = ~ir[15];
            8'h0a, 8'h0b: cls_cond_any = 1'b1;
            8'h0d: begin mv_we = 1; mv_src_reg = 1; end
            8'h0e: begin cls_shift = 1; cls_cond = 1; cls_cond_any = 1; end
            8'h0f: cls_shift = 1;
            8'h10: begin cls_shift = 1; mv_we = 1; mv_src_reg = 1; mv_after = 1; end
            8'h11: begin cls_shift = 1;
                         if (ir[15]) pm_wr = 1;
                         else begin pm_rd = 1; mv_we = 1; mv_src_pm = 1; end end
            8'h12: begin cls_shift = 1; dm_dag1 = 1;
                         if (ir[15]) dm_wr = 1; else begin dm_rd = 1; mv_we = 1; end end
            8'h13: begin cls_shift = 1; dm_dag2 = 1;
                         if (ir[15]) dm_wr = 1; else begin dm_rd = 1; mv_we = 1; end end
            8'b0001_10??, 8'b0001_11??: cls_cond_any = 1'b1;
            8'b0010_000?: begin cls_mac = 1; cls_cond = 1; cls_cond_any = 1; unit_to_ar_mr = 1; end
            8'b0010_001?: begin cls_alu = 1; cls_cond = 1; cls_cond_any = 1; unit_to_ar_mr = 1; end
            8'b0010_010?: begin cls_mac = 1; cls_cond = 1; cls_cond_any = 1; unit_to_ar_mr = 0; end
            8'b0010_011?: begin cls_alu = 1; cls_cond = 1; cls_cond_any = 1; unit_to_ar_mr = 0; end
            8'b0010_1???: begin cls_mac = ~opc[1]; cls_alu = opc[1]; unit_to_ar_mr = ~opc[2]; mv_we = 1; mv_src_reg = 1; end
            8'b0011_????: begin mv_we = 1; mv_src_imm = 1; end
            8'b0100_????: begin mv_we = 1; mv_src_imm = 1; end
            8'b0101_????: begin cls_mac = ~opc[1]; cls_alu = opc[1]; unit_to_ar_mr = ~opc[2];
                                if (opc[3]) pm_wr = 1; else begin pm_rd = 1; mv_we = 1; mv_src_pm = 1; end end
            8'b0110_????: begin cls_mac = ~opc[1]; cls_alu = opc[1]; unit_to_ar_mr = ~opc[2]; dm_dag1 = 1;
                                if (opc[3]) dm_wr = 1; else begin dm_rd = 1; mv_we = 1; end end
            8'b0111_????: begin cls_mac = ~opc[1]; cls_alu = opc[1]; unit_to_ar_mr = ~opc[2]; dm_dag2 = 1;
                                if (opc[3]) dm_wr = 1; else begin dm_rd = 1; mv_we = 1; end end
            8'b1000_????: begin dm_imm = 1; dm_rd = 1; mv_we = 1; end
            8'b1001_????: begin dm_imm = 1; dm_wr = 1; end
            8'b1010_????: begin dm_dag1 = 1; dm_wr = 1; end
            8'b1011_????: begin dm_dag2 = 1; dm_wr = 1; end
            8'b11??_????: begin cls_mac = ~opc[1]; cls_alu = opc[1]; unit_to_ar_mr = 1;
                                dm_dag1 = 1; dm_rd = 1; pm_rd = 1; pm_hi_fields = 1; dual = 1; end
            default: ;
        endcase
    end

    // multi-bit ir-field selections (used only when the matching enable is set;
    // driving them unconditionally keeps them out of the opcode casez so each
    // is a small mux keyed on the opcode nibble, not a 256:1 decode)
    wire [3:0] op_hn = opc[7:4];
    assign mv_grp      = (opc == 8'h0d) ? ir[11:10]
                       : ((op_hn == 4'h3 || op_hn == 4'h8) ? opc[3:2] : 2'd0);
    assign mv_reg      = (op_hn == 4'h3 || op_hn == 4'h4 || op_hn == 4'h8) ? ir[3:0] : ir[7:4];
    assign mv_src_grp  = (opc == 8'h0d) ? ir[9:8] : 2'd0;
    assign mv_src_reg_n = ir[3:0];
    assign mv_imm      = (op_hn == 4'h4) ? ir[19:4] : {{2{ir[17]}}, ir[17:4]};
    assign dual_ddst   = opc[3:2];
    assign dual_pdst   = opc[5:4];

    // memory-write source (pre-instruction register value or immediate)
    logic [15:0] wr_src_val;
    always_comb begin
        casez (opc)
            8'h11, 8'h12, 8'h13: wr_src_val = read_reg0(ir[7:4]);
            8'b0101_1???, 8'b0110_1???, 8'b0111_1???: wr_src_val = read_reg0(ir[7:4]);
            8'b1001_????: wr_src_val = read_reg(opc[3:2], ir[3:0]);
            8'b1010_????, 8'b1011_????: wr_src_val = ir[19:4];
            default: wr_src_val = 16'h0000;
        endcase
    end

    // effective data address and DAG fields
    logic [13:0] ea;
    logic [2:0]  ea_i, ea_m;
    always_comb begin
        ea_i = {dm_dag2, ir[3:2]};
        ea_m = {dm_dag2, ir[1:0]};
        if (dm_imm) ea = ir[17:4];
        else if (dm_dag1 && mstat[MS_REV]) ea = bitrev14(r_i[ea_i]);
        else ea = r_i[ea_i];
    end
    wire [2:0] pea_i = pm_hi_fields ? {1'b1, ir[7:6]} : {1'b1, ir[3:2]};
    wire [2:0] pea_m = pm_hi_fields ? {1'b1, ir[5:4]} : {1'b1, ir[1:0]};

    // ---------------------------------------------------------------------
    // Shared operand muxes. The ALU, multiplier and shifter never run in the
    // same cycle (an instruction is exactly one of them), so the register-file
    // read muxes are shared: the per-unit register pair for x-codes 0/1 and
    // the y-registers are selected first, then a single 8:1 / 4:1 mux. The
    // idle units compute on the "wrong" operands but their results are never
    // latched, so this is free.
    // ---------------------------------------------------------------------
    logic [15:0] ux0, ux1, uy0, uy1, uy2;
    logic [15:0] uxop, uyop;
    always_comb begin
        if (cls_mac)        begin ux0 = r_mx0; ux1 = r_mx1; end
        else if (cls_shift) begin ux0 = r_si;  ux1 = r_si;  end
        else                begin ux0 = r_ax0; ux1 = r_ax1; end   // ALU + DIVS/DIVQ
        if (cls_mac)        begin uy0 = r_my0; uy1 = r_my1; uy2 = r_mf; end
        else                begin uy0 = r_ay0; uy1 = r_ay1; uy2 = r_af; end
        uxop = xsel(xs, ux0, ux1);
        uyop = (ys == 2'd0) ? uy0 : (ys == 2'd1) ? uy1 : (ys == 2'd2) ? uy2 : 16'h0000;
    end

    // ---------------------------------------------------------------------
    // ALU: one 17-bit adder with operand inversion does every add/subtract
    // form (and DIVQ's AF +/- X). Sampled at the end of S_ISSUE.
    // ---------------------------------------------------------------------
    logic [15:0] ax, ay, alu_r, alu_sat;
    logic [15:0] add_a, add_b;
    logic        add_ci, add_sub;
    logic [16:0] add_r;
    logic [15:0] vflag_b;           // the "d" operand MAME uses in its V test
    logic  [7:0] alu_st;
    logic        is_divq;
    always_comb begin
        ax = uxop;
        ay = uyop;
        is_divq = (opc == 8'h07);
        // adder operand selection
        add_a = ax; add_b = ay; add_ci = 1'b0; add_sub = 1'b0; vflag_b = ay;
        if (is_divq) begin
            add_a = r_af; add_b = ax; add_sub = ~astat[AQ]; add_ci = ~astat[AQ];
        end else case (fn)
            4'h1: begin add_a = ay; add_b = 16'h0000; add_ci = 1'b1; end                 // Y + 1
            4'h2: begin add_a = ax; add_b = ay; add_ci = astat[AC]; end                  // X + Y + C
            4'h3: begin add_a = ax; add_b = ay; end                                      // X + Y
            4'h5: begin add_a = 16'h0000; add_b = ay; add_sub = 1'b1; add_ci = 1'b1; end // -Y
            4'h6: begin add_a = ax; add_b = ay; add_sub = 1'b1; add_ci = astat[AC]; end  // X - Y + C - 1
            4'h7: begin add_a = ax; add_b = ay; add_sub = 1'b1; add_ci = 1'b1; end       // X - Y
            4'h8: begin add_a = ay; add_b = 16'hffff; end                                // Y - 1
            4'h9: begin add_a = ay; add_b = ax; add_sub = 1'b1; add_ci = 1'b1; vflag_b = ax; end       // Y - X
            4'ha: begin add_a = ay; add_b = ax; add_sub = 1'b1; add_ci = astat[AC]; vflag_b = ax; end  // Y - X + C - 1
            4'hf: begin add_a = 16'h0000; add_b = ax; add_sub = ax[15]; add_ci = ax[15]; end          // ABS X
            default: ;
        endcase
        add_r = {1'b0, add_a} + {1'b0, (add_sub ? ~add_b : add_b)} + {16'd0, add_ci};
        // result select
        case (fn)
            4'h0: alu_r = ay;
            4'h4: alu_r = ~ay;
            4'hb: alu_r = ~ax;
            4'hc: alu_r = ax & ay;
            4'hd: alu_r = ax | ay;
            4'he: alu_r = ax ^ ay;
            default: alu_r = add_r[15:0];
        endcase
        // flags. CLR_FLAGS: C, V, N, Z cleared unless sticky V keeps V.
        alu_st = mstat[MS_STICKYV] ? (astat & 8'hf4) : (astat & 8'hf0);
        alu_st[AN] = alu_r[15];
        alu_st[AZ] = (alu_r == 16'h0);
        case (fn)
            4'h1: begin if (ay == 16'h7fff) alu_st[AV] = 1'b1; else if (ay == 16'hffff) alu_st[AC] = 1'b1; end
            // adds: V = s^d^r^carry (d includes the carry-in for X+Y+C); C = carry
            4'h2: begin alu_st[AV] = ax[15] ^ (ay[15] ^ (astat[AC] && ay[14:0] == 15'h7fff)) ^ alu_r[15] ^ add_r[16]; alu_st[AC] = add_r[16]; end
            4'h3: begin alu_st[AV] = ax[15] ^ ay[15] ^ alu_r[15] ^ add_r[16]; alu_st[AC] = add_r[16]; end
            4'h5: begin if (ay == 16'h8000) alu_st[AV] = 1'b1; if (ay == 16'h0000) alu_st[AC] = 1'b1; end
            // subtracts (a + ~b + ci): MAME's bit16 of the difference is !carry; C = carry
            4'h6, 4'h7, 4'h9, 4'ha: begin alu_st[AV] = add_a[15] ^ vflag_b[15] ^ alu_r[15] ^ ~add_r[16]; alu_st[AC] = add_r[16]; end
            4'h8: begin if (ay == 16'h8000) alu_st[AV] = 1'b1; else if (ay == 16'h0000) alu_st[AC] = 1'b1; end
            4'hf: begin
                alu_st[AS] = 1'b0;
                alu_st[AN] = 1'b0; alu_st[AZ] = 1'b0;
                if (ax == 16'h0000) alu_st[AZ] = 1'b1;
                if (ax == 16'h8000) begin alu_st[AN] = 1'b1; alu_st[AV] = 1'b1; end
                if (ax[15]) alu_st[AS] = 1'b1;
            end
            default: ;
        endcase
        alu_sat = alu_r;
        if (mstat[MS_SAT] && alu_st[AV] && unit_to_ar_mr) alu_sat = alu_st[AC] ? 16'h8000 : 16'h7fff;
    end

    // ---------------------------------------------------------------------
    // Multiplier (the ADSP-2100 MSTAT has no INTEGER bit: always fractional)
    // ---------------------------------------------------------------------
    logic [15:0] mxv, myv;
    logic signed [16:0] mxs, mys;
    logic signed [33:0] mprod;
    logic [31:0] mprod32;
    logic        x_signed, y_signed;
    always_comb begin
        x_signed = (fn < 4'h4) || (fn[1:0] == 2'd0) || (fn[1:0] == 2'd1);
        y_signed = (fn < 4'h4) || (fn[1:0] == 2'd0) || (fn[1:0] == 2'd2);
        mxv = uxop;
        myv = uyop;
        mxs = x_signed ? {mxv[15], mxv} : {1'b0, mxv};
        mys = y_signed ? {myv[15], myv} : {1'b0, myv};
        mprod = mxs * mys;
        mprod32 = {mprod[30:0], 1'b0};      // (x*y) << 1, truncated to 32 bits
    end

    // ---------------------------------------------------------------------
    // Shifter: one 64->32 funnel does every direction and fill.
    //   left  by n : ({v, 32'b0} >> (32 - n))[31:0]
    //   right by n : ({fill, v}  >> n)[31:0]      fill = sign or zero
    // n is clamped to 32 (the "sc >= 32 -> 0 / sign" cases fall out).
    // ---------------------------------------------------------------------
    logic [15:0] sxv;
    logic [31:0] sx_hi, sx_lo_u, sx_lo_s;
    logic signed [7:0] sc;
    logic [3:0]  sfn;
    logic [31:0] sh_v;              // value into the funnel
    logic        sh_left, sh_arith;
    logic signed [8:0] sh_cnt;      // signed shift count (+ = left) before clamping
    logic [5:0]  sh_n;              // magnitude clamped to 32
    logic [31:0] rsh_in, rsh_out, rmask;
    logic        fillb;
    logic [31:0] sres;
    logic        sres_or, sres_we;
    logic [15:0] nse, nsb;
    logic        nse_we, nsb_we;
    logic  [7:0] sh_st;
    logic [31:0] clz_in;
    logic [5:0]  cnt;
    always_comb begin
        sxv = uxop;
        sx_hi   = {sxv, 16'h0};
        sx_lo_u = {16'h0, sxv};
        sx_lo_s = {{16{sxv[15]}}, sxv};
        sc = (opc == 8'h0f) ? ir[7:0] : r_se[7:0];
        sfn = ir[14:11];
        // value / count / fill per function
        sh_v = sx_hi; sh_arith = 1'b0; sh_cnt = {sc[7], sc};
        case (sfn)
            4'h0, 4'h1: begin sh_v = sx_hi;   sh_arith = 1'b0; end                   // LSHIFT HI
            4'h2, 4'h3: begin sh_v = sx_lo_u; sh_arith = 1'b0; end                   // LSHIFT LO
            4'h4, 4'h5: begin sh_v = sx_hi;   sh_arith = 1'b1; end                   // ASHIFT HI
            4'h6, 4'h7: begin sh_v = sx_lo_s; sh_arith = 1'b1; end                   // ASHIFT LO
            4'h8, 4'h9: begin                                                        // NORM HI
                if (sc > 8'sd0) begin sh_v = {astat[AC], sx_hi[31:1]}; sh_arith = 1'b1; sh_cnt = 9'sd1 - {sc[7], sc}; end
                else begin sh_v = sx_hi; sh_arith = 1'b0; sh_cnt = -{sc[7], sc}; end
            end
            4'ha, 4'hb: begin sh_v = sx_lo_u; sh_arith = 1'b0; sh_cnt = -{sc[7], sc}; end   // NORM LO
            default: ;
        endcase
        sh_left = (sh_cnt > 9'sd0);
        if (sh_left) sh_n = (sh_cnt > 9'sd32) ? 6'd32 : sh_cnt[5:0];
        else         sh_n = (sh_cnt < -9'sd32) ? 6'd32 : (-sh_cnt[5:0]);
        // One 32-bit barrel right-shifter serves every direction: a left shift
        // is done by reversing the input, right-shifting, and reversing the
        // result (fill 0 from the right). A right shift fills the vacated top
        // bits with `fillb` (the sign bit for arithmetic/NORM-HI, else 0).
        // sh_n runs 0..32; a shift of 32 makes (v >> 32) = 0 and the fill mask
        // all-ones, so "shift by >= 32 gives 0 or sign-fill" falls out with no
        // special case.
        fillb  = (!sh_left && sh_arith) ? sh_v[31] : 1'b0;
        rsh_in = sh_left ? rev32(sh_v) : sh_v;
        rmask  = 32'hffffffff >> sh_n;                         // low (32-n) bits set
        rsh_out = (rsh_in >> sh_n) | (fillb ? ~rmask : 32'h0);
        sres = sh_left ? rev32(rsh_out) : rsh_out;
        sres_we = (sfn <= 4'hb);
        sres_or = sfn[0] && (sfn <= 4'hb);
        // exponent detectors share one leading-zero counter
        clz_in = (sfn == 4'he) ? {16'h0, (astat[SS] ? ~sxv : sxv)} : (sxv[15] ? ~sx_lo_s : sx_lo_s);
        cnt = clz32(clz_in);
        nse = r_se; nsb = r_sb; nse_we = 0; nsb_we = 0; sh_st = astat;
        case (sfn)
            4'hc: begin nse_we = 1; sh_st[SS] = sxv[15]; nse = 16'd17 - {10'h0, cnt}; end           // EXP HI
            4'hd: begin                                                                             // EXP HIX
                nse_we = 1;
                if (astat[AV]) begin nse = 16'h0001; sh_st[SS] = ~sxv[15]; end
                else begin sh_st[SS] = sxv[15]; nse = 16'd17 - {10'h0, cnt}; end
            end
            4'he: begin if (r_se == 16'hfff1) begin nse_we = 1; nse = 16'd1 - {10'h0, cnt}; end end  // EXP LO
            4'hf: begin                                                                             // EXPADJ
                // MAME compares res < -sb as unsigned 32-bit values
                if (({26'h0, cnt} - 32'd17) < (32'h0 - {{16{r_sb[15]}}, r_sb})) begin nsb_we = 1; nsb = 16'd17 - {10'h0, cnt}; end
            end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------------
    // Conditions
    // ---------------------------------------------------------------------
    wire        ce_true = (cntr != 14'h0) && (cntr != 14'h1);
    wire        loop_cond_true = (loop_cond == 4'he) ? ce_true : cond_flags(loop_cond, astat);
    wire        in_loop_end = (pc == loop_end);
    wire        wb_cond = (cc == 4'he) ? ce_true : cond_flags(cc, astat);

    // ---------------------------------------------------------------------
    // Interrupt evaluation
    // ---------------------------------------------------------------------
    logic       irq_take;
    logic [1:0] irq_num;
    logic [3:0] irq_chk;
    always_comb begin
        for (int n = 0; n < 4; n++) irq_chk[n] = (icntl[n] ? irq_latch[n] : irq[n]) & imask[n];
        irq_take = |irq_chk;
        irq_num = irq_chk[3] ? 2'd3 : irq_chk[2] ? 2'd2 : irq_chk[1] ? 2'd1 : 2'd0;
    end

    // ---------------------------------------------------------------------
    // Pipeline latches
    // ---------------------------------------------------------------------
    logic [13:0] pcn;
    logic        io_pending_rd;
    logic        dm_is_io;
    logic  [2:0] dag_i_idx, dag_m_idx, pdag_i_idx, pdag_m_idx;
    logic        dag_do, pdag_do;
    logic [15:0] dm_data_lat;
    logic [23:0] pm_data_lat;
    logic [13:0] dm_addr_lat;

    logic [15:0] alu_res;
    logic  [7:0] alu_astat;
    logic        alu_taken, mac_taken, sh_taken;
    logic [31:0] mac_prod;
    logic        mac_sub, mac_acc, mac_rnd;
    logic [47:0] mac_res;
    logic        mac_mv;
    logic [15:0] sh_sr0, sh_sr1, sh_se, sh_sb;
    logic        sh_sr_we, sh_se_we, sh_sb_we;
    logic  [7:0] sh_astat;
    logic [15:0] div_af_r, div_ay0_r;
    logic        div_aq_r;

    // MAC accumulate: one 3-input 48-bit add (acc + (+/-)prod + rounding)
    logic [47:0] macc_res;
    logic        macc_mv;
    always_comb begin
        logic [47:0] acc, p48, res;
        p48 = {{16{mac_prod[31]}}, mac_prod};
        if (mac_sub) p48 = ~p48;
        acc = mac_acc ? {r_mr2, r_mr1, r_mr0} : 48'h0;
        res = acc + p48 + {31'h0, mac_rnd, 15'h0} + {47'h0, mac_sub};
        if (mac_rnd && mac_prod[15:0] == 16'h8000) res[16] = 1'b0;
        macc_res = res;
        macc_mv = !(res[39:31] == 9'h000 || res[39:31] == 9'h1ff);
    end

    // DIVS / DIVQ (DIVQ's add/subtract comes from the ALU adder)
    logic [15:0] div_af, div_ay0;
    logic        div_aq;
    always_comb begin
        logic [15:0] t;
        if (opc == 8'h06) begin
            t = ax ^ ay;
            div_aq = t[15];
            div_af = {ay[14:0], r_ay0[15]};
            div_ay0 = {r_ay0[14:0], t[15]};
        end else begin
            t = add_r[15:0] ^ ax;
            div_aq = t[15];
            div_af = {add_r[14:0], r_ay0[15]};
            div_ay0 = {r_ay0[14:0], ~t[15]};
        end
    end

    // move / load value (S_WB)
    logic [15:0] mv_val;
    always_comb begin
        if (mv_src_imm)      mv_val = mv_imm;
        else if (mv_src_pm)  mv_val = pm_data_lat[23:8];
        else if (mv_src_reg) begin
            mv_val = read_reg(mv_src_grp, mv_src_reg_n);
            // a shift+move (0x10) reads its source after the shift
            if (mv_after && sh_taken) begin
                case (mv_src_reg_n)
                    4'he: mv_val = sh_sr_we ? sh_sr0 : r_sr0;
                    4'hf: mv_val = sh_sr_we ? sh_sr1 : r_sr1;
                    4'h9: mv_val = sh_se_we ? sh_se : r_se;
                    default: ;
                endcase
            end
        end else             mv_val = dm_data_lat;
    end

    // ---------------------------------------------------------------------
    // Next MSTAT (for the bank swap): mirrors every writer of mstat in S_WB
    // ---------------------------------------------------------------------
    logic [3:0] mstat_nxt;
    always_comb begin
        mstat_nxt = mstat;
        if (mv_we && mv_grp == 2'd3 && mv_reg == 4'h1) mstat_nxt = mv_val[3:0];
        if (opc == 8'h0c) begin
            if (ir[5]) mstat_nxt[MS_BANK] = ir[4];
            if (ir[7]) mstat_nxt[MS_REV] = ir[6];
            if (ir[9]) mstat_nxt[MS_STICKYV] = ir[8];
            if (ir[11]) mstat_nxt[MS_SAT] = ir[10];
        end
        if ((opc == 8'h04 && ir[1] && ir[0]) || (opc == 8'h0a && ir[4] && wb_cond)) mstat_nxt = stat_top[15:12];
    end
    wire bank_swap = (st == S_WB) && (mstat_nxt[MS_BANK] != mstat[MS_BANK]);

    // DAG post-modify: two instances (dual fetch needs both); MODIFY reuses A
    wire [2:0] dagA_i = (opc == 8'h09) ? ir[4:2] : dag_i_idx;
    wire [2:0] dagA_m = (opc == 8'h09) ? {ir[4], ir[1:0]} : dag_m_idx;
    wire [13:0] dagA_res = dag_modify(r_i[dagA_i], r_m[dagA_m], r_base[dagA_i], r_l[dagA_i]);
    wire [13:0] dagB_res = dag_modify(r_i[pdag_i_idx], r_m[pdag_m_idx], r_base[pdag_i_idx], r_l[pdag_i_idx]);
    wire        dagA_do  = (opc == 8'h09) || dag_do;

    // group 1/2 write: one shared mask function (I write uses L's mask, L write the new one)
    wire [2:0]  w12_idx  = {mv_grp[1], mv_reg[1:0]};
    wire [13:0] w12_mask = lmask_of((mv_reg[3:2] == 2'd2) ? mv_val[13:0] : r_l[w12_idx]);

    // ---------------------------------------------------------------------
    // Memory port A drive
    // ---------------------------------------------------------------------
    always_comb begin
        pm_a_we = 1'b0;
        pm_a_wdata = {wr_src_val, px};
        pm_a_addr = pc[12:0];
        if (st == S_ISSUE && (pm_rd || pm_wr)) begin
            pm_a_addr = r_i[pea_i][12:0];
            pm_a_we = pm_wr;
        end
        dm_a_we = 1'b0;
        dm_a_wdata = wr_src_val;
        dm_a_addr = ea[12:0];
        if (st == S_ISSUE && dm_wr && !ea[13]) dm_a_we = 1'b1;
    end

    // ---------------------------------------------------------------------
    // Debug taps for the bench: data-space accesses as the core performs them
    // ---------------------------------------------------------------------
    logic        dbg_dm_wr /* verilator public_flat_rd */;
    logic        dbg_dm_rd /* verilator public_flat_rd */;
    logic [13:0] dbg_dm_addr /* verilator public_flat_rd */;
    logic [15:0] dbg_dm_data /* verilator public_flat_rd */;

    // ---------------------------------------------------------------------
    // Stack / register-write helpers. Macros rather than tasks so that every
    // non-blocking assignment textually sits inside the single sequencer
    // always_ff (Verilator counts a task body as a second driver).
    // ---------------------------------------------------------------------
`define PC_PUSH(v) \
        if (pc_sp < 5'd16) begin pc_stack[pc_sp[3:0]] <= (v); pc_sp <= pc_sp + 5'd1; sstat[SS_PCEMPTY] <= 1'b0; end \
        else sstat[SS_PCOVER] <= 1'b1;
`define PC_POP \
        if (pc_sp != 5'd0) begin pc_sp <= pc_sp - 5'd1; if (pc_sp == 5'd1) sstat[SS_PCEMPTY] <= 1'b1; end
`define LOOP_POP \
        if (loop_sp != 3'd0) begin \
            loop_sp <= loop_sp - 3'd1; \
            if (loop_sp == 3'd1) begin loop_end <= 14'h3fff; loop_cond <= 4'h0; sstat[SS_LPEMPTY] <= 1'b1; end \
            else begin loop_end <= loop_stack[loop_sp[1:0] - 2'd2][17:4]; loop_cond <= loop_stack[loop_sp[1:0] - 2'd2][3:0]; end \
        end
`define CNTR_POP \
        begin \
            if (cntr_sp != 3'd0) begin cntr_sp <= cntr_sp - 3'd1; if (cntr_sp == 3'd1) sstat[SS_CNTEMPTY] <= 1'b1; end \
            cntr <= cntr_top; \
        end
`define CNTR_PUSH \
        if (cntr_sp < 3'd4) begin cntr_stack[cntr_sp[1:0]] <= cntr; cntr_sp <= cntr_sp + 3'd1; sstat[SS_CNTEMPTY] <= 1'b0; end \
        else sstat[SS_CNTOVER] <= 1'b1;
`define STAT_PUSH \
        if (stat_sp < 3'd4) begin stat_stack[stat_sp[1:0]] <= {mstat, imask, astat}; stat_sp <= stat_sp + 3'd1; sstat[SS_STEMPTY] <= 1'b0; end \
        else sstat[SS_STOVER] <= 1'b1;
`define STAT_POP \
        begin \
            if (stat_sp != 3'd0) begin stat_sp <= stat_sp - 3'd1; if (stat_sp == 3'd1) sstat[SS_STEMPTY] <= 1'b1; end \
            {mstat, imask, astat} <= stat_top; \
        end
`define CE_DECREMENT \
        if (ce_true) cntr <= cntr - 14'd1; else begin `CNTR_POP end
`define WRITE_REG0(n, v) \
        case (n) \
            4'h0: r_ax0 <= v;  4'h1: r_ax1 <= v;  4'h2: r_mx0 <= v;  4'h3: r_mx1 <= v; \
            4'h4: r_ay0 <= v;  4'h5: r_ay1 <= v;  4'h6: r_my0 <= v;  4'h7: r_my1 <= v; \
            4'h8: r_si <= v; \
            4'h9: r_se <= {{8{v[7]}}, v[7:0]}; \
            4'ha: r_ar <= v; \
            4'hb: r_mr0 <= v; \
            4'hc: begin r_mr1 <= v; r_mr2 <= {16{v[15]}}; end \
            4'hd: r_mr2 <= {{8{v[7]}}, v[7:0]}; \
            4'he: r_sr0 <= v; \
            default: r_sr1 <= v; \
        endcase
`define WRITE_REG12(n, v) \
        case (n[3:2]) \
            2'd0: begin r_i[w12_idx] <= v[13:0]; r_base[w12_idx] <= v[13:0] & w12_mask; end \
            2'd1: r_m[w12_idx] <= v[13:0]; \
            2'd2: begin r_l[w12_idx] <= v[13:0]; r_base[w12_idx] <= r_i[w12_idx] & w12_mask; end \
            default: ; \
        endcase
`define WRITE_REG3(n, v) \
        case (n) \
            4'h0: astat <= v[7:0]; \
            4'h1: mstat <= v[3:0]; \
            4'h3: imask <= v[3:0]; \
            4'h4: icntl <= v[4:0]; \
            4'h5: begin `CNTR_PUSH cntr <= v[13:0]; end \
            4'h6: r_sb <= {{11{v[4]}}, v[4:0]}; \
            4'h7: px <= v[7:0]; \
            4'hc: begin \
                if (v[1]) irq_latch[0] <= 1'b0; \
                if (v[2]) irq_latch[1] <= 1'b0; \
                if (v[3]) irq_latch[3] <= 1'b0; \
                if (v[5]) irq_latch[2] <= 1'b0; \
                if (v[7]) irq_latch[0] <= 1'b1; \
                if (v[8]) irq_latch[1] <= 1'b1; \
                if (v[9]) irq_latch[3] <= 1'b1; \
                if (v[11]) irq_latch[2] <= 1'b1; \
            end \
            4'hd: cntr <= v[13:0]; \
            4'hf: begin `PC_PUSH(v[13:0]) end \
            default: ; \
        endcase

    // ---------------------------------------------------------------------
    // The sequencer
    // ---------------------------------------------------------------------
    always_ff @(posedge clk) begin
        io_rd <= 1'b0;
        io_wr <= 1'b0;
        dbg_instr_done <= 1'b0;
        dbg_dm_wr <= 1'b0;
        dbg_dm_rd <= 1'b0;
        irq_prev <= irq;
        for (int n = 0; n < 4; n++) if (irq[n] && !irq_prev[n]) irq_latch[n] <= 1'b1;

        if (reset) begin
            st <= S_IDLE;
            pc <= 14'd4;
            loop_end <= 14'h3fff; loop_cond <= 4'h0;
            cntr <= 14'h0;
            astat <= 8'h00; sstat <= 8'h55; mstat <= 4'h0; px <= 8'h00;
            imask <= 4'h0; icntl <= 5'h0; irq_latch <= 4'h0; irq_prev <= 4'h0;
            pc_sp <= 5'd0; loop_sp <= 3'd0; cntr_sp <= 3'd0; stat_sp <= 3'd0;
            fo <= 1'b0;
            for (int k = 0; k < 8; k++) begin r_i[k] <= 14'h0; r_m[k] <= 14'h0; r_l[k] <= 14'h0; r_base[k] <= 14'h0; end
            r_ax0 <= 16'h0; r_ax1 <= 16'h0; r_ay0 <= 16'h0; r_ay1 <= 16'h0; r_ar <= 16'h0; r_af <= 16'h0;
            r_mx0 <= 16'h0; r_mx1 <= 16'h0; r_my0 <= 16'h0; r_my1 <= 16'h0;
            r_mr0 <= 16'h0; r_mr1 <= 16'h0; r_mr2 <= 16'h0; r_mf <= 16'h0;
            r_si <= 16'h0; r_se <= 16'h0; r_sb <= 16'h0; r_sr0 <= 16'h0; r_sr1 <= 16'h0;
            x_ax0 <= 16'h0; x_ax1 <= 16'h0; x_ay0 <= 16'h0; x_ay1 <= 16'h0; x_ar <= 16'h0; x_af <= 16'h0;
            x_mx0 <= 16'h0; x_mx1 <= 16'h0; x_my0 <= 16'h0; x_my1 <= 16'h0;
            x_mr0 <= 16'h0; x_mr1 <= 16'h0; x_mr2 <= 16'h0; x_mf <= 16'h0;
            x_si <= 16'h0; x_se <= 16'h0; x_sb <= 16'h0; x_sr0 <= 16'h0; x_sr1 <= 16'h0;
            ir <= 24'h0; pcn <= 14'h0;
            io_pending_rd <= 1'b0; dm_is_io <= 1'b0;
            dag_do <= 1'b0; pdag_do <= 1'b0;
            dag_i_idx <= 3'd0; dag_m_idx <= 3'd0; pdag_i_idx <= 3'd0; pdag_m_idx <= 3'd0;
            dm_data_lat <= 16'h0; pm_data_lat <= 24'h0; dm_addr_lat <= 14'h0;
            alu_taken <= 1'b0; sh_taken <= 1'b0; mac_taken <= 1'b0;
            alu_res <= 16'h0; alu_astat <= 8'h0; mac_prod <= 32'h0; mac_res <= 48'h0; mac_mv <= 1'b0;
            mac_sub <= 1'b0; mac_acc <= 1'b0; mac_rnd <= 1'b0;
            sh_sr0 <= 16'h0; sh_sr1 <= 16'h0; sh_se <= 16'h0; sh_sb <= 16'h0;
            sh_sr_we <= 1'b0; sh_se_we <= 1'b0; sh_sb_we <= 1'b0; sh_astat <= 8'h0;
            div_af_r <= 16'h0; div_ay0_r <= 16'h0; div_aq_r <= 1'b0;
            io_addr <= 12'h0; io_wdata <= 16'h0;
            dbg_dm_addr <= 14'h0; dbg_dm_data <= 16'h0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (cen && !halt) begin
                        if (irq_take) begin
                            irq_latch[irq_num] <= 1'b0;
                            `PC_PUSH(pc)
                            `STAT_PUSH
                            pc <= {12'h0, irq_num};
                            if (icntl[4]) imask <= imask & ~((4'b0010 << irq_num) - 4'd1);
                            else          imask <= 4'h0;
                        end else begin
                            st <= S_WAIT;
                        end
                    end
                end
                S_WAIT:  st <= S_LATCH;
                S_LATCH: begin
                    ir <= pm_a_q;
                    st <= S_DEC;
                end
                // settle: gives the ir decode cone (shifter setup, DAG fields)
                // a second clock before S_ISSUE captures anything ir-derived
                S_DEC:   st <= S_ISSUE;
                S_ISSUE: begin
                    // ---- loop end (MAME: before executing the instruction) ----
                    if (in_loop_end) begin
                        if (loop_cond_true) begin
                            pcn <= pc_top;
                        end else begin
                            `LOOP_POP
                            `PC_POP
                            pcn <= pc + 14'd1;
                        end
                        if (loop_cond == 4'he) begin `CE_DECREMENT end
                    end else begin
                        pcn <= pc + 14'd1;
                    end
                    // ---- memory / IO issue ----
                    dag_do <= (dm_dag1 || dm_dag2);
                    dag_i_idx <= ea_i; dag_m_idx <= ea_m;
                    pdag_do <= (pm_rd || pm_wr);
                    pdag_i_idx <= pea_i; pdag_m_idx <= pea_m;
                    dm_is_io <= ea[13];
                    dm_addr_lat <= ea;
                    io_pending_rd <= 1'b0;
                    if ((dm_rd || dm_wr) && ea[13:12] == 2'b10) begin   // 0x2000-0x2fff
                        io_addr <= ea[11:0];
                        if (dm_rd) begin io_rd <= 1'b1; io_pending_rd <= 1'b1; end
                        else begin io_wr <= 1'b1; io_wdata <= wr_src_val; end
                    end
                    if (dm_wr) begin dbg_dm_wr <= 1'b1; dbg_dm_addr <= ea; dbg_dm_data <= wr_src_val; end
                    // ---- compute units (pre-instruction register values) ----
                    alu_res <= alu_sat;
                    alu_astat <= alu_st;
                    alu_taken <= cls_alu;
                    mac_prod <= mprod32;
                    mac_taken <= cls_mac && (fn != 4'h0);
                    mac_sub <= (fn == 4'h3) || (fn >= 4'hc);
                    mac_acc <= (fn == 4'h2) || (fn == 4'h3) || (fn >= 4'h8);
                    mac_rnd <= (fn == 4'h1) || (fn == 4'h2) || (fn == 4'h3);
                    sh_taken <= cls_shift;
                    sh_sr_we <= sres_we;
                    {sh_sr1, sh_sr0} <= sres_or ? ({r_sr1, r_sr0} | sres) : sres;
                    sh_se_we <= nse_we; sh_se <= nse;
                    sh_sb_we <= nsb_we; sh_sb <= nsb;
                    sh_astat <= sh_st;
                    div_af_r <= div_af; div_ay0_r <= div_ay0; div_aq_r <= div_aq;
                    st <= S_MEM;
                end
                S_MEM: begin
                    pm_data_lat <= pm_a_q;
                    mac_res <= macc_res;
                    mac_mv <= macc_mv;
                    if (io_pending_rd) begin
                        if (!io_wait) begin
                            dm_data_lat <= io_rdata;
                            io_pending_rd <= 1'b0;
                            dbg_dm_rd <= 1'b1; dbg_dm_addr <= dm_addr_lat; dbg_dm_data <= io_rdata;
                            st <= S_WB;
                        end
                    end else begin
                        dm_data_lat <= dm_is_io ? 16'hffff : dm_a_q;
                        if (dm_rd) begin dbg_dm_rd <= 1'b1; dbg_dm_addr <= dm_addr_lat; dbg_dm_data <= dm_is_io ? 16'hffff : dm_a_q; end
                        st <= S_WB;
                    end
                end
                S_WB: begin
                    st <= S_IDLE;
                    dbg_instr_done <= 1'b1;
                    pc <= pcn;
                    // ---- compute-unit results ----
                    if (alu_taken && (!cls_cond || wb_cond)) begin
                        astat <= alu_astat;
                        if (unit_to_ar_mr) r_ar <= alu_res; else r_af <= alu_res;
                    end
                    if (mac_taken && (!cls_cond || wb_cond)) begin
                        if (unit_to_ar_mr) begin
                            {r_mr2, r_mr1, r_mr0} <= mac_res;
                            astat[MV] <= mac_mv;
                        end else r_mf <= mac_res[31:16];
                    end
                    if (sh_taken && (!cls_cond || wb_cond)) begin
                        astat <= sh_astat;
                        if (sh_sr_we) begin r_sr1 <= sh_sr1; r_sr0 <= sh_sr0; end
                        if (sh_se_we) r_se <= sh_se;
                        if (sh_sb_we) r_sb <= sh_sb;
                    end
                    // ---- program-memory data read updates PX ----
                    if (pm_rd) px <= pm_data_lat[7:0];
                    // ---- DAG post-modify (and MODIFY) ----
                    if (dagA_do) r_i[dagA_i] <= dagA_res;
                    if (pdag_do) r_i[pdag_i_idx] <= dagB_res;
                    // ---- dual-fetch loads ----
                    if (dual) begin
                        case (dual_ddst)
                            2'd0: r_ax0 <= dm_data_lat; 2'd1: r_ax1 <= dm_data_lat;
                            2'd2: r_mx0 <= dm_data_lat; default: r_mx1 <= dm_data_lat;
                        endcase
                        case (dual_pdst)
                            2'd0: r_ay0 <= pm_data_lat[23:8]; 2'd1: r_ay1 <= pm_data_lat[23:8];
                            2'd2: r_my0 <= pm_data_lat[23:8]; default: r_my1 <= pm_data_lat[23:8];
                        endcase
                    end
                    // ---- move / load / immediate write (after the unit result: later write wins) ----
                    if (mv_we) begin
                        if (mv_src_reg && mv_src_grp == 2'd3 && mv_src_reg_n == 4'hf) begin `PC_POP end   // TOPPCSTACK read pops
                        case (mv_grp)
                            2'd0: begin `WRITE_REG0(mv_reg, mv_val) end
                            2'd1, 2'd2: begin `WRITE_REG12(mv_reg, mv_val) end
                            default: begin `WRITE_REG3(mv_reg, mv_val) end
                        endcase
                    end
                    // ---- control flow and special instructions ----
                    casez (opc)
                        8'h02: begin
                            if (!ir[15] && wb_cond) begin
                                if (ir[5]) fo <= 1'b0;
                                if (ir[4]) fo <= ~fo;
                            end
                        end
                        8'h03: begin   // jump/call on FLAG_IN
                            if (ir[1] ? flag_in : !flag_in) begin
                                if (ir[0]) begin `PC_PUSH(pcn) end
                                pc <= {ir[3:2], ir[15:4]};
                            end
                        end
                        8'h04: begin   // stack control
                            if (ir[4]) begin `PC_POP end
                            if (ir[3]) begin `LOOP_POP end
                            if (ir[2]) begin `CNTR_POP end
                            if (ir[1]) begin
                                if (ir[0]) begin `STAT_POP end else begin `STAT_PUSH end
                            end
                        end
                        8'h05: begin   // SAT MR
                            if (astat[MV]) begin
                                if (r_mr2[7]) begin r_mr2 <= 16'hffff; r_mr1 <= 16'h8000; r_mr0 <= 16'h0000; end
                                else begin r_mr2 <= 16'h0000; r_mr1 <= 16'h7fff; r_mr0 <= 16'hffff; end
                            end
                        end
                        8'h06, 8'h07: begin   // DIVS / DIVQ
                            astat[AQ] <= div_aq_r;
                            r_af <= div_af_r;
                            r_ay0 <= div_ay0_r;
                        end
                        8'h0a: begin   // conditional return
                            if (wb_cond) begin
                                `PC_POP
                                pc <= pc_top;
                                if (ir[4]) begin `STAT_POP end
                            end
                        end
                        8'h0b: begin   // conditional jump/call indirect
                            if (wb_cond) begin
                                if (ir[4]) begin `PC_PUSH(pcn) end
                                pc <= r_i[{1'b1, ir[7:6]}];
                            end
                        end
                        8'h0c: begin   // mode control (ADSP-2100 subset)
                            if (ir[5]) mstat[MS_BANK] <= ir[4];
                            if (ir[7]) mstat[MS_REV] <= ir[6];
                            if (ir[9]) mstat[MS_STICKYV] <= ir[8];
                            if (ir[11]) mstat[MS_SAT] <= ir[10];
                        end
                        8'b0001_01??: begin   // DO UNTIL
                            if (loop_sp < 3'd4) begin
                                loop_stack[loop_sp[1:0]] <= ir[17:0];
                                loop_sp <= loop_sp + 3'd1;
                                loop_end <= ir[17:4]; loop_cond <= ir[3:0];
                                sstat[SS_LPEMPTY] <= 1'b0;
                            end else sstat[SS_LPOVER] <= 1'b1;
                            `PC_PUSH(pcn)
                        end
                        8'b0001_10??: if (wb_cond) pc <= ir[17:4];
                        8'b0001_11??: begin
                            if (wb_cond) begin `PC_PUSH(pcn) pc <= ir[17:4]; end
                        end
                        default: ;
                    endcase
                    // an instruction that evaluates CE decrements the counter
                    if (cls_cond_any && cc == 4'he) begin `CE_DECREMENT end
                    // ---- register bank swap (MAME swaps the whole core struct
                    // when MSTAT.BANK changes; no instruction that changes it
                    // also writes a core register) ----
                    if (bank_swap) begin
                        r_ax0 <= x_ax0; x_ax0 <= r_ax0; r_ax1 <= x_ax1; x_ax1 <= r_ax1;
                        r_ay0 <= x_ay0; x_ay0 <= r_ay0; r_ay1 <= x_ay1; x_ay1 <= r_ay1;
                        r_ar <= x_ar;   x_ar <= r_ar;   r_af <= x_af;   x_af <= r_af;
                        r_mx0 <= x_mx0; x_mx0 <= r_mx0; r_mx1 <= x_mx1; x_mx1 <= r_mx1;
                        r_my0 <= x_my0; x_my0 <= r_my0; r_my1 <= x_my1; x_my1 <= r_my1;
                        r_mr0 <= x_mr0; x_mr0 <= r_mr0; r_mr1 <= x_mr1; x_mr1 <= r_mr1;
                        r_mr2 <= x_mr2; x_mr2 <= r_mr2; r_mf <= x_mf;   x_mf <= r_mf;
                        r_si <= x_si;   x_si <= r_si;   r_se <= x_se;   x_se <= r_se;
                        r_sb <= x_sb;   x_sb <= r_sb;   r_sr0 <= x_sr0; x_sr0 <= r_sr0;
                        r_sr1 <= x_sr1; x_sr1 <= r_sr1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`undef PC_PUSH
`undef PC_POP
`undef LOOP_POP
`undef CNTR_POP
`undef CNTR_PUSH
`undef STAT_PUSH
`undef STAT_POP
`undef CE_DECREMENT
`undef WRITE_REG0
`undef WRITE_REG12
`undef WRITE_REG3
