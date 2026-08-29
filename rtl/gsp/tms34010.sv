//------------------------------------------------------------------------------
// TMS34010 graphics system processor for the Stun Runner core.
//
// Semantics ported from MAME 0.288 (devices/cpu/tms34010, BSD-3-Clause,
// Alex Pasadyn / Zsolt Vasvari / Aaron Giles): register files A0-A14/B0-B14
// with a shared SP, 32-bit bit-addressed PC, status register N C Z V P IE
// FE1 FS1 FE0 FS0, field moves of 1..32 bits crossing word boundaries, XY
// addressing through CONVSP/CONVDP, pixel transfers with raster ops and
// transparency, FILL / PIXBLT B / PIXBLT / LINE / DRAV, the host interface,
// the internal I/O registers and the display raster counters.
//
// Area-conscious microarchitecture: one shared 32-bit ALU, one shared barrel
// shifter/rotator and one shared 33x33 multiplier, fed from registered
// operands and consumed one clock later through a small writeback sequencer
// (S_ALU / S_SH). Every register-file write goes through a single write port.
// Field extract/insert, pixel and blit engines are multi-cycle sequences over
// those units. Every instruction costs at least one `cen` (6 MHz) and every
// external word access one more, so the core is never faster than the real
// part for memory-bound work.
//
// Memory: a single request port (mem_*), word (16-bit) granularity, variable
// latency. Everything outside the I/O register block (0xC0000000-0xC00001FF
// bit addresses) goes out this port; the parent decodes VRAM / expander /
// palette / control latches. A 1 KB direct-mapped instruction cache sits on
// the fetch path only.
//
// See docs/gsp.md for what is implemented and verified.
//------------------------------------------------------------------------------
`default_nettype none

module tms34010 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,            // 6 MHz instruction-cycle enable
    input  logic        cen_vid,        // 5 MHz video clock enable (HCOUNT increment)
    input  logic        halt_n,         // /GSPRES: 0 holds the core in reset
    input  logic        cache_flush,    // parent pulses when it modifies VRAM behind our back (SRT copies)
    // memory
    output logic [31:4] mem_addr,
    output logic        mem_req,
    output logic        mem_we,
    output logic [15:0] mem_wdata,
    input  logic [15:0] mem_rdata,
    input  logic        mem_ack,
    output logic        mem_srt,
    // host interface: 0 = HSTADRL, 1 = HSTADRH, 2 = HSTDATA, 3 = HSTCTL
    input  logic  [1:0] host_addr,
    input  logic        host_rd,
    input  logic        host_wr,
    input  logic [15:0] host_wdata,
    output logic [15:0] host_rdata,
    output logic        host_ready,
    output logic        int_out,
    // video timing
    output logic        hblank,
    output logic        vblank,
    output logic [15:0] hcount,
    output logic [15:0] vcount,
    output logic        line_start,
    output logic [15:0] r_hesync, r_heblnk, r_hsblnk, r_htotal,
    output logic [15:0] r_vesync, r_veblnk, r_vsblnk, r_vtotal,
    output logic [15:0] r_dpyctl, r_dpystrt, r_dpytap, r_dpyadr,
    // debug / bench
    output logic [31:0] dbg_pc,
    output logic        dbg_halted,
    output logic        dbg_instr,      // pulse: an instruction is about to execute at dbg_pc
    input  logic        dbg_force_di,   // bench: raise the display interrupt now
    input  logic        dbg_int_inhibit,// bench: interrupts are taken only after dbg_force_int
    input  logic        dbg_force_int,  // bench: take the pending interrupt at the next boundary (aborts a fetch in progress)
    input  logic        dbg_hold,       // bench: park at the instruction boundary (host accesses still serviced)
    output logic        dbg_idle        // bench: parked at the boundary with nothing pending
);

    // ------------------------------------------------------------------
    // I/O register indices
    // ------------------------------------------------------------------
    localparam int R_HESYNC = 0,  R_HEBLNK = 1,  R_HSBLNK = 2,  R_HTOTAL = 3;
    localparam int R_VESYNC = 4,  R_VEBLNK = 5,  R_VSBLNK = 6,  R_VTOTAL = 7;
    localparam int R_DPYCTL = 8,  R_DPYSTRT = 9, R_DPYINT = 10, R_CONTROL = 11;
    localparam int R_HSTADRL = 13, R_HSTADRH = 14, R_HSTCTLL = 15;
    localparam int R_HSTCTLH = 16, R_INTENB = 17, R_INTPEND = 18, R_CONVSP = 19;
    localparam int R_CONVDP = 20, R_PSIZE = 21, R_DPYTAP = 27, R_DPYADR = 30;

    localparam logic [15:0] INT_HI = 16'h0200, INT_DI = 16'h0400, INT_WV = 16'h0800;

    // status register bits
    localparam int SB_N = 31, SB_C = 30, SB_Z = 29, SB_V = 28, SB_P = 25, SB_IE = 21;

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    (* ramstyle = "logic" *) logic [31:0] rf [0:30] /*verilator public*/;     // A0-A14 = 0..14, SP = 15, B0-B14 = 30..16
    logic [31:0] pc /*verilator public*/;
    logic [31:0] st /*verilator public*/;
    (* ramstyle = "logic" *) logic [15:0] io [0:31] /*verilator public*/;

    logic [15:0] ir;
    logic [31:0] imm, imm2;
    logic        reset_deferred;
    logic        nmi_pend;
    logic [31:0] T;                  // scratch

    // derived from I/O registers
    logic [4:0]  sp_sh, dp_sh;                 // CONVSP/CONVDP shifts
    logic [2:0]  pxs;                          // pixel shift (log2 PSIZE)
    logic [4:0]  psz;                          // pixel size 1/2/4/8/16
    logic [15:0] pm;                           // pixel mask
    logic [3:0]  pmsk_a;                       // address bits selecting pixel within word
    logic [4:0]  rop;
    logic        transp, rop_en, srt_mode;
    logic [1:0]  wchk;
    logic        halted;

    always_comb begin
        sp_sh = ~io[R_CONVSP][4:0];
        dp_sh = ~io[R_CONVDP][4:0];
        case (io[R_PSIZE])
            16'h0002: begin pxs = 3'd1; psz = 5'd2;  pm = 16'h0003; pmsk_a = 4'he; end
            16'h0004: begin pxs = 3'd2; psz = 5'd4;  pm = 16'h000f; pmsk_a = 4'hc; end
            16'h0008: begin pxs = 3'd3; psz = 5'd8;  pm = 16'h00ff; pmsk_a = 4'h8; end
            16'h0010: begin pxs = 3'd4; psz = 5'd16; pm = 16'hffff; pmsk_a = 4'h0; end
            default:  begin pxs = 3'd0; psz = 5'd1;  pm = 16'h0001; pmsk_a = 4'hf; end
        endcase
        rop      = io[R_CONTROL][14:10];
        transp   = io[R_CONTROL][5];
        wchk     = io[R_CONTROL][7:6];
        rop_en   = (rop != 5'd0) && (rop <= 5'd21);
        srt_mode = io[R_DPYCTL][11];
        halted   = io[R_HSTCTLH][15];
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    function automatic logic [4:0] ridx(input logic r, input logic [3:0] n);
        ridx = r ? (5'd30 - {1'b0, n}) : {1'b0, n};
    endfunction
    function automatic logic [31:0] sxt16(input logic [15:0] v);
        sxt16 = {{16{v[15]}}, v};
    endfunction
    function automatic logic [31:0] sxt8(input logic [7:0] v);
        sxt8 = {{24{v[7]}}, v};
    endfunction
    // low-w-bits mask, w = 0..32
    function automatic logic [31:0] wmask(input logic [5:0] w);
        logic [31:0] m;
        for (int i = 0; i < 32; i++) m[i] = (6'(i) < w);
        wmask = m;
    endfunction
    // bits [lo, hi) of a 16-bit word at word index k (bit positions 16k..16k+15)
    function automatic logic [15:0] rmask16(input logic [5:0] lo, input logic [5:0] hi, input logic [1:0] k);
        logic [15:0] m;
        logic [5:0]  b;
        for (int j = 0; j < 16; j++) begin
            b = {k, 4'(j)};
            m[j] = (b >= lo) && (b < hi);
        end
        rmask16 = m;
    endfunction
    function automatic logic [5:0] fsize(input logic [4:0] f);
        fsize = (f == 5'd0) ? 6'd32 : {1'b0, f};
    endfunction
    function automatic logic cond_true(input logic [3:0] c, input logic [31:0] s);
        logic n, cc, z, v;
        n = s[SB_N]; cc = s[SB_C]; z = s[SB_Z]; v = s[SB_V];
        case (c)
            4'h0: cond_true = 1'b1;
            4'h1: cond_true = !n && !z;
            4'h2: cond_true = cc || z;
            4'h3: cond_true = !cc && !z;
            4'h4: cond_true = n ^ v;
            4'h5: cond_true = !(n ^ v);
            4'h6: cond_true = (n ^ v) || z;
            4'h7: cond_true = !(n ^ v) && !z;
            4'h8: cond_true = cc;
            4'h9: cond_true = !cc;
            4'ha: cond_true = z;
            4'hb: cond_true = !z;
            4'hc: cond_true = v;
            4'hd: cond_true = !v;
            4'he: cond_true = n;
            default: cond_true = !n;
        endcase
    endfunction

    // single-pixel raster op (PIXT / LINE / DRAV), values are pixel-sized
    function automatic logic [15:0] rop_pix(input logic [4:0] r, input logic [15:0] n, input logic [15:0] o, input logic [15:0] m);
        logic [16:0] sum;
        sum = {1'b0, n} + {1'b0, o};
        case (r)
            5'd1:  rop_pix = n & o;
            5'd2:  rop_pix = n & ~o;
            5'd3:  rop_pix = 16'h0;
            5'd4:  rop_pix = n | ~o;
            5'd5:  rop_pix = ~(n ^ o);
            5'd6:  rop_pix = ~o;
            5'd7:  rop_pix = ~(n | o);
            5'd8:  rop_pix = n | o;
            5'd9:  rop_pix = o;
            5'd10: rop_pix = n ^ o;
            5'd11: rop_pix = ~n & o;
            5'd12: rop_pix = 16'hffff;
            5'd13: rop_pix = ~n | o;
            5'd14: rop_pix = ~(n & o);
            5'd15: rop_pix = ~n;
            5'd16: rop_pix = sum[15:0];
            5'd17: rop_pix = (sum > {1'b0, m}) ? m : sum[15:0];
            5'd18: rop_pix = o - n;
            5'd19: rop_pix = (o > n) ? (o - n) : 16'h0;
            5'd20: rop_pix = (o > n) ? o : n;
            5'd21: rop_pix = (o > n) ? n : o;
            default: rop_pix = n;
        endcase
    endfunction

    // blit pixel op: MAME pixel_opNN(dstword, mask, srcpix) on 32-bit words (src already positioned)
    function automatic logic [31:0] blt_op(input logic [4:0] r, input logic [31:0] d, input logic [31:0] m, input logic [31:0] s);
        logic [32:0] t;
        logic [31:0] dm;
        dm = d & m;
        case (r)
            5'd0:  blt_op = s;
            5'd1:  blt_op = s & d;
            5'd2:  blt_op = s & ~d;
            5'd3:  blt_op = 32'h0;
            5'd4:  blt_op = (s | ~d) & m;
            5'd5:  blt_op = ~(s ^ d) & m;
            5'd6:  blt_op = ~d & m;
            5'd7:  blt_op = ~(s | d) & m;
            5'd8:  blt_op = (s | d) & m;
            5'd9:  blt_op = d & m;
            5'd10: blt_op = (s ^ d) & m;
            5'd11: blt_op = (~s & d) & m;
            5'd12: blt_op = m;
            5'd13: blt_op = (~s & d) & m;   // MAME op13 (== op11)
            5'd14: blt_op = ~(s & d) & m;
            5'd15: blt_op = s ^ m;
            5'd16: begin t = {1'b0, s} + {1'b0, d}; blt_op = t[31:0] & m; end
            5'd17: begin t = {1'b0, s} + {1'b0, dm}; blt_op = ($signed(t[31:0]) > $signed(m)) ? m : t[31:0]; end
            5'd18: blt_op = (d - s) & m;
            5'd19: begin t = {1'b0, s} - {1'b0, dm}; blt_op = t[32] ? 32'h0 : t[31:0]; end
            5'd20: blt_op = (s > dm) ? s : dm;
            5'd21: blt_op = (s < dm) ? s : dm;
            default: blt_op = s;
        endcase
    endfunction

    // leading-zero count of a 32-bit value (0 if v == 0)
    // Leading-zero count for LMO: the bit position of the leftmost one counted
    // down from bit 31 (0 when bit 31 is set), and 0 for v == 0.
    //
    // Written as a five-stage binary search on purpose. The obvious
    // "increment while not found" loop synthesises to 32 chained 6-bit
    // incrementers -- Add74..Add88 in the first fitted build, a 23.2 ns
    // ripple that made rf -> rf the worst path in the design (35.6 ns).
    // Each stage keeps the half that holds the leftmost one and records which
    // half that was. The bottom bit of every narrowed window is dropped: if
    // every bit above it is zero the answer is already forced, so it is never
    // read (hence the [n:1] ranges).
    function automatic logic [5:0] lzc(input logic [31:0] v);
        logic [15:1] w1;
        logic  [7:1] w2;
        logic  [3:1] w3;
        logic  [4:0] n;
        n[4] = (v[31:16] == 16'd0);
        w1   = n[4] ? v[15:1] : v[31:17];
        n[3] = (w1[15:8] == 8'd0);
        w2   = n[3] ? w1[7:1] : w1[15:9];
        n[2] = (w2[7:4] == 4'd0);
        w3   = n[2] ? w2[3:1] : w2[7:5];
        n[1] = (w3[3:2] == 2'd0);
        n[0] = ~(n[1] ? w3[1] : w3[3]);
        lzc  = (v == 32'd0) ? 6'd0 : {1'b0, n};
    endfunction

    // ------------------------------------------------------------------
    // Opcode classes
    // ------------------------------------------------------------------
    typedef enum logic [7:0] {
        OP_ILL, OP_UNIMPL, OP_REV, OP_EMU, OP_EXGPC, OP_GETPC, OP_JUMP, OP_GETST, OP_PUTST,
        OP_POPST, OP_PUSHST, OP_NOP, OP_CLRC, OP_MOVB_AA, OP_DINT, OP_ABS, OP_NEG, OP_NEGB,
        OP_NOT, OP_SEXT, OP_ZEXT, OP_SETF, OP_MOVE_RA, OP_MOVE_AR, OP_MOVE_AA, OP_MOVB_RA,
        OP_MOVB_AR, OP_TRAP, OP_CALL, OP_RETI, OP_RETS, OP_MMTM, OP_MMFM, OP_MOVI_W,
        OP_MOVI_L, OP_ADDI_W, OP_ADDI_L, OP_CMPI_W, OP_CMPI_L, OP_ANDI, OP_ORI, OP_XORI,
        OP_SUBI_W, OP_SUBI_L, OP_CALLR, OP_CALLA, OP_EINT, OP_DSJ, OP_DSJEQ, OP_DSJNE,
        OP_SETC, OP_PIXBLT_LL, OP_PIXBLT_LXY, OP_PIXBLT_XYL, OP_PIXBLT_XYXY, OP_PIXBLT_BL,
        OP_PIXBLT_BXY, OP_FILL_L, OP_FILL_XY, OP_ADDK, OP_SUBK, OP_MOVK, OP_BTST_K,
        OP_SLA_K, OP_SLL_K, OP_SRA_K, OP_SRL_K, OP_RL_K, OP_DSJS, OP_ADD, OP_ADDC, OP_SUB,
        OP_SUBB, OP_CMP, OP_BTST_R, OP_MOVE_RR, OP_MOVE_RRX, OP_AND, OP_ANDN, OP_OR, OP_XOR,
        OP_DIVS, OP_DIVU, OP_MPYS, OP_MPYU, OP_SLA_R, OP_SLL_R, OP_SRA_R, OP_SRL_R, OP_RL_R,
        OP_LMO, OP_MODS, OP_MODU, OP_MOVE_RN, OP_MOVE_NR, OP_MOVE_NN, OP_MOVB_RN, OP_MOVB_NR,
        OP_MOVE_R_NI, OP_MOVE_NI_R, OP_MOVE_NI_NI, OP_MOVB_NN, OP_MOVE_R_DN, OP_MOVE_DN_R,
        OP_MOVE_DN_DN, OP_MOVB_R_NO, OP_MOVB_NO_R, OP_MOVE_R_NO, OP_MOVE_NO_R, OP_MOVE_NO_NO,
        OP_MOVB_NO_NO, OP_JR, OP_MOVE_NO_NI, OP_MOVE_A_NI, OP_EXGF, OP_LINE, OP_ADD_XY,
        OP_SUB_XY, OP_CMP_XY, OP_CPW, OP_CVXYL, OP_MOVX, OP_MOVY, OP_PIXT_RIXY, OP_PIXT_IXYR,
        OP_PIXT_IXYIXY, OP_DRAV, OP_PIXT_RI, OP_PIXT_IR, OP_PIXT_II
    } opc_t;

    function automatic opc_t dec_op(input logic [15:0] o);
        opc_t r;
        r = OP_UNIMPL;
        casez (o[15:4])
            12'h002, 12'h003: r = OP_REV;
            12'h010: r = OP_EMU;
            12'h012, 12'h013: r = OP_EXGPC;
            12'h014, 12'h015: r = OP_GETPC;
            12'h016, 12'h017: r = OP_JUMP;
            12'h018, 12'h019: r = OP_GETST;
            12'h01a, 12'h01b: r = OP_PUTST;
            12'h01c: r = OP_POPST;
            12'h01e: r = OP_PUSHST;
            12'h02?: r = OP_ILL;
            12'h030: r = OP_NOP;
            12'h032: r = OP_CLRC;
            12'h034: r = OP_MOVB_AA;
            12'h036: r = OP_DINT;
            12'h038, 12'h039: r = OP_ABS;
            12'h03a, 12'h03b: r = OP_NEG;
            12'h03c, 12'h03d: r = OP_NEGB;
            12'h03e, 12'h03f: r = OP_NOT;
            12'h04?: r = OP_ILL;
            12'h050, 12'h051, 12'h070, 12'h071: r = OP_SEXT;
            12'h052, 12'h053, 12'h072, 12'h073: r = OP_ZEXT;
            12'h054, 12'h055, 12'h056, 12'h057, 12'h074, 12'h075, 12'h076, 12'h077: r = OP_SETF;
            12'h058, 12'h059, 12'h078, 12'h079: r = OP_MOVE_RA;
            12'h05a, 12'h05b, 12'h07a, 12'h07b: r = OP_MOVE_AR;
            12'h05c, 12'h07c: r = OP_MOVE_AA;
            12'h05e, 12'h05f: r = OP_MOVB_RA;
            12'h07e, 12'h07f: r = OP_MOVB_AR;
            12'h06?, 12'h08?: r = OP_ILL;
            12'h090, 12'h091: r = OP_TRAP;
            12'h092, 12'h093: r = OP_CALL;
            12'h094: r = OP_RETI;
            12'h096, 12'h097: r = OP_RETS;
            12'h098, 12'h099: r = OP_MMTM;
            12'h09a, 12'h09b: r = OP_MMFM;
            12'h09c, 12'h09d: r = OP_MOVI_W;
            12'h09e, 12'h09f: r = OP_MOVI_L;
            12'h0a?: r = OP_ILL;
            12'h0b0, 12'h0b1: r = OP_ADDI_W;
            12'h0b2, 12'h0b3: r = OP_ADDI_L;
            12'h0b4, 12'h0b5: r = OP_CMPI_W;
            12'h0b6, 12'h0b7: r = OP_CMPI_L;
            12'h0b8, 12'h0b9: r = OP_ANDI;
            12'h0ba, 12'h0bb: r = OP_ORI;
            12'h0bc, 12'h0bd: r = OP_XORI;
            12'h0be, 12'h0bf: r = OP_SUBI_W;
            12'h0c?: r = OP_ILL;
            12'h0d0, 12'h0d1: r = OP_SUBI_L;
            12'h0d3: r = OP_CALLR;
            12'h0d5: r = OP_CALLA;
            12'h0d6: r = OP_EINT;
            12'h0d8, 12'h0d9: r = OP_DSJ;
            12'h0da, 12'h0db: r = OP_DSJEQ;
            12'h0dc, 12'h0dd: r = OP_DSJNE;
            12'h0de: r = OP_SETC;
            12'h0e?: r = OP_ILL;
            12'h0f0: r = OP_PIXBLT_LL;
            12'h0f2: r = OP_PIXBLT_LXY;
            12'h0f4: r = OP_PIXBLT_XYL;
            12'h0f6: r = OP_PIXBLT_XYXY;
            12'h0f8: r = OP_PIXBLT_BL;
            12'h0fa: r = OP_PIXBLT_BXY;
            12'h0fc: r = OP_FILL_L;
            12'h0fe: r = OP_FILL_XY;
            12'h10?, 12'h11?, 12'h12?, 12'h13?: r = OP_ADDK;
            12'h14?, 12'h15?, 12'h16?, 12'h17?: r = OP_SUBK;
            12'h18?, 12'h19?, 12'h1a?, 12'h1b?: r = OP_MOVK;
            12'h1c?, 12'h1d?, 12'h1e?, 12'h1f?: r = OP_BTST_K;
            12'h20?, 12'h21?, 12'h22?, 12'h23?: r = OP_SLA_K;
            12'h24?, 12'h25?, 12'h26?, 12'h27?: r = OP_SLL_K;
            12'h28?, 12'h29?, 12'h2a?, 12'h2b?: r = OP_SRA_K;
            12'h2c?, 12'h2d?, 12'h2e?, 12'h2f?: r = OP_SRL_K;
            12'h30?, 12'h31?, 12'h32?, 12'h33?: r = OP_RL_K;
            12'h38?, 12'h39?, 12'h3a?, 12'h3b?, 12'h3c?, 12'h3d?, 12'h3e?, 12'h3f?: r = OP_DSJS;
            12'h40?, 12'h41?: r = OP_ADD;
            12'h42?, 12'h43?: r = OP_ADDC;
            12'h44?, 12'h45?: r = OP_SUB;
            12'h46?, 12'h47?: r = OP_SUBB;
            12'h48?, 12'h49?: r = OP_CMP;
            12'h4a?, 12'h4b?: r = OP_BTST_R;
            12'h4c?, 12'h4d?: r = OP_MOVE_RR;
            12'h4e?, 12'h4f?: r = OP_MOVE_RRX;
            12'h50?, 12'h51?: r = OP_AND;
            12'h52?, 12'h53?: r = OP_ANDN;
            12'h54?, 12'h55?: r = OP_OR;
            12'h56?, 12'h57?: r = OP_XOR;
            12'h58?, 12'h59?: r = OP_DIVS;
            12'h5a?, 12'h5b?: r = OP_DIVU;
            12'h5c?, 12'h5d?: r = OP_MPYS;
            12'h5e?, 12'h5f?: r = OP_MPYU;
            12'h60?, 12'h61?: r = OP_SLA_R;
            12'h62?, 12'h63?: r = OP_SLL_R;
            12'h64?, 12'h65?: r = OP_SRA_R;
            12'h66?, 12'h67?: r = OP_SRL_R;
            12'h68?, 12'h69?: r = OP_RL_R;
            12'h6a?, 12'h6b?: r = OP_LMO;
            12'h6c?, 12'h6d?: r = OP_MODS;
            12'h6e?, 12'h6f?: r = OP_MODU;
            12'h80?, 12'h81?, 12'h82?, 12'h83?: r = OP_MOVE_RN;
            12'h84?, 12'h85?, 12'h86?, 12'h87?: r = OP_MOVE_NR;
            12'h88?, 12'h89?, 12'h8a?, 12'h8b?: r = OP_MOVE_NN;
            12'h8c?, 12'h8d?: r = OP_MOVB_RN;
            12'h8e?, 12'h8f?: r = OP_MOVB_NR;
            12'h90?, 12'h91?, 12'h92?, 12'h93?: r = OP_MOVE_R_NI;
            12'h94?, 12'h95?, 12'h96?, 12'h97?: r = OP_MOVE_NI_R;
            12'h98?, 12'h99?, 12'h9a?, 12'h9b?: r = OP_MOVE_NI_NI;
            12'h9c?, 12'h9d?: r = OP_MOVB_NN;
            12'ha0?, 12'ha1?, 12'ha2?, 12'ha3?: r = OP_MOVE_R_DN;
            12'ha4?, 12'ha5?, 12'ha6?, 12'ha7?: r = OP_MOVE_DN_R;
            12'ha8?, 12'ha9?, 12'haa?, 12'hab?: r = OP_MOVE_DN_DN;
            12'hac?, 12'had?: r = OP_MOVB_R_NO;
            12'hae?, 12'haf?: r = OP_MOVB_NO_R;
            12'hb0?, 12'hb1?, 12'hb2?, 12'hb3?: r = OP_MOVE_R_NO;
            12'hb4?, 12'hb5?, 12'hb6?, 12'hb7?: r = OP_MOVE_NO_R;
            12'hb8?, 12'hb9?, 12'hba?, 12'hbb?: r = OP_MOVE_NO_NO;
            12'hbc?, 12'hbd?: r = OP_MOVB_NO_NO;
            12'hc??: r = OP_JR;
            12'hd0?, 12'hd1?, 12'hd2?, 12'hd3?: r = OP_MOVE_NO_NI;
            12'hd40, 12'hd41, 12'hd60, 12'hd61: r = OP_MOVE_A_NI;
            12'hd50, 12'hd51, 12'hd70, 12'hd71: r = OP_EXGF;
            12'hdf1, 12'hdf9: r = OP_LINE;
            12'he0?, 12'he1?: r = OP_ADD_XY;
            12'he2?, 12'he3?: r = OP_SUB_XY;
            12'he4?, 12'he5?: r = OP_CMP_XY;
            12'he6?, 12'he7?: r = OP_CPW;
            12'he8?, 12'he9?: r = OP_CVXYL;
            12'hec?, 12'hed?: r = OP_MOVX;
            12'hee?, 12'hef?: r = OP_MOVY;
            12'hf0?, 12'hf1?: r = OP_PIXT_RIXY;
            12'hf2?, 12'hf3?: r = OP_PIXT_IXYR;
            12'hf4?, 12'hf5?: r = OP_PIXT_IXYIXY;
            12'hf6?, 12'hf7?: r = OP_DRAV;
            12'hf8?, 12'hf9?: r = OP_PIXT_RI;
            12'hfa?, 12'hfb?: r = OP_PIXT_IR;
            12'hfc?, 12'hfd?: r = OP_PIXT_II;
            default: r = OP_UNIMPL;
        endcase
        dec_op = r;
    endfunction

    function automatic logic dec_fsel(input logic [15:0] o);
        if (o[15:12] == 4'h0) dec_fsel = o[9];               // 05xx -> 0, 07xx -> 1
        else if (o[15:12] == 4'hd && (o[11:8] == 4'h4 || o[11:8] == 4'h5)) dec_fsel = 1'b0;
        else if (o[15:12] == 4'hd && (o[11:8] == 4'h6 || o[11:8] == 4'h7)) dec_fsel = 1'b1;
        else dec_fsel = o[9];
    endfunction

    function automatic logic [2:0] dec_immn(input opc_t c, input logic [15:0] o);
        case (c)
            OP_MOVI_W, OP_ADDI_W, OP_CMPI_W, OP_SUBI_W, OP_MMTM, OP_MMFM, OP_CALLR,
            OP_DSJ, OP_DSJEQ, OP_DSJNE, OP_MOVE_R_NO, OP_MOVE_NO_R, OP_MOVE_NO_NI,
            OP_MOVB_R_NO, OP_MOVB_NO_R: dec_immn = 3'd1;
            OP_MOVI_L, OP_ADDI_L, OP_CMPI_L, OP_SUBI_L, OP_ANDI, OP_ORI, OP_XORI,
            OP_MOVE_RA, OP_MOVE_AR, OP_MOVB_RA, OP_MOVB_AR, OP_MOVE_A_NI, OP_CALLA,
            OP_MOVE_NO_NO, OP_MOVB_NO_NO: dec_immn = 3'd2;
            OP_MOVE_AA, OP_MOVB_AA: dec_immn = 3'd4;
            OP_JR: dec_immn = (o[7:0] == 8'h00) ? 3'd1 : (o[7:0] == 8'h80) ? 3'd2 : 3'd0;
            default: dec_immn = 3'd0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------------
    typedef enum logic [7:0] {
        S_RESET, S_CHECK, S_RESETVEC, S_HOST1,
        S_INT0, S_INT1, S_INT2, S_INT3,
        S_FT0, S_FT0B, S_FT1, S_FT2, S_FTDONE,
        S_DECODE, S_EXEC,
        S_ALU, S_SH,
        S_W0, S_W1,
        S_FR0, S_FR1, S_FR2, S_FR3, S_FRD0, S_FRD1, S_FRD2, S_FRD3,
        S_FW0, S_FW0B, S_FW0C, S_FW1, S_FW2, S_FW3,
        S_PW0, S_PW1, S_PW2, S_PW3, S_PR0, S_PR1, S_PR2,
        S_XY0, S_XY1, S_XY2,
        S_MUL1, S_MUL2, S_MUL3, S_DIV0, S_DIV1, S_DIV2,
        S_BLT0, S_BLT1, S_BLT1B, S_BLT1C, S_BLT1D, S_BLT2, S_BLT2B, S_BLT2C, S_BLT2D, S_BLT2E,
        S_BLT_ROW, S_BLT_ROWB, S_BLT_ROWC, S_BLT_SRC0, S_BLT_SRC0W, S_BLT_SRC0X, S_BLT_DST0, S_BLT_DST0W,
        S_BLT_PIX, S_BLT_SRCNW, S_BLT_SRCNX, S_BLT_DSTN, S_BLT_DSTNW, S_BLT_PIX1, S_BLT_PIX2, S_BLT_WRW,
        S_BLT_FLUSH, S_BLT_FLUSHR, S_BLT_NEXTROW, S_BLT_END, S_BLT_END2, S_BLT_END3, S_BLT_END3B, S_BLT_END4
    } state_t;

    // writeback selectors for the shared units
    typedef enum logic [3:0] {
        WB_NONE, WB_RD, WB_RD_IFPOS, WB_PC, WB_PCMASK, WB_T, WB_FRADDR, WB_FWADDR, WB_PUSH, WB_SP,
        WB_PWADDR, WB_PRADDR, WB_RD_FWADDR, WB_RD_FRADDR, WB_XYIN, WB_PUSHR
    } wb_t;
    typedef enum logic [2:0] {
        FL_NONE, FL_ARITH, FL_LOGIC, FL_MOVE, FL_NZV, FL_SHZ, FL_SHNZ, FL_SLA
    } fl_t;
    typedef enum logic [1:0] { SH_SHL, SH_SHR, SH_SAR, SH_ROL } shm_t;
    typedef enum logic [2:0] { A_ADD, A_SUB, A_AND, A_OR, A_XOR, A_ANDN, A_PASSB } aop_t;

    state_t state, w_ret, fr_ret, fw_ret, pw_ret, pr_ret, xy_ret, wb_next;
    wb_t    wb_sel, xy_wb;
    fl_t    wb_fl;
    logic [4:0] wb_idx;
    // Settle clocks. At 96 MHz the shared-unit combinational cones (~15-22 ns:
    // ALU adder+flags, 32-bit rotator+mask, the opcode-selected S_EXEC action
    // mux over the register-file read ports) do not fit a single 10.4 ns clock.
    // Every state that consumes such a cone one clock after its operands were
    // registered therefore spends one settle clock first: alu_ph for S_ALU, and
    // the shared mph for S_DECODE / S_EXEC / S_SH / S_XY1 / S_XY2 / S_PW2 / S_PW3 /
    // S_PR2 / S_FRD1 / S_FRD2 / S_FW0B / S_FW0C / S_BLT1B / S_BLT1D / S_BLT2D /
    // S_BLT2E / S_BLT_ROWB /
    // S_BLT_SRC0X / S_BLT_SRCNX / S_BLT_PIX2 / S_BLT_WRW / S_MUL2 / S_MUL3 /
    // S_DIV2 / S_BLT2C / S_BLT_END3 / S_BLT_END4 (mutually exclusive states, one
    // bit suffices; each sets it on entry and clears it when it acts). Each cone
    // then spans two real clocks, matching the multicycles in the SDC.
    //
    // The last six are settled for a second reason, and it is the one that makes
    // the register-file exceptions in the SDC provable rather than argued:
    //
    //   EVERY register-file write in this core now happens on the acting tick of
    //   an mph/alu_ph settled state (S_ALU, S_SH, S_EXEC, S_MUL2, S_MUL3, S_DIV2,
    //   S_BLT2C, S_BLT_END3, S_BLT_END4).
    //
    // The clock before an acting tick is that state's settle tick, and a settle
    // tick assigns nothing but mph/alu_ph. So no register the FSM owns can change
    // less than two clocks before a register-file write: the whole rf write cone
    // (rfw_en / rfw_idx / rfw_val, the opcode action mux, the 32:1 read ports,
    // state, istep, the alu/shifter operands, the blit latches) has a real
    // two-clock budget. The exceptions are the settle flags themselves and
    // `mul_p`, which reloads on every clock including settle ticks; both are
    // excluded from that multicycle in the SDC. The engine is throttled to one instruction per cen_6m (16
    // clocks) and every external word access waits for cen in S_W0, so for the
    // common cen-bound instruction these extra clocks cost little net time
    // (bench-measured on the trace windows).
    logic       alu_ph, mph;

    opc_t   opc;
    logic   fsel, rbit;
    logic [2:0] immn, immcnt;
    logic [3:0] istep;

    // decoded register indices / values
    logic [4:0]  ri_d, ri_s, rg_idx;
    logic [31:0] rdv, rsv, rgv;
    logic [5:0]  fsz;
    logic        fext;
    logic [31:0] fincv;
    logic [31:0] k32;                // ADDK/SUBK/MOVK constant
    always_comb begin
        // Instruction decode is combinational off the fetched `ir`, NOT a set of
        // registers latched in S_DECODE one clock before S_EXEC. `ir` is stable
        // from the fetch edge until the next fetch (>=16 clocks, cen-throttled),
        // so every decode/read cone below (opcode-selected S_EXEC action mux, the
        // 32:1 register-file read mux) is anchored on `ir` with the full
        // fetch->EXEC window (>=4 clocks with the S_DECODE/S_EXEC settle clocks)
        // instead of one clock, and is multicycled from `ir` in the SDC. Keeping
        // it combinational (rather than latching it at both fetch paths) avoids
        // replicating the ~700-ALM opcode decoder. `immn` stays a REGISTER
        // (latched at the S_DECODE act) because S_FTDONE compares it one clock
        // after an opcode fetch -- as a register that compare carries no ir cone.
        opc  = dec_op(ir);
        fsel = dec_fsel(ir);
        rbit = ir[4];
        ri_d  = ridx(rbit, ir[3:0]);
        ri_s  = ridx(rbit, ir[8:5]);
        rdv   = rf[ri_d];
        rsv   = rf[ri_s];
        rgv   = rf[rg_idx];
        fsz   = fsel ? fsize(st[10:6]) : fsize(st[4:0]);
        fext  = fsel ? st[11] : st[5];
        fincv = {26'd0, fsz};
        k32   = (ir[9:5] == 5'd0) ? 32'd32 : {27'd0, ir[9:5]};
    end

    // implied B registers
    logic [31:0] B_SADDR, B_SPTCH, B_DADDR, B_DPTCH, B_OFFSET, B_WSTART, B_WEND, B_DYDX;
    logic [31:0] B_COLOR0, B_COLOR1, B_COUNT, B_INC1, B_INC2, B_TEMP;
    assign B_SADDR = rf[30]; assign B_SPTCH = rf[29]; assign B_DADDR = rf[28]; assign B_DPTCH = rf[27];
    assign B_OFFSET = rf[26]; assign B_WSTART = rf[25]; assign B_WEND = rf[24]; assign B_DYDX = rf[23];
    assign B_COLOR0 = rf[22]; assign B_COLOR1 = rf[21]; assign B_COUNT = rf[20]; assign B_INC1 = rf[19];
    assign B_INC2 = rf[18]; assign B_TEMP = rf[16];

    // ------------------------------------------------------------------
    // Shared ALU (registered operands)
    // ------------------------------------------------------------------
    logic [31:0] alu_a, alu_b, alu_r;
    aop_t        alu_op;
    logic        alu_cin;
    logic        alu_n, alu_z, alu_c, alu_v;
    always_comb begin
        case (alu_op)
            A_ADD:   alu_r = alu_a + alu_b + {31'd0, alu_cin};
            A_SUB:   alu_r = alu_a - alu_b - {31'd0, alu_cin};
            A_AND:   alu_r = alu_a & alu_b;
            A_OR:    alu_r = alu_a | alu_b;
            A_XOR:   alu_r = alu_a ^ alu_b;
            A_ANDN:  alu_r = alu_a & ~alu_b;
            default: alu_r = alu_b;
        endcase
        alu_n = alu_r[31];
        alu_z = (alu_r == 32'd0);
        if (alu_op == A_SUB) begin
            alu_c = (alu_b > alu_a);
            alu_v = (alu_a[31] ^ alu_b[31]) & (alu_a[31] ^ alu_r[31]);
        end else begin
            alu_c = (~alu_a < alu_b);
            alu_v = ~(alu_a[31] ^ alu_b[31]) & (alu_a[31] ^ alu_r[31]);
        end
    end

    // ------------------------------------------------------------------
    // Shared rotator / shifter (registered operands)
    // ------------------------------------------------------------------
    logic [31:0] sh_x, sh_r, sh_rot, sh_m;
    logic [4:0]  sh_k, sh_ka;
    shm_t        sh_mode;
    logic        sh_c;
    logic [31:0] sla_mask;
    always_comb begin
        // rotate left by ka (right shifts rotate by 32-k)
        sh_ka = (sh_mode == SH_SHL || sh_mode == SH_ROL) ? sh_k : (5'd0 - sh_k);
        sh_rot = sh_x;
        if (sh_ka[0]) sh_rot = {sh_rot[30:0], sh_rot[31]};
        if (sh_ka[1]) sh_rot = {sh_rot[29:0], sh_rot[31:30]};
        if (sh_ka[2]) sh_rot = {sh_rot[27:0], sh_rot[31:28]};
        if (sh_ka[3]) sh_rot = {sh_rot[23:0], sh_rot[31:24]};
        if (sh_ka[4]) sh_rot = {sh_rot[15:0], sh_rot[31:16]};
        // mask of the k low bits (SHL) or the 32-k low bits (SHR/SAR)
        sh_m = (sh_mode == SH_SHL) ? wmask({1'b0, sh_k}) : wmask(6'd32 - {1'b0, sh_k});
        case (sh_mode)
            SH_SHL:  sh_r = sh_rot & ~sh_m;
            SH_SHR:  sh_r = sh_rot & sh_m;
            SH_SAR:  sh_r = (sh_rot & sh_m) | (sh_x[31] ? ~sh_m : 32'h0);
            default: sh_r = sh_rot;
        endcase
        sh_c = (sh_k != 5'd0) && ((sh_mode == SH_SHL || sh_mode == SH_ROL) ? sh_rot[0] : sh_rot[31]);
        sla_mask = ~wmask(6'd31 - {1'b0, sh_k}) & 32'h7fffffff;
    end

    // ------------------------------------------------------------------
    // Shared multiplier (registered operands, registered product)
    // ------------------------------------------------------------------
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] mul_p;
    logic [63:0] mul_res;
    always_ff @(posedge clk) mul_p <= mul_a * mul_b;
    assign mul_res = mul_p[63:0];

    // ------------------------------------------------------------------
    // Window compare unit (signed 16-bit against WSTART/WEND)
    // ------------------------------------------------------------------
    logic [31:0] win_xy;
    logic win_xlt, win_xgt, win_ylt, win_ygt, win_out;
    always_comb begin
        win_xlt = $signed(win_xy[15:0])  < $signed(B_WSTART[15:0]);
        win_xgt = $signed(win_xy[15:0])  > $signed(B_WEND[15:0]);
        win_ylt = $signed(win_xy[31:16]) < $signed(B_WSTART[31:16]);
        win_ygt = $signed(win_xy[31:16]) > $signed(B_WEND[31:16]);
        win_out = win_xlt | win_xgt | win_ylt | win_ygt;
    end

    // ------------------------------------------------------------------
    // Word primitive
    // ------------------------------------------------------------------
    logic [27:0] w_addr;
    logic        w_we, w_srt;
    logic [15:0] w_wdata;
    logic [15:0] mrd;
    logic        w_is_io;
    assign w_is_io = (w_addr[27:5] == 23'h600000);

    // instruction cache
    logic        ic_lu_en, ic_hit, ic_fill, ic_inv;
    logic [15:0] ic_data, ic_fill_data;
    logic [27:0] ic_lu_addr, ic_fill_addr, ic_inv_addr;
    gsp_icache icache (
        .clk(clk), .reset(reset || !halt_n), .flush(cache_flush),
        .lu_en(ic_lu_en), .lu_addr(ic_lu_addr), .hit(ic_hit), .data(ic_data),
        .fill_en(ic_fill), .fill_addr(ic_fill_addr), .fill_data(ic_fill_data),
        .inv_en(ic_inv), .inv_addr(ic_inv_addr)
    );
    logic [2:0]  ft_dst;

    // field engines
    logic [31:0] fr_addr, fr_val;
    logic [5:0]  fr_size;
    logic        fr_sext, fr_third;
    logic [15:0] fr_w0, fr_w1;
    logic [31:0] fw_addr, fw_data, fw_dlo;
    logic [15:0] fw_dhi;
    logic [5:0]  fw_size;
    logic [1:0]  fw_k, fw_nw;
    logic [15:0] fw_dk, fw_mk;
    always_comb begin
        fw_mk = rmask16({2'b0, fw_addr[3:0]}, {2'b0, fw_addr[3:0]} + fw_size, fw_k);
        case (fw_k)
            2'd0:    fw_dk = fw_dlo[15:0];
            2'd1:    fw_dk = fw_dlo[31:16];
            default: fw_dk = fw_dhi;
        endcase
    end

    // pixel engines
    logic [31:0] pw_addr, pr_addr;
    logic [15:0] pw_data, pr_val, pw_new, pw_pmask;
    logic [3:0]  pw_sc, pr_sc;
    assign pw_sc = pw_addr[3:0] & pmsk_a;
    assign pr_sc = pr_addr[3:0] & pmsk_a;
    assign pw_pmask = rmask16({2'b0, pw_sc}, {2'b0, pw_sc} + {1'b0, psz}, 2'd0);

    // XY -> linear sequence
    logic [31:0] xy_in;
    logic [4:0]  xy_sh;

    // divide
    logic        div_start, div_done;
    logic [63:0] div_num, div_quo, div_in;
    logic [31:0] div_den, div_rem;
    logic        div_neg_q, div_neg_r, div_signed, div_is_mod;
    gsp_div divider (.clk(clk), .reset(reset), .start(div_start), .num(div_num), .den(div_den),
                     .done(div_done), .quo(div_quo), .rem(div_rem));

    // blit engine
    logic        blt_mode_fill, blt_mode_b, blt_src_lin, blt_dst_lin, blt_yrev, blt_req_src;
    logic [15:0] blt_dx, blt_dy, blt_x, blt_y;
    logic [31:0] blt_saddr, blt_srow, blt_drow;
    logic [27:0] blt_swa, blt_dwa;
    logic [4:0]  blt_sbit, blt_dbit;
    logic [31:0] blt_sw;                    // source word, current pixel at bit 0
    logic [31:0] blt_dword, blt_dmask, blt_pix;
    logic [31:0] blt_dstxy;
    logic [4:0]  blt_sbpp;
    logic [2:0]  blt_sbpp_l;                // log2
    logic signed [16:0] bc_sx, bc_sy, bc_ex, bc_ey;

    // interrupt/trap bookkeeping
    logic [31:0] int_vec;
    logic        int_push, force_pend;
    logic        host_pend, host_we;
    logic [15:0] host_data;

    // video counters
    logic [15:0] hc, vc;

    // register-file write port (single)
    logic        rfw_en;
    logic [4:0]  rfw_idx;
    logic [31:0] rfw_val;

    // ------------------------------------------------------------------
    // I/O register write with side effects (shared by GSP and host paths)
    // ------------------------------------------------------------------
    task automatic io_write(input logic [4:0] idx, input logic [15:0] d, input logic external);
        logic [15:0] o, n;
        o = io[idx];
        case (idx)
            5'd15: begin  // HSTCTLL
                if (!external) begin
                    n = (o & 16'hff8f) | (d & 16'h0070);
                    n = n | (d & 16'h0080);
                    n = n & (d | ~16'h0008);
                end else begin
                    n = (o & 16'hfff8) | (d & 16'h0007);
                    n = n & (d | ~16'h0080);
                    n = n | (d & 16'h0008);
                end
                io[idx] <= n;
                if (!o[3] && n[3]) io[R_INTPEND] <= io[R_INTPEND] | INT_HI;
                else if (o[3] && !n[3]) io[R_INTPEND] <= io[R_INTPEND] & ~INT_HI;
            end
            5'd16: begin  // HSTCTLH
                io[idx] <= d;
                if (d[8]) nmi_pend <= 1'b1;
            end
            5'd18: begin  // INTPEND: only WV/DI can be cleared
                n = o;
                if (!d[11]) n = n & ~INT_WV;
                if (!d[10]) n = n & ~INT_DI;
                io[idx] <= n;
            end
            5'd28, 5'd29: begin end
            default: io[idx] <= d;
        endcase
    endtask

    function automatic logic [15:0] io_read(input logic [4:0] idx);
        case (idx)
            5'd28: io_read = hc;
            5'd29: io_read = vc;
            default: io_read = io[idx];
        endcase
    endfunction

    // ------------------------------------------------------------------
    // Main state machine
    // ------------------------------------------------------------------
    logic [31:0] t32;
    logic [15:0] t16;
    logic [5:0]  k6;
    logic        tb;
    logic [4:0]  db5, sb5;

    always_ff @(posedge clk) begin
        // pulses / defaults
        ic_lu_en   <= 1'b0;
        ic_fill    <= 1'b0;
        ic_inv     <= 1'b0;
        host_ready <= 1'b0;
        dbg_instr  <= 1'b0;
        div_start  <= 1'b0;
        rfw_en = 1'b0; rfw_idx = 5'd0; rfw_val = 32'd0;

        // ---------------- host register accesses (any time) ----------------
        if (host_wr) begin
            case (host_addr)
                2'd0: io[R_HSTADRL] <= host_wdata;
                2'd1: io[R_HSTADRH] <= host_wdata;
                2'd2: begin host_pend <= 1'b1; host_we <= 1'b1; host_data <= host_wdata; end
                default: begin
                    io_write(5'd16, {host_wdata[15:8], io[R_HSTCTLH][7:0]}, 1'b1);
                    io_write(5'd15, {io[R_HSTCTLL][15:8], host_wdata[7:0]}, 1'b1);
                end
            endcase
            if (host_addr != 2'd2) host_ready <= 1'b1;
        end
        if (host_rd) begin
            case (host_addr)
                2'd0: begin host_rdata <= io[R_HSTADRL]; host_ready <= 1'b1; end
                2'd1: begin host_rdata <= io[R_HSTADRH]; host_ready <= 1'b1; end
                2'd2: begin host_pend <= 1'b1; host_we <= 1'b0; end
                default: begin host_rdata <= {io[R_HSTCTLH][15:8], io[R_HSTCTLL][7:0]}; host_ready <= 1'b1; end
            endcase
        end
        if (dbg_force_di) io[R_INTPEND] <= io[R_INTPEND] | INT_DI;
        if (dbg_force_int) force_pend <= 1'b1;

        // ---------------- video raster ----------------
        line_start <= 1'b0;
        if (cen_vid) begin
            if (hc >= io[R_HTOTAL]) begin
                hc <= 16'd0;
                vc <= (vc >= io[R_VTOTAL]) ? 16'd0 : vc + 16'd1;
                line_start <= 1'b1;
            end else begin
                hc <= hc + 16'd1;
            end
        end
        if (line_start) begin
            if (io[R_DPYCTL][15] && vc == io[R_DPYINT]) io[R_INTPEND] <= io[R_INTPEND] | INT_DI;
            if (vc == io[R_VSBLNK]) io[R_DPYADR] <= io[R_DPYSTRT];
            else if (vc >= io[R_VEBLNK] && vc < io[R_VSBLNK]) begin
                if (io[R_DPYADR][1:0] == 2'b00)
                    io[R_DPYADR] <= ((io[R_DPYADR] & 16'hfffc) - (io[R_DPYCTL] & 16'h03fc)) | (io[R_DPYSTRT] & 16'h0003);
                else
                    io[R_DPYADR] <= (io[R_DPYADR] & 16'hfffc) | ((io[R_DPYADR] - 16'd1) & 16'h0003);
            end
        end

        if (reset || !halt_n) begin
            state <= S_RESET;
            mem_req <= 1'b0;
            mem_we  <= 1'b0;
            mem_srt <= 1'b0;
            host_pend <= 1'b0;
            nmi_pend <= 1'b0;
            force_pend <= 1'b0;
            hc <= 16'd0;
            vc <= 16'd0;
            for (int i = 0; i < 32; i++) io[i] <= 16'h0;
            io[R_HSTCTLH] <= 16'h8000;          // halt on reset (/HCS)
            st <= 32'h0000_0010;
            pc <= 32'h0;
            reset_deferred <= 1'b1;
            istep <= 4'd0;
            alu_ph <= 1'b0;
            mph    <= 1'b0;
        end else begin
            case (state)
            // ---------------------------------------------------------------
            S_RESET: state <= S_CHECK;

            S_CHECK: begin
                istep <= 4'd0;
                if (host_pend) begin
                    host_pend <= 1'b0;
                    w_addr  <= {io[R_HSTADRH], io[R_HSTADRL][15:4]};
                    w_we    <= host_we;
                    w_wdata <= host_data;
                    w_srt   <= 1'b0;
                    w_ret   <= S_HOST1;
                    state   <= S_W0;
                end else if (halted) begin
                    state <= S_CHECK;
                end else if (reset_deferred) begin
                    fr_addr <= 32'hffffffe0; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_RESETVEC;
                    state <= S_FR0;
                end else if (dbg_hold) begin
                    state <= S_CHECK;
                end else if (nmi_pend && (!dbg_int_inhibit || force_pend)) begin
                    nmi_pend <= 1'b0;
                    force_pend <= 1'b0;
                    io[R_HSTCTLH] <= io[R_HSTCTLH] & ~16'h0100;
                    int_vec  <= 32'hfffffee0;
                    int_push <= !io[R_HSTCTLH][9];
                    state    <= S_INT0;
                end else if (st[SB_IE] && ((io[R_INTPEND] & io[R_INTENB] & 16'h0e00) != 16'h0) && (!dbg_int_inhibit || force_pend)) begin
                    int_push <= 1'b1;
                    force_pend <= 1'b0;
                    if ((io[R_INTPEND] & io[R_INTENB] & INT_HI) != 16'h0)      int_vec <= 32'hfffffec0;
                    else if ((io[R_INTPEND] & io[R_INTENB] & INT_DI) != 16'h0) int_vec <= 32'hfffffea0;
                    else                                                        int_vec <= 32'hfffffe80;
                    state <= S_INT0;
                end else begin
                    dbg_instr <= 1'b1;
                    ft_dst <= 3'd0;
                    state  <= S_FT0;
                end
            end
            S_RESETVEC: begin
                pc <= fr_val & 32'hfffffff0;
                reset_deferred <= 1'b0;
                state <= S_CHECK;
            end
            S_HOST1: begin
                host_rdata <= mrd;
                host_ready <= 1'b1;
                if ((w_we && io[R_HSTCTLH][11]) || (!w_we && io[R_HSTCTLH][12]))
                    {io[R_HSTADRH], io[R_HSTADRL]} <= {io[R_HSTADRH], io[R_HSTADRL]} + 32'h10;
                state <= S_CHECK;
            end

            // interrupt / trap entry: push pc, push st, st = 0x10, pc = [vec]
            S_INT0: begin
                if (int_push) begin
                    alu_a <= rf[15]; alu_b <= 32'h20; alu_op <= A_SUB; alu_cin <= 1'b0;
                    fw_size <= 6'd32; fw_data <= pc; fw_ret <= S_INT1;
                    wb_sel <= WB_PUSH; wb_fl <= FL_NONE; wb_next <= S_FW0; state <= S_ALU;
                end else state <= S_INT2;
            end
            S_INT1: begin
                alu_a <= rf[15]; alu_b <= 32'h20; alu_op <= A_SUB; alu_cin <= 1'b0;
                fw_size <= 6'd32; fw_data <= st; fw_ret <= S_INT2;
                wb_sel <= WB_PUSH; wb_fl <= FL_NONE; wb_next <= S_FW0; state <= S_ALU;
            end
            S_INT2: begin
                st <= 32'h0000_0010;
                fr_addr <= int_vec; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_INT3;
                state <= S_FR0;
            end
            S_INT3: begin
                pc <= fr_val & 32'hfffffff0;
                state <= S_CHECK;
            end

            // ---------------- fetch (opcode / immediate) through the cache ----------------
            S_FT0: begin
                if (dbg_force_int && ft_dst == 3'd0) state <= S_CHECK;
                else if (cen) begin
                    ic_lu_en   <= 1'b1;
                    ic_lu_addr <= pc[31:4];
                    state      <= S_FT0B;
                end
            end
            S_FT0B: begin
                if (dbg_force_int && ft_dst == 3'd0) state <= S_CHECK;
                else state <= S_FT1;
            end
            S_FT1: begin
                if (dbg_force_int && ft_dst == 3'd0) state <= S_CHECK;
                else if (ic_hit) begin
                    case (ft_dst)
                        3'd0: ir <= ic_data;
                        3'd1: imm[15:0] <= ic_data;
                        3'd2: imm[31:16] <= ic_data;
                        3'd3: imm2[15:0] <= ic_data;
                        default: imm2[31:16] <= ic_data;
                    endcase
                    pc <= pc + 32'h10;
                    state <= S_FTDONE;
                end else begin
                    mem_addr <= pc[31:4];
                    mem_we   <= 1'b0;
                    mem_srt  <= 1'b0;
                    mem_req  <= 1'b1;
                    state    <= S_FT2;
                end
            end
            S_FT2: begin
                if (mem_ack) begin
                    mem_req <= 1'b0;
                    ic_fill <= 1'b1;
                    ic_fill_addr <= pc[31:4];
                    ic_fill_data <= mem_rdata;
                    case (ft_dst)
                        3'd0: ir <= mem_rdata;
                        3'd1: imm[15:0] <= mem_rdata;
                        3'd2: imm[31:16] <= mem_rdata;
                        3'd3: imm2[15:0] <= mem_rdata;
                        default: imm2[31:16] <= mem_rdata;
                    endcase
                    pc <= pc + 32'h10;
                    state <= S_FTDONE;
                end
            end
            S_FTDONE: begin
                if (ft_dst == 3'd0) state <= S_DECODE;
                else if (immcnt == immn) state <= S_EXEC;
                else begin
                    immcnt <= immcnt + 3'd1;
                    ft_dst <= immcnt + 3'd1;
                    state  <= S_FT0;
                end
            end
            // One settle clock, then act: the dec_immn cone off `ir` then has two
            // clocks to the captures here (immn/immcnt/ft_dst/state), three from
            // the fetch edge -- the 3/2 ir multicycle for these dests in the SDC.
            S_DECODE: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                istep <= 4'd0;
                immn  <= dec_immn(opc, ir);
                if (dec_immn(opc, ir) != 3'd0) begin
                    immcnt <= 3'd1;
                    ft_dst <= 3'd1;
                    state  <= S_FT0;
                end else state <= S_EXEC;
            end

            // ---------------- shared ALU / shifter writeback ----------------
            S_ALU: if (!alu_ph) alu_ph <= 1'b1; else begin
                alu_ph <= 1'b0;
                state <= wb_next;
                case (wb_sel)
                    WB_RD:        begin rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = alu_r; end
                    WB_RD_IFPOS:  if (!alu_r[31] && !alu_z) begin rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = alu_r; end
                    WB_PC:        pc <= alu_r;
                    WB_PCMASK:    pc <= alu_r & 32'hfffffff0;
                    WB_T:         T <= alu_r;
                    WB_FRADDR:    fr_addr <= alu_r;
                    WB_FWADDR:    fw_addr <= alu_r;
                    WB_PUSH:      begin fw_addr <= alu_r; rfw_en = 1'b1; rfw_idx = 5'd15; rfw_val = alu_r; end
                    WB_SP:        begin rfw_en = 1'b1; rfw_idx = 5'd15; rfw_val = alu_r; end
                    WB_PWADDR:    pw_addr <= alu_r;
                    WB_PRADDR:    pr_addr <= alu_r;
                    WB_RD_FWADDR: begin fw_addr <= alu_r; rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = alu_r; end
                    WB_RD_FRADDR: begin fr_addr <= alu_r; rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = alu_r; end
                    WB_XYIN:      blt_saddr <= alu_r;
                    WB_PUSHR:     begin fw_addr <= alu_r; fw_data <= rgv; rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = alu_r; end
                    default: begin end
                endcase
                case (wb_fl)
                    FL_ARITH: begin st[SB_N] <= alu_n; st[SB_Z] <= alu_z; st[SB_C] <= alu_c; st[SB_V] <= alu_v; end
                    FL_LOGIC: st[SB_Z] <= alu_z;
                    FL_MOVE:  begin st[SB_N] <= alu_n; st[SB_Z] <= alu_z; st[SB_V] <= 1'b0; end
                    FL_NZV:   begin st[SB_N] <= alu_n; st[SB_Z] <= alu_z; st[SB_V] <= alu_v; end
                    default: begin end
                endcase
            end
            S_SH: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                state <= wb_next;
                case (wb_sel)
                    WB_RD:     begin rfw_en = 1'b1; rfw_idx = wb_idx; rfw_val = sh_r; end
                    WB_T:      T <= sh_r;
                    WB_FWADDR: fw_addr <= sh_r;
                    default: begin end
                endcase
                case (wb_fl)
                    FL_SHZ:  begin st[SB_C] <= sh_c; st[SB_Z] <= (sh_r == 32'd0); end
                    FL_SHNZ: begin st[SB_C] <= sh_c; st[SB_Z] <= (sh_r == 32'd0); st[SB_N] <= sh_r[31]; end
                    FL_SLA:  begin
                        st[SB_C] <= sh_c; st[SB_Z] <= (sh_r == 32'd0); st[SB_N] <= sh_r[31];
                        st[SB_V] <= (((sh_x[31] ? (sh_x ^ sla_mask) : sh_x) & sla_mask) != 32'd0);
                    end
                    default: begin end
                endcase
            end

            // ---------------- word primitive ----------------
            S_W0: begin
                if (w_is_io) begin
                    if (w_we) io_write(w_addr[4:0], w_wdata, 1'b0);
                    mrd   <= io_read(w_addr[4:0]);
                    state <= w_ret;
                end else if (cen) begin
                    mem_addr  <= w_addr;
                    mem_we    <= w_we;
                    mem_wdata <= w_wdata;
                    mem_srt   <= w_srt;
                    mem_req   <= 1'b1;
                    if (w_we) begin ic_inv <= 1'b1; ic_inv_addr <= w_addr; end
                    state <= S_W1;
                end
            end
            S_W1: begin
                if (mem_ack) begin
                    mem_req <= 1'b0;
                    mem_we  <= 1'b0;
                    mem_srt <= 1'b0;
                    mrd     <= mem_rdata;
                    state   <= w_ret;
                end
            end

            // ---------------- field read: fr_addr/fr_size/fr_sext -> fr_val ----------------
            S_FR0: begin
                w_addr <= fr_addr[31:4]; w_we <= 1'b0; w_srt <= 1'b0; w_ret <= S_FR1;
                fr_third <= 1'b0;
                state <= S_W0;
            end
            S_FR1: begin
                fr_w0 <= mrd;
                fr_w1 <= 16'h0;
                if ({2'b0, fr_addr[3:0]} + fr_size > 6'd16) begin
                    w_addr <= fr_addr[31:4] + 28'd1; w_ret <= S_FR2; state <= S_W0;
                end else state <= S_FRD0;
            end
            S_FR2: begin
                fr_w1 <= mrd;
                if ({2'b0, fr_addr[3:0]} + fr_size > 6'd32) begin
                    w_addr <= fr_addr[31:4] + 28'd2; w_ret <= S_FR3; state <= S_W0;
                end else state <= S_FRD0;
            end
            S_FR3: begin
                fr_third <= 1'b1;         // third word in mrd
                state <= S_FRD0;
            end
            S_FRD0: begin
                sh_x <= {fr_w1, fr_w0}; sh_k <= {1'b0, fr_addr[3:0]}; sh_mode <= SH_SHR;
                state <= S_FRD1;
            end
            S_FRD1: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                T <= sh_r;
                sh_x <= {16'h0, mrd}; sh_k <= 5'd0 - {1'b0, fr_addr[3:0]}; sh_mode <= SH_SHL;
                state <= (fr_third && fr_addr[3:0] != 4'h0) ? S_FRD2 : S_FRD3;
            end
            S_FRD2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                T <= T | sh_r;
                state <= S_FRD3;
            end
            S_FRD3: begin
                t32 = T & wmask(fr_size);
                if (fr_sext && fr_size != 6'd32 && T[fr_size[4:0] - 5'd1]) t32 = t32 | ~wmask(fr_size);
                fr_val <= t32;
                state  <= fr_ret;
            end

            // ---------------- field write: fw_addr/fw_size/fw_data ----------------
            S_FW0: begin
                sh_x <= fw_data; sh_k <= {1'b0, fw_addr[3:0]}; sh_mode <= SH_SHL;
                k6 = {2'b0, fw_addr[3:0]} + fw_size;
                fw_nw <= (k6 > 6'd32) ? 2'd3 : (k6 > 6'd16) ? 2'd2 : 2'd1;
                fw_k  <= 2'd0;
                state <= S_FW0B;
            end
            S_FW0B: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                fw_dlo <= sh_r;
                sh_k <= 5'd0 - {1'b0, fw_addr[3:0]}; sh_mode <= SH_SHR;
                state <= S_FW0C;
            end
            S_FW0C: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                fw_dhi <= (fw_addr[3:0] == 4'h0) ? 16'h0 : sh_r[15:0];
                state <= S_FW1;
            end
            S_FW1: begin
                w_addr <= fw_addr[31:4] + {26'd0, fw_k};
                w_srt  <= 1'b0;
                if (fw_mk == 16'hffff) begin
                    w_we <= 1'b1; w_wdata <= fw_dk; w_ret <= S_FW3;
                end else begin
                    w_we <= 1'b0; w_ret <= S_FW2;
                end
                state <= S_W0;
            end
            S_FW2: begin
                w_we <= 1'b1; w_wdata <= (mrd & ~fw_mk) | (fw_dk & fw_mk); w_ret <= S_FW3;
                state <= S_W0;
            end
            S_FW3: begin
                if ({1'b0, fw_k} + 3'd1 < {1'b0, fw_nw}) begin
                    fw_k  <= fw_k + 2'd1;
                    state <= S_FW1;
                end else state <= fw_ret;
            end

            // ---------------- pixel write: pw_addr/pw_data ----------------
            S_PW0: begin
                w_addr <= pw_addr[31:4];
                if (srt_mode) begin
                    w_we <= 1'b1; w_srt <= 1'b1; w_wdata <= 16'h0; w_ret <= pw_ret;
                end else if (psz == 5'd16 && !rop_en && !transp) begin
                    w_we <= 1'b1; w_srt <= 1'b0; w_wdata <= pw_data; w_ret <= pw_ret;
                end else begin
                    w_we <= 1'b0; w_srt <= 1'b0; w_ret <= S_PW1;
                end
                state <= S_W0;
            end
            S_PW1: begin
                sh_x <= {16'h0, mrd}; sh_k <= {1'b0, pw_sc}; sh_mode <= SH_SHR;
                state <= S_PW2;
            end
            S_PW2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                t16 = sh_r[15:0] & pm;                                       // old pixel
                t16 = rop_en ? (rop_pix(rop, pw_data & pm, t16, pm) & pm) : (pw_data & pm);
                pw_new <= t16;
                sh_x <= {16'h0, t16}; sh_k <= {1'b0, pw_sc}; sh_mode <= SH_SHL;
                state <= (transp && t16 == 16'h0) ? pw_ret : S_PW3;
            end
            S_PW3: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                w_we <= 1'b1; w_wdata <= (mrd & ~pw_pmask) | sh_r[15:0]; w_ret <= pw_ret;
                state <= S_W0;
            end
            // ---------------- pixel read: pr_addr -> pr_val ----------------
            S_PR0: begin
                w_addr <= pr_addr[31:4]; w_we <= 1'b0; w_srt <= srt_mode; w_ret <= S_PR1;
                state <= S_W0;
            end
            S_PR1: begin
                sh_x <= {16'h0, mrd}; sh_k <= {1'b0, pr_sc}; sh_mode <= SH_SHR;
                state <= S_PR2;
            end
            S_PR2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                pr_val <= srt_mode ? 16'h0 : (sh_r[15:0] & pm);
                state  <= pr_ret;
            end

            // ---------------- XY -> linear: xy_in, xy_sh -> (xy_wb) ----------------
            S_XY0: begin
                sh_x <= sxt16(xy_in[31:16]); sh_k <= xy_sh; sh_mode <= SH_SHL;
                state <= S_XY1;
            end
            S_XY1: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                alu_a <= sh_r; alu_b <= sxt16(xy_in[15:0]) << pxs; alu_op <= A_ADD; alu_cin <= 1'b0;
                state <= S_XY2;
            end
            // settle: consumes alu_r one state after S_XY1 registered the operands
            S_XY2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                alu_a <= alu_r; alu_b <= B_OFFSET;
                wb_sel <= xy_wb; wb_fl <= FL_NONE; wb_next <= xy_ret;
                state <= S_ALU;
            end

            // ---------------- multiply / divide ----------------
            S_MUL1: state <= S_MUL2;              // product registers
            S_MUL2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = mul_res[63:32];
                st[SB_Z] <= (mul_res == 64'd0);
                if (opc == OP_MPYS) st[SB_N] <= mul_res[63];
                state <= S_MUL3;
            end
            // Settle tick: S_MUL2 writes the register file on its own tick, so
            // without this S_MUL3's write would land one clock later and the
            // rf -> rf multicycle of 2 would not hold for that pair. mul_a/mul_b
            // are unchanged, so mul_res is stable across the extra clock.
            S_MUL3: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                rfw_en = 1'b1; rfw_idx = ri_d | 5'd1; rfw_val = mul_res[31:0];
                state <= S_CHECK;
            end
            S_DIV0: begin
                div_num <= div_neg_r ? (64'd0 - div_in) : div_in;
                div_start <= 1'b1;
                state <= S_DIV1;
            end
            S_DIV1: begin
                if (div_done) begin
                    T <= div_neg_r ? (32'd0 - div_rem) : div_rem;          // remainder (sign of dividend)
                    div_in <= div_neg_q ? (64'd0 - div_quo) : div_quo;    // quotient
                    state <= S_DIV2;
                end
            end
            S_DIV2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                state <= S_CHECK;
                if (div_is_mod) begin
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = T;
                    st[SB_Z] <= (T == 32'd0);
                    if (div_signed) st[SB_N] <= T[31];
                end else if (ir[0] == 1'b0) begin
                    if (div_signed ? (div_in[63:31] != {33{div_in[31]}}) : (div_in[63:32] != 32'd0)) begin
                        st[SB_V] <= 1'b1;
                    end else begin
                        rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = div_in[31:0];
                        st[SB_Z] <= (div_in[31:0] == 32'd0);
                        if (div_signed) st[SB_N] <= div_in[31];
                        istep <= 4'd1; state <= S_EXEC;         // second write: remainder
                    end
                end else begin
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = div_in[31:0];
                    st[SB_Z] <= (div_in[31:0] == 32'd0);
                    if (div_signed) st[SB_N] <= div_in[31];
                end
            end

            // ---------------- blit engine (FILL / PIXBLT B / PIXBLT) ----------------
            S_BLT0: begin
                // window clipping for XY destinations (apply_window)
                bc_sx <= $signed({blt_dstxy[15], blt_dstxy[15:0]});
                bc_sy <= $signed({blt_dstxy[31], blt_dstxy[31:16]});
                bc_ex <= $signed({blt_dstxy[15], blt_dstxy[15:0]}) + $signed({blt_dx[15], blt_dx}) - 17'sd1;
                bc_ey <= $signed({blt_dstxy[31], blt_dstxy[31:16]}) + $signed({blt_dy[15], blt_dy}) - 17'sd1;
                if (!blt_dst_lin && wchk != 2'd0) begin
                    st[SB_V] <= (wchk == 2'd1);
                    state <= S_BLT1;
                end else state <= S_BLT2;
            end
            S_BLT1: begin
                // X clip: start
                begin
                    logic signed [16:0] wsx, wex;
                    wsx = $signed({B_WSTART[15], B_WSTART[15:0]});
                    wex = $signed({B_WEND[15], B_WEND[15:0]});
                    sh_x <= 32'(wsx - bc_sx); sh_k <= {2'b0, blt_sbpp_l}; sh_mode <= SH_SHL;   // diff * srcbpp
                    tb = (wsx > bc_sx);
                    if (tb) begin bc_sx <= wsx; st[SB_V] <= 1'b1; end
                    if (bc_ex > wex) begin bc_ex <= wex; st[SB_V] <= 1'b1; end
                    state <= (tb && !blt_mode_fill) ? S_BLT1B : S_BLT1C;
                end
            end
            S_BLT1B: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_saddr <= blt_saddr + sh_r;
                state <= S_BLT1C;
            end
            S_BLT1C: begin
                begin
                    logic signed [16:0] wsy, wey;
                    wsy = $signed({B_WSTART[31], B_WSTART[31:16]});
                    wey = $signed({B_WEND[31], B_WEND[31:16]});
                    sh_x <= 32'(wsy - bc_sy); sh_k <= sp_sh; sh_mode <= SH_SHL;                 // diff * convsp
                    tb = (wsy > bc_sy);
                    if (tb) begin bc_sy <= wsy; st[SB_V] <= 1'b1; end
                    if (bc_ey > wey) begin bc_ey <= wey; st[SB_V] <= 1'b1; end
                    state <= (tb && !blt_mode_fill) ? S_BLT1D : S_BLT2;
                end
            end
            S_BLT1D: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_saddr <= blt_saddr + sh_r;
                state <= S_BLT2;
            end
            S_BLT2: begin
                blt_dstxy <= {bc_sy[15:0], bc_sx[15:0]};
                blt_dx <= 16'(bc_ex - bc_sx + 17'sd1);
                blt_dy <= 16'(bc_ey - bc_sy + 17'sd1);
                state <= S_BLT2B;
            end
            S_BLT2B: begin
                // linear destination address
                if (blt_dst_lin) begin
                    T <= B_DADDR;
                    state <= S_BLT2C;
                end else begin
                    xy_in <= blt_dstxy; xy_sh <= dp_sh; xy_wb <= WB_T; xy_ret <= S_BLT2C;
                    state <= S_XY0;
                end
            end
            S_BLT2C: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                // bail if clipped away, window mode 1 -> WV interrupt
                t32 = T & ~{27'd0, psz - 5'd1};
                if ($signed(blt_dx) <= 0 || $signed(blt_dy) <= 0) begin
                    state <= S_CHECK;
                end else if (wchk == 2'd1 && !blt_dst_lin) begin
                    st[SB_V] <= 1'b0;
                    rfw_en = 1'b1; rfw_idx = 5'd28; rfw_val = blt_dstxy;
                    istep <= 4'd1; state <= S_EXEC;           // second write: DYDX
                end else begin
                    blt_srow <= blt_saddr;
                    blt_drow <= t32;
                    blt_y    <= 16'd0;
                    st[SB_P] <= 1'b1;
                    // y reverse (PIXBLT only) for non-linear operands
                    if (!blt_mode_fill && !blt_mode_b && (!blt_src_lin || !blt_dst_lin) && blt_yrev) begin
                        sh_x <= sxt16(blt_dy) - 32'd1; sh_k <= sp_sh; sh_mode <= SH_SHL;
                        state <= S_BLT2D;
                    end else state <= S_BLT_ROW;
                end
            end
            S_BLT2D: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_srow <= blt_srow + sh_r;
                sh_k <= dp_sh;
                state <= S_BLT2E;
            end
            S_BLT2E: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_drow <= blt_drow + sh_r;
                state <= S_BLT_ROW;
            end
            S_BLT_ROW: begin
                blt_swa  <= blt_srow[31:4];
                blt_dwa  <= blt_drow[31:4];
                blt_sbit <= {1'b0, blt_srow[3:0]};
                blt_dbit <= {1'b0, blt_drow[3:0]};
                blt_x    <= 16'd0;
                blt_dword <= 32'd0;
                sh_x <= {16'h0, pm}; sh_k <= {1'b0, blt_drow[3:0]}; sh_mode <= SH_SHL;   // initial dest mask
                state <= S_BLT_ROWB;
            end
            S_BLT_ROWB: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_dmask <= sh_r;
                if (blt_mode_fill) state <= S_BLT_DST0;
                else state <= S_BLT_SRC0;
            end
            S_BLT_SRC0: begin
                w_addr <= blt_srow[31:4]; w_we <= 1'b0; w_srt <= srt_mode; w_ret <= S_BLT_SRC0W;
                state <= S_W0;
            end
            S_BLT_SRC0W: begin
                sh_x <= {16'h0, srt_mode ? 16'h0 : mrd}; sh_k <= {1'b0, blt_srow[3:0]}; sh_mode <= SH_SHR;
                blt_swa <= blt_swa + 28'd1;
                state <= S_BLT_SRC0X;
            end
            S_BLT_SRC0X: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_sw <= sh_r;
                state <= S_BLT_DST0;
            end
            S_BLT_DST0: begin
                if (blt_req_src || transp || blt_drow[3:0] != 4'h0) begin
                    if (srt_mode && blt_mode_fill) begin
                        blt_dword <= 32'd0;
                        state <= S_BLT_PIX;
                    end else begin
                        w_addr <= blt_drow[31:4]; w_we <= 1'b0; w_srt <= srt_mode; w_ret <= S_BLT_DST0W;
                        state <= S_W0;
                    end
                end else begin
                    blt_dword <= 32'd0;
                    state <= S_BLT_PIX;
                end
            end
            S_BLT_DST0W: begin
                blt_dword <= {16'h0, srt_mode ? 16'h0 : mrd};
                state <= S_BLT_PIX;
            end
            S_BLT_PIX: begin
                // per pixel: fetch more source if needed (into position 16 - sbit of the aligned word)
                if (!blt_mode_fill && ({1'b0, blt_sbit} + {1'b0, blt_sbpp} > 6'd16)) begin
                    if (srt_mode) begin
                        blt_swa <= blt_swa + 28'd1;
                        state <= S_BLT_DSTN;
                    end else begin
                        w_addr <= blt_swa; w_we <= 1'b0; w_srt <= 1'b0; w_ret <= S_BLT_SRCNW;
                        state <= S_W0;
                    end
                end else state <= S_BLT_DSTN;
            end
            S_BLT_SRCNW: begin
                sh_x <= {16'h0, mrd}; sh_k <= 5'd16 - blt_sbit; sh_mode <= SH_SHL;
                blt_swa <= blt_swa + 28'd1;
                state <= S_BLT_SRCNX;
            end
            S_BLT_SRCNX: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_sw <= blt_sw | sh_r;
                state <= S_BLT_DSTN;
            end
            S_BLT_DSTN: begin
                if ((blt_req_src || transp) && ({1'b0, blt_dbit} + {1'b0, psz} > 6'd16)) begin
                    if (srt_mode) state <= S_BLT_PIX1;
                    else begin
                        w_addr <= blt_dwa + 28'd1; w_we <= 1'b0; w_srt <= 1'b0; w_ret <= S_BLT_DSTNW;
                        state <= S_W0;
                    end
                end else state <= S_BLT_PIX1;
            end
            S_BLT_DSTNW: begin
                blt_dword <= blt_dword | ({16'h0, mrd} << 16);
                state <= S_BLT_PIX1;
            end
            S_BLT_PIX1: begin
                // source pixel value, positioned at the destination bit
                if (blt_mode_fill) begin
                    blt_pix <= B_COLOR1 & blt_dmask;
                    state <= S_BLT_PIX2;
                end else if (blt_mode_b) begin
                    blt_pix <= (blt_sw[0] ? B_COLOR1 : B_COLOR0) & blt_dmask;
                    state <= S_BLT_PIX2;
                end else begin
                    sh_x <= blt_sw & {16'h0, pm}; sh_k <= blt_dbit; sh_mode <= SH_SHL;
                    blt_pix <= 32'd0;
                    state <= S_BLT_PIX2;
                end
            end
            S_BLT_PIX2: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                begin
                    logic [31:0] dw, pix, dmask_adv;
                    case (pxs)
                        3'd0: dmask_adv = blt_dmask << 1;
                        3'd1: dmask_adv = blt_dmask << 2;
                        3'd2: dmask_adv = blt_dmask << 4;
                        3'd3: dmask_adv = blt_dmask << 8;
                        default: dmask_adv = blt_dmask << 16;
                    endcase
                    dw  = blt_dword;
                    pix = (blt_mode_fill || blt_mode_b) ? blt_pix : sh_r;
                    pix = blt_op(rop, dw, blt_dmask, pix);
                    if (!transp || pix != 32'h0) dw = (dw & ~blt_dmask) | pix;
                    // advance source
                    if (!blt_mode_fill) begin
                        sb5 = blt_sbit + blt_sbpp;
                        blt_sbit <= (sb5 > 5'd16) ? sb5 - 5'd16 : sb5;
                        case (blt_sbpp_l)
                            3'd0: blt_sw <= blt_sw >> 1;
                            3'd1: blt_sw <= blt_sw >> 2;
                            3'd2: blt_sw <= blt_sw >> 4;
                            3'd3: blt_sw <= blt_sw >> 8;
                            default: blt_sw <= blt_sw >> 16;
                        endcase
                    end
                    // advance destination
                    db5 = blt_dbit + psz;
                    blt_x <= blt_x + 16'd1;
                    if (db5 > 5'd16) begin
                        blt_dword <= dw >> 16;
                        blt_dbit  <= db5 - 5'd16;
                        blt_dmask <= {16'h0, dmask_adv[31:16]};
                        w_addr <= blt_dwa; w_we <= 1'b1; w_srt <= srt_mode; w_wdata <= dw[15:0]; w_ret <= S_BLT_WRW;
                        state <= S_W0;
                    end else begin
                        blt_dword <= dw;
                        blt_dbit  <= db5;
                        blt_dmask <= dmask_adv;
                        state <= (blt_x + 16'd1 == blt_dx) ? S_BLT_FLUSH : S_BLT_PIX;
                    end
                end
            end
            // settle: compares blt_x one state after S_BLT_PIX2 incremented it
            S_BLT_WRW: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                blt_dwa <= blt_dwa + 28'd1;
                state <= (blt_x == blt_dx) ? S_BLT_FLUSH : S_BLT_PIX;
            end
            S_BLT_FLUSH: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                if (blt_dbit != 5'd0) begin
                    if (blt_dbit != 5'd16 && !(srt_mode && blt_mode_fill)) begin
                        w_addr <= blt_dwa; w_we <= 1'b0; w_srt <= srt_mode; w_ret <= S_BLT_FLUSHR;
                        state <= S_W0;
                    end else begin
                        w_addr <= blt_dwa; w_we <= 1'b1; w_srt <= srt_mode; w_wdata <= blt_dword[15:0]; w_ret <= S_BLT_NEXTROW;
                        state <= S_W0;
                    end
                end else state <= S_BLT_NEXTROW;
            end
            S_BLT_FLUSHR: begin
                t16 = 16'hffff << blt_dbit[3:0];
                w_we <= 1'b1; w_wdata <= (blt_dword[15:0] & ~t16) | ((srt_mode ? 16'h0 : mrd) & t16); w_ret <= S_BLT_NEXTROW;
                state <= S_W0;
            end
            S_BLT_NEXTROW: begin
                blt_y <= blt_y + 16'd1;
                if (blt_y + 16'd1 == blt_dy) state <= S_BLT_END;
                else begin
                    if (!blt_mode_fill && !blt_mode_b && blt_yrev) begin
                        blt_srow <= blt_srow - B_SPTCH;
                        blt_drow <= blt_drow - B_DPTCH;
                    end else begin
                        blt_srow <= blt_srow + B_SPTCH;
                        blt_drow <= blt_drow + B_DPTCH;
                    end
                    state <= S_BLT_ROW;
                end
            end
            S_BLT_END: begin
                st[SB_P] <= 1'b0;
                mul_a <= $signed({{17{B_DYDX[31]}}, B_DYDX[31:16]});          // sign-extended DYDX.y
                mul_b <= $signed({B_DPTCH[31], B_DPTCH});
                state <= S_BLT_END2;
            end
            S_BLT_END2: state <= S_BLT_END3;               // DYDX.y * DPTCH registers this cycle
            S_BLT_END3: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                // mul_res = DYDX.y * DPTCH. The SPTCH operand is handed over here
                // rather than in S_BLT_END2 so that mul_p is not reloaded with the
                // next product on this state's settle tick.
                if (blt_dst_lin) begin rfw_en = 1'b1; rfw_idx = 5'd28; rfw_val = B_DADDR + mul_res[31:0]; end
                else begin rfw_en = 1'b1; rfw_idx = 5'd28; rfw_val = {B_DADDR[31:16] + B_DYDX[31:16], B_DADDR[15:0]}; end
                mul_b <= $signed({B_SPTCH[31], B_SPTCH});
                state <= S_BLT_END3B;
            end
            // Same role S_BLT_END2 plays for S_BLT_END3: mul_p takes DYDX.y *
            // SPTCH on this clock, so S_BLT_END4's acting tick is two clocks
            // after the product last changed -- which is what lets the SDC give
            // the DSP output two clocks to the register file.
            S_BLT_END3B: state <= S_BLT_END4;
            // Settle tick: S_BLT_END3 wrote DADDR on the previous clock. Without
            // it these two register-file writes are one clock apart and the
            // rf -> rf multicycle of 2 would not hold. mul_b was set in
            // S_BLT_END2, so mul_res (DYDX.y * SPTCH) is stable across both.
            S_BLT_END4: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                if (!blt_mode_fill) begin
                    if (blt_src_lin) begin rfw_en = 1'b1; rfw_idx = 5'd30; rfw_val = B_SADDR + mul_res[31:0]; end
                    else begin rfw_en = 1'b1; rfw_idx = 5'd30; rfw_val = {B_SADDR[31:16] + B_DYDX[31:16], B_SADDR[15:0]}; end
                end
                state <= S_CHECK;
            end

            // ---------------- execute ----------------
            // One settle clock before acting: every capture below (operand
            // registers, rfw writes, next-state) reads the register-file ports
            // and the opcode-selected action mux, cones that need two clocks.
            S_EXEC: if (!mph) mph <= 1'b1; else begin
                mph <= 1'b0;
                state <= S_CHECK;     // default: single-step instruction
                // defaults for the shared units
                alu_a <= rdv; alu_b <= rsv; alu_op <= A_ADD; alu_cin <= 1'b0;
                wb_sel <= WB_RD; wb_idx <= ri_d; wb_fl <= FL_NONE; wb_next <= S_CHECK;
                sh_x <= rdv; sh_k <= ir[9:5]; sh_mode <= SH_SHL;
                case (opc)
                OP_ILL: begin
                    int_vec <= 32'hfffffc20; int_push <= 1'b1; state <= S_INT0;
                end
                OP_UNIMPL, OP_NOP, OP_EMU: begin end
                OP_REV: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = 32'h0008; end
                OP_EXGPC: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = pc; pc <= rdv & 32'hfffffff0; end
                OP_GETPC: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = pc; end
                OP_JUMP:  pc <= rdv & 32'hfffffff0;
                OP_GETST: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = st; end
                OP_PUTST: st <= rdv;
                OP_POPST: begin
                    if (istep == 4'd0) begin
                        fr_addr <= rf[15]; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_EXEC;
                        alu_a <= rf[15]; alu_b <= 32'h20; wb_sel <= WB_SP; wb_next <= S_FR0;
                        istep <= 4'd1; state <= S_ALU;
                    end else st <= fr_val;
                end
                OP_PUSHST: begin
                    alu_a <= rf[15]; alu_b <= 32'h20; alu_op <= A_SUB;
                    fw_size <= 6'd32; fw_data <= st; fw_ret <= S_CHECK;
                    wb_sel <= WB_PUSH; wb_next <= S_FW0; state <= S_ALU;
                end
                OP_CLRC: st[SB_C] <= 1'b0;
                OP_SETC: st[SB_C] <= 1'b1;
                OP_DINT: st[SB_IE] <= 1'b0;
                OP_EINT: st[SB_IE] <= 1'b1;
                OP_ABS: begin
                    alu_a <= 32'd0; alu_b <= rdv; alu_op <= A_SUB;
                    wb_sel <= WB_RD_IFPOS; wb_fl <= FL_NZV; state <= S_ALU;
                end
                OP_NEG: begin
                    alu_a <= 32'd0; alu_b <= rdv; alu_op <= A_SUB;
                    wb_fl <= FL_ARITH; state <= S_ALU;
                end
                OP_NEGB: begin
                    if (istep == 4'd0) begin
                        alu_a <= rdv; alu_b <= 32'd0; alu_cin <= st[SB_C];        // t = rd + C
                        wb_sel <= WB_T; wb_next <= S_EXEC; istep <= 4'd1; state <= S_ALU;
                    end else begin
                        alu_a <= 32'd0; alu_b <= T; alu_op <= A_SUB;
                        wb_fl <= FL_ARITH; state <= S_ALU;
                    end
                end
                OP_NOT: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = ~rdv; st[SB_Z] <= (~rdv == 32'd0); end
                OP_SEXT: begin
                    t32 = rdv & wmask(fsz);
                    if (fsz != 6'd32 && rdv[fsz[4:0] - 5'd1]) t32 = t32 | ~wmask(fsz);
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = t32;
                    st[SB_N] <= t32[31]; st[SB_Z] <= (t32 == 32'd0);
                end
                OP_ZEXT: begin
                    t32 = rdv & wmask(fsz);
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = t32;
                    st[SB_Z] <= (t32 == 32'd0);
                end
                OP_SETF: begin
                    if (fsel) st[11:6] <= ir[5:0]; else st[5:0] <= ir[5:0];
                end
                OP_EXGF: begin
                    rfw_en = 1'b1; rfw_idx = ri_d;
                    if (fsel) begin st[11:6] <= rdv[5:0]; rfw_val = {26'd0, st[11:6]}; end
                    else begin st[5:0] <= rdv[5:0]; rfw_val = {26'd0, st[5:0]}; end
                end
                // ---- arithmetic through the ALU
                OP_ADD:    begin wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_ADDC:   begin alu_cin <= st[SB_C]; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_ADDI_W: begin alu_b <= sxt16(imm[15:0]); wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_ADDI_L: begin alu_b <= imm; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_ADDK:   begin alu_b <= k32; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_SUB:    begin alu_op <= A_SUB; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_SUBB:   begin alu_op <= A_SUB; alu_cin <= st[SB_C]; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_SUBI_W: begin alu_op <= A_SUB; alu_b <= ~sxt16(imm[15:0]); wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_SUBI_L: begin alu_op <= A_SUB; alu_b <= ~imm; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_SUBK:   begin alu_op <= A_SUB; alu_b <= k32; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_CMP:    begin alu_op <= A_SUB; wb_sel <= WB_NONE; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_CMPI_W: begin alu_op <= A_SUB; alu_b <= sxt16(~imm[15:0]); wb_sel <= WB_NONE; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_CMPI_L: begin alu_op <= A_SUB; alu_b <= ~imm; wb_sel <= WB_NONE; wb_fl <= FL_ARITH; state <= S_ALU; end
                OP_AND:  begin alu_op <= A_AND;  wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_ANDN: begin alu_op <= A_ANDN; wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_OR:   begin alu_op <= A_OR;   wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_XOR:  begin alu_op <= A_XOR;  wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_ANDI: begin alu_op <= A_ANDN; alu_b <= imm; wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_ORI:  begin alu_op <= A_OR;   alu_b <= imm; wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_XORI: begin alu_op <= A_XOR;  alu_b <= imm; wb_fl <= FL_LOGIC; state <= S_ALU; end
                OP_MOVK: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = k32; end
                OP_MOVI_W: begin alu_op <= A_PASSB; alu_b <= sxt16(imm[15:0]); wb_fl <= FL_MOVE; state <= S_ALU; end
                OP_MOVI_L: begin alu_op <= A_PASSB; alu_b <= imm; wb_fl <= FL_MOVE; state <= S_ALU; end
                OP_MOVE_RR: begin alu_op <= A_PASSB; wb_fl <= FL_MOVE; state <= S_ALU; end
                OP_MOVE_RRX: begin alu_op <= A_PASSB; wb_idx <= ridx(~rbit, ir[3:0]); wb_fl <= FL_MOVE; state <= S_ALU; end
                OP_BTST_K: st[SB_Z] <= ~rdv[5'd31 - ir[9:5]];
                OP_BTST_R: st[SB_Z] <= ~rdv[rsv[4:0]];
                // ---- shifts through the shifter
                OP_SLL_K: begin sh_mode <= SH_SHL; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_SLL_R: begin sh_mode <= SH_SHL; sh_k <= rsv[4:0]; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_SLA_K: begin sh_mode <= SH_SHL; wb_fl <= FL_SLA; state <= S_SH; end
                OP_SLA_R: begin sh_mode <= SH_SHL; sh_k <= rsv[4:0]; wb_fl <= FL_SLA; state <= S_SH; end
                OP_SRA_K: begin sh_mode <= SH_SAR; sh_k <= 5'd0 - ir[9:5]; wb_fl <= FL_SHNZ; state <= S_SH; end
                OP_SRA_R: begin sh_mode <= SH_SAR; sh_k <= 5'd0 - rsv[4:0]; wb_fl <= FL_SHNZ; state <= S_SH; end
                OP_SRL_K: begin sh_mode <= SH_SHR; sh_k <= 5'd0 - ir[9:5]; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_SRL_R: begin sh_mode <= SH_SHR; sh_k <= 5'd0 - rsv[4:0]; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_RL_K:  begin sh_mode <= SH_ROL; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_RL_R:  begin sh_mode <= SH_ROL; sh_k <= rsv[4:0]; wb_fl <= FL_SHZ; state <= S_SH; end
                OP_LMO: begin
                    // Two S_EXEC passes. The first captures Rs into the shifter
                    // operand register -- that cone is the 32:1 read mux alone;
                    // the second counts from sh_x, which the SDC gives two
                    // clocks (sh_x written on an S_EXEC acting tick, read on the
                    // next one, one mph settle apart). Doing both in one tick
                    // put the read mux and the leading-zero count in series in a
                    // single rf -> rf window, which no honest multicycle covers.
                    if (istep == 4'd0) begin
                        sh_x <= rsv;
                        st[SB_Z] <= (rsv == 32'd0);
                        istep <= 4'd1; state <= S_EXEC;
                    end else begin
                        rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {26'd0, lzc(sh_x)};
                    end
                end
                OP_MPYS, OP_MPYU: begin
                    t32 = rsv & wmask(fsize(st[10:6]));
                    if (opc == OP_MPYS && st[10:6] != 5'd0 && rsv[st[10:6] - 5'd1]) t32 = t32 | ~wmask(fsize(st[10:6]));
                    mul_a <= $signed({(opc == OP_MPYS) ? t32[31] : 1'b0, t32});
                    mul_b <= $signed({(opc == OP_MPYS) ? rdv[31] : 1'b0, rdv});
                    state <= S_MUL1;
                end
                OP_DIVS, OP_DIVU, OP_MODS, OP_MODU: begin
                    if (istep == 4'd1) begin
                        // second register write after a 64/32 divide: remainder into rd+1
                        rfw_en = 1'b1; rfw_idx = ri_d + 5'd1; rfw_val = T;
                    end else if (istep == 4'd2) begin
                        // rgv = rd+1 is valid now
                        if ((opc == OP_DIVS || opc == OP_DIVU) && ir[0] == 1'b0) div_in <= {rdv, rgv};
                        else if (opc == OP_DIVS || opc == OP_MODS) div_in <= {{32{rdv[31]}}, rdv};
                        else div_in <= {32'd0, rdv};
                        state <= S_DIV0;
                    end else begin
                        div_signed <= (opc == OP_DIVS || opc == OP_MODS);
                        div_is_mod <= (opc == OP_MODS || opc == OP_MODU);
                        st[SB_Z] <= 1'b0; st[SB_V] <= 1'b0;
                        if (opc == OP_DIVS || opc == OP_MODS) st[SB_N] <= 1'b0;
                        rg_idx <= ri_d + 5'd1;
                        if (rsv == 32'd0) begin
                            st[SB_V] <= 1'b1;
                        end else begin
                            div_den   <= ((opc == OP_DIVS || opc == OP_MODS) && rsv[31]) ? (32'd0 - rsv) : rsv;
                            div_neg_q <= (opc == OP_DIVS || opc == OP_MODS) && (rdv[31] ^ rsv[31]);
                            div_neg_r <= (opc == OP_DIVS || opc == OP_MODS) && rdv[31];
                            istep <= 4'd2; state <= S_EXEC;
                        end
                    end
                end
                // ---- XY
                OP_ADD_XY: begin
                    t16 = rdv[15:0] + rsv[15:0];
                    t32[15:0] = rdv[31:16] + rsv[31:16];
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {t32[15:0], t16};
                    st[SB_N] <= (t16 == 16'd0); st[SB_C] <= t32[15]; st[SB_Z] <= (t32[15:0] == 16'd0); st[SB_V] <= t16[15];
                end
                OP_SUB_XY: begin
                    st[SB_N] <= (rsv[15:0] == rdv[15:0]);
                    st[SB_C] <= ($signed(rsv[31:16]) > $signed(rdv[31:16]));
                    st[SB_Z] <= (rsv[31:16] == rdv[31:16]);
                    st[SB_V] <= ($signed(rsv[15:0]) > $signed(rdv[15:0]));
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {rdv[31:16] - rsv[31:16], rdv[15:0] - rsv[15:0]};
                end
                OP_CMP_XY: begin
                    t16 = rdv[15:0] - rsv[15:0];
                    t32[15:0] = rdv[31:16] - rsv[31:16];
                    st[SB_N] <= (t16 == 16'd0); st[SB_V] <= t16[15];
                    st[SB_Z] <= (t32[15:0] == 16'd0); st[SB_C] <= t32[15];
                end
                OP_CPW: begin
                    // window unit is fed with rsv (see win_xy mux below)
                    t32 = {23'd0, win_ygt, win_ylt, win_xgt, win_xlt, 5'd0};
                    rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = t32;
                    st[SB_V] <= win_out;
                end
                OP_CVXYL: begin
                    xy_in <= rsv; xy_sh <= dp_sh; xy_wb <= WB_RD; xy_ret <= S_CHECK; state <= S_XY0;
                end
                OP_MOVX: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {rdv[31:16], rsv[15:0]}; end
                OP_MOVY: begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {rsv[31:16], rdv[15:0]}; end
                // ---- jumps and calls
                OP_JR: begin
                    tb = cond_true(ir[11:8], st);
                    alu_a <= pc; wb_sel <= WB_PC;
                    if (ir[7:0] == 8'h00) begin
                        alu_b <= sxt16(imm[15:0]) << 4;
                        if (tb) state <= S_ALU;
                    end else if (ir[7:0] == 8'h80) begin
                        if (tb) pc <= imm & 32'hfffffff0;
                    end else begin
                        alu_b <= sxt8(ir[7:0]) << 4;
                        if (tb) state <= S_ALU;
                    end
                end
                OP_DSJS: begin
                    if (istep == 4'd0) begin
                        alu_b <= 32'd1; alu_op <= A_SUB; wb_next <= S_EXEC; istep <= 4'd1; state <= S_ALU;
                    end else begin
                        // alu_r still holds rd - 1 (operands unchanged)
                        alu_a <= pc; alu_b <= {27'd0, ir[9:5]} << 4; alu_op <= ir[10] ? A_SUB : A_ADD;
                        wb_sel <= WB_PC;
                        if (!alu_z) state <= S_ALU;
                    end
                end
                OP_DSJ, OP_DSJEQ, OP_DSJNE: begin
                    if (istep == 4'd0) begin
                        if (opc == OP_DSJ || (opc == OP_DSJEQ && st[SB_Z]) || (opc == OP_DSJNE && !st[SB_Z])) begin
                            alu_b <= 32'd1; alu_op <= A_SUB; wb_next <= S_EXEC; istep <= 4'd1; state <= S_ALU;
                        end
                    end else begin
                        alu_a <= pc; alu_b <= sxt16(imm[15:0]) << 4; wb_sel <= WB_PC;
                        if (!alu_z) state <= S_ALU;
                    end
                end
                OP_CALL, OP_CALLR, OP_CALLA: begin
                    alu_a <= rf[15]; alu_b <= 32'h20; alu_op <= A_SUB;
                    fw_size <= 6'd32; fw_data <= pc; fw_ret <= S_CHECK;
                    wb_sel <= WB_PUSH; wb_next <= S_FW0; state <= S_ALU;
                    case (opc)
                        OP_CALL:  pc <= rdv & 32'hfffffff0;
                        OP_CALLA: pc <= imm & 32'hfffffff0;
                        default:  pc <= pc + (sxt16(imm[15:0]) << 4);
                    endcase
                end
                OP_RETS: begin
                    if (istep == 4'd0) begin
                        fr_addr <= rf[15]; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_EXEC;
                        alu_a <= rf[15]; alu_b <= 32'h20 + ({27'd0, ir[4:0]} << 4); wb_sel <= WB_SP; wb_next <= S_FR0;
                        istep <= 4'd1; state <= S_ALU;
                    end else pc <= fr_val & 32'hfffffff0;
                end
                OP_RETI: begin
                    case (istep)
                        4'd0: begin
                            fr_addr <= rf[15]; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_EXEC;
                            alu_a <= rf[15]; alu_b <= 32'h20; wb_sel <= WB_SP; wb_next <= S_FR0;
                            istep <= 4'd1; state <= S_ALU;
                        end
                        4'd1: begin
                            imm2 <= fr_val;                        // saved st (T is clobbered by the field read)
                            fr_addr <= rf[15]; fr_ret <= S_EXEC;
                            alu_a <= rf[15]; alu_b <= 32'h20; wb_sel <= WB_SP; wb_next <= S_FR0;
                            istep <= 4'd2; state <= S_ALU;
                        end
                        default: begin
                            pc <= fr_val & 32'hfffffff0;
                            st <= imm2;
                        end
                    endcase
                end
                OP_TRAP: begin
                    int_vec  <= 32'hffffffe0 - ({27'd0, ir[4:0]} << 5);
                    int_push <= (ir[4:0] != 5'd0);
                    state    <= S_INT0;
                end
                OP_MMTM: begin
                    // istep counts register i = 0..15 (bit 15-i of the list); rg_idx read one cycle ahead
                    if (imm[15 - istep]) begin
                        alu_b <= 32'h20; alu_op <= A_SUB;
                        rg_idx <= ridx(rbit, istep);
                        fw_size <= 6'd32; fw_ret <= (istep == 4'd15) ? S_CHECK : S_EXEC;
                        wb_sel <= WB_PUSHR; wb_next <= S_FW0;
                        istep <= istep + 4'd1; state <= S_ALU;
                    end else begin
                        istep <= istep + 4'd1;
                        state <= (istep == 4'd15) ? S_CHECK : S_EXEC;
                    end
                end
                OP_MMFM: begin
                    if (imm2[0]) begin
                        rfw_en = 1'b1; rfw_idx = ridx(rbit, 4'd15 - (istep - 4'd1)); rfw_val = fr_val;
                        imm2[0] <= 1'b0;
                        state <= (istep == 4'd0) ? S_CHECK : S_EXEC;
                    end else if (imm[15 - istep]) begin
                        fr_addr <= rdv; fr_size <= 6'd32; fr_sext <= 1'b0; fr_ret <= S_EXEC;
                        alu_b <= 32'h20; wb_next <= S_FR0;
                        imm2[0] <= 1'b1;
                        istep <= istep + 4'd1; state <= S_ALU;
                    end else begin
                        istep <= istep + 4'd1;
                        state <= (istep == 4'd15) ? S_CHECK : S_EXEC;
                    end
                end
                // ---- field / byte moves
                OP_MOVE_RN, OP_MOVB_RN: begin
                    fw_addr <= rdv; fw_size <= (opc == OP_MOVB_RN) ? 6'd8 : fsz; fw_data <= rsv; fw_ret <= S_CHECK; state <= S_FW0;
                end
                OP_MOVE_R_NI: begin
                    fw_addr <= rdv; fw_size <= fsz; fw_data <= rsv; fw_ret <= S_CHECK;
                    alu_b <= fincv; wb_next <= S_FW0; state <= S_ALU;
                end
                OP_MOVE_R_DN: begin
                    if (istep == 4'd0) begin
                        alu_b <= fincv; alu_op <= A_SUB; wb_sel <= WB_RD_FWADDR; wb_next <= S_EXEC;
                        istep <= 4'd1; state <= S_ALU;
                    end else begin
                        fw_size <= fsz; fw_data <= rsv; fw_ret <= S_CHECK; state <= S_FW0;
                    end
                end
                OP_MOVE_R_NO, OP_MOVB_R_NO: begin
                    alu_b <= sxt16(imm[15:0]); fw_size <= (opc == OP_MOVB_R_NO) ? 6'd8 : fsz; fw_data <= rsv; fw_ret <= S_CHECK;
                    wb_sel <= WB_FWADDR; wb_next <= S_FW0; state <= S_ALU;
                end
                OP_MOVE_RA, OP_MOVB_RA: begin
                    fw_addr <= imm; fw_size <= (opc == OP_MOVB_RA) ? 6'd8 : fsz; fw_data <= rdv; fw_ret <= S_CHECK; state <= S_FW0;
                end
                OP_MOVE_NR, OP_MOVE_NI_R, OP_MOVE_DN_R, OP_MOVE_NO_R, OP_MOVE_AR, OP_MOVB_NR, OP_MOVB_NO_R, OP_MOVB_AR: begin
                    tb = (opc == OP_MOVB_NR || opc == OP_MOVB_NO_R || opc == OP_MOVB_AR);
                    if (istep == 4'd0) begin
                        fr_size <= tb ? 6'd8 : fsz; fr_sext <= tb ? 1'b1 : fext; fr_ret <= S_EXEC; istep <= 4'd1;
                        case (opc)
                            OP_MOVE_NR, OP_MOVE_NI_R, OP_MOVB_NR: begin fr_addr <= rsv; state <= S_FR0; end
                            OP_MOVE_DN_R: begin
                                alu_a <= rsv; alu_b <= fincv; alu_op <= A_SUB; wb_sel <= WB_RD_FRADDR; wb_idx <= ri_s; wb_next <= S_FR0; state <= S_ALU;
                            end
                            OP_MOVE_NO_R, OP_MOVB_NO_R: begin
                                alu_a <= rsv; alu_b <= sxt16(imm[15:0]); wb_sel <= WB_FRADDR; wb_next <= S_FR0; state <= S_ALU;
                            end
                            default: begin fr_addr <= imm; state <= S_FR0; end
                        endcase
                    end else if (istep == 4'd1 && opc == OP_MOVE_NI_R) begin
                        rfw_en = 1'b1; rfw_idx = ri_s; rfw_val = rsv + fincv;
                        istep <= 4'd2; state <= S_EXEC;
                    end else begin
                        rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = fr_val;
                        st[SB_N] <= fr_val[31]; st[SB_Z] <= (fr_val == 32'd0); st[SB_V] <= 1'b0;
                    end
                end
                OP_MOVE_NN, OP_MOVE_NI_NI, OP_MOVE_DN_DN, OP_MOVE_NO_NI, OP_MOVE_NO_NO, OP_MOVE_A_NI, OP_MOVE_AA,
                OP_MOVB_NN, OP_MOVB_NO_NO, OP_MOVB_AA: begin
                    tb = (opc == OP_MOVB_NN || opc == OP_MOVB_NO_NO || opc == OP_MOVB_AA);
                    if (istep == 4'd0) begin
                        fr_size <= tb ? 6'd8 : fsz; fr_sext <= 1'b0; fr_ret <= S_EXEC; istep <= 4'd1;
                        case (opc)
                            OP_MOVE_NN, OP_MOVE_NI_NI, OP_MOVB_NN: begin fr_addr <= rsv; state <= S_FR0; end
                            OP_MOVE_DN_DN: begin
                                alu_a <= rsv; alu_b <= fincv; alu_op <= A_SUB; wb_sel <= WB_RD_FRADDR; wb_idx <= ri_s; wb_next <= S_FR0; state <= S_ALU;
                            end
                            OP_MOVE_NO_NI, OP_MOVE_NO_NO, OP_MOVB_NO_NO: begin
                                alu_a <= rsv; alu_b <= sxt16(imm[15:0]); wb_sel <= WB_FRADDR; wb_next <= S_FR0; state <= S_ALU;
                            end
                            default: begin fr_addr <= imm; state <= S_FR0; end     // A_NI, AA: first long
                        endcase
                    end else if (istep == 4'd1 && opc == OP_MOVE_NI_NI) begin
                        // rs += inc first (if rs == rd the write address is the updated value)
                        rfw_en = 1'b1; rfw_idx = ri_s; rfw_val = rsv + fincv;
                        istep <= 4'd2; state <= S_EXEC;
                    end else begin
                        fw_size <= tb ? 6'd8 : fsz; fw_data <= fr_val; fw_ret <= S_CHECK; state <= S_FW0;
                        case (opc)
                            OP_MOVE_NN, OP_MOVB_NN: fw_addr <= rdv;
                            OP_MOVE_NI_NI, OP_MOVE_NO_NI, OP_MOVE_A_NI: begin
                                fw_addr <= rdv; alu_b <= fincv; wb_next <= S_FW0; state <= S_ALU;
                            end
                            OP_MOVE_DN_DN: begin
                                alu_b <= fincv; alu_op <= A_SUB; wb_sel <= WB_RD_FWADDR; wb_next <= S_FW0; state <= S_ALU;
                            end
                            OP_MOVE_NO_NO, OP_MOVB_NO_NO: begin
                                alu_b <= sxt16(imm2[15:0]); wb_sel <= WB_FWADDR; wb_next <= S_FW0; state <= S_ALU;
                            end
                            default: fw_addr <= imm2;                 // AA: second long
                        endcase
                    end
                end
                // ---- pixel transfers
                OP_PIXT_RI: begin
                    pw_addr <= rdv; pw_data <= rsv[15:0]; pw_ret <= S_CHECK; state <= S_PW0;
                end
                OP_PIXT_RIXY, OP_DRAV: begin
                    // window unit is fed with rdv (win_xy mux)
                    tb = 1'b0;   // skip
                    if (wchk != 2'd0) begin
                        st[SB_V] <= win_out;
                        if (win_out || wchk == 2'd1) tb = 1'b1;
                    end
                    if (opc == OP_DRAV) begin rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {rdv[31:16] + rsv[31:16], rdv[15:0] + rsv[15:0]}; end
                    if (!tb) begin
                        xy_in <= rdv; xy_sh <= dp_sh; xy_wb <= WB_PWADDR; xy_ret <= S_PW0;
                        pw_data <= (opc == OP_DRAV) ? B_COLOR1[15:0] : rsv[15:0];
                        pw_ret <= S_CHECK; state <= S_XY0;
                    end
                end
                OP_PIXT_IR, OP_PIXT_IXYR: begin
                    if (istep == 4'd0) begin
                        pr_ret <= S_EXEC; istep <= 4'd1;
                        if (opc == OP_PIXT_IR) begin pr_addr <= rsv; state <= S_PR0; end
                        else begin xy_in <= rsv; xy_sh <= sp_sh; xy_wb <= WB_PRADDR; xy_ret <= S_PR0; state <= S_XY0; end
                    end else begin
                        rfw_en = 1'b1; rfw_idx = ri_d; rfw_val = {16'd0, pr_val};
                        st[SB_V] <= (pr_val != 16'd0);
                    end
                end
                OP_PIXT_II, OP_PIXT_IXYIXY: begin
                    if (istep == 4'd0) begin
                        tb = 1'b0;
                        if (opc == OP_PIXT_IXYIXY && wchk != 2'd0) begin
                            st[SB_V] <= win_out;
                            if (win_out || wchk == 2'd1) tb = 1'b1;
                        end
                        if (!tb) begin
                            pr_ret <= S_EXEC; istep <= 4'd1;
                            if (opc == OP_PIXT_II) begin pr_addr <= rsv; state <= S_PR0; end
                            else begin xy_in <= rsv; xy_sh <= sp_sh; xy_wb <= WB_PRADDR; xy_ret <= S_PR0; state <= S_XY0; end
                        end
                    end else begin
                        pw_data <= pr_val; pw_ret <= S_CHECK;
                        if (opc == OP_PIXT_II) begin pw_addr <= rdv; state <= S_PW0; end
                        else begin xy_in <= rdv; xy_sh <= dp_sh; xy_wb <= WB_PWADDR; xy_ret <= S_PW0; state <= S_XY0; end
                    end
                end
                OP_LINE: begin
                    // one pixel per execution, like the hardware (and MAME); window unit is fed with DADDR
                    if (istep == 4'd0) begin
                        if (!st[SB_P]) begin
                            st[SB_P] <= 1'b1;
                            rfw_en = 1'b1; rfw_idx = 5'd16; rfw_val = ir[7] ? 32'd1 : 32'd0;    // TEMP
                            istep <= 4'd1; state <= S_EXEC;
                        end else if ($signed(B_COUNT) > 0) begin
                            istep <= 4'd2; state <= S_EXEC;
                        end else begin
                            st[SB_P] <= 1'b0;
                        end
                    end else if (istep == 4'd1) begin
                        if ($signed(B_COUNT) > 0) begin istep <= 4'd2; state <= S_EXEC; end
                        else st[SB_P] <= 1'b0;
                    end else if (istep == 4'd2) begin
                        rfw_en = 1'b1; rfw_idx = 5'd20; rfw_val = B_COUNT - 32'd1;
                        istep <= 4'd3;
                        if (wchk != 2'd3 || !win_out) begin
                            xy_in <= B_DADDR; xy_sh <= dp_sh; xy_wb <= WB_PWADDR; xy_ret <= S_PW0;
                            pw_data <= B_COLOR1[15:0]; pw_ret <= S_EXEC; state <= S_XY0;
                        end else state <= S_EXEC;
                    end else if (istep == 4'd3) begin
                        // DDA step: SADDR
                        istep <= 4'd4; state <= S_EXEC;
                        if ($signed(B_SADDR) >= $signed(B_TEMP)) begin
                            rfw_en = 1'b1; rfw_idx = 5'd30; rfw_val = B_SADDR + (sxt16(B_DYDX[31:16]) << 1) - (sxt16(B_DYDX[15:0]) << 1);
                            T <= B_INC1;
                        end else begin
                            rfw_en = 1'b1; rfw_idx = 5'd30; rfw_val = B_SADDR + (sxt16(B_DYDX[31:16]) << 1);
                            T <= B_INC2;
                        end
                    end else begin
                        rfw_en = 1'b1; rfw_idx = 5'd28; rfw_val = {B_DADDR[31:16] + T[31:16], B_DADDR[15:0] + T[15:0]};
                        pc <= pc - 32'h10;        // re-execute (interrupts can be taken in between)
                        state <= S_CHECK;
                    end
                end
                // ---- blits
                OP_FILL_L, OP_FILL_XY, OP_PIXBLT_BL, OP_PIXBLT_BXY,
                OP_PIXBLT_LL, OP_PIXBLT_LXY, OP_PIXBLT_XYL, OP_PIXBLT_XYXY: begin
                    if (istep == 4'd1) begin
                        // window mode 1: second write (DYDX), then WV interrupt request
                        rfw_en = 1'b1; rfw_idx = 5'd23; rfw_val = {blt_dy, blt_dx};
                        io[R_INTPEND] <= io[R_INTPEND] | INT_WV;
                    end else if (st[SB_P]) begin
                        st[SB_P] <= 1'b0;
                    end else begin
                        blt_mode_fill <= (opc == OP_FILL_L || opc == OP_FILL_XY);
                        blt_mode_b    <= (opc == OP_PIXBLT_BL || opc == OP_PIXBLT_BXY);
                        blt_dst_lin   <= (opc == OP_FILL_L || opc == OP_PIXBLT_BL || opc == OP_PIXBLT_LL || opc == OP_PIXBLT_XYL);
                        blt_src_lin   <= (opc == OP_PIXBLT_LL || opc == OP_PIXBLT_LXY || opc == OP_PIXBLT_BL || opc == OP_PIXBLT_BXY);
                        blt_yrev      <= io[R_CONTROL][9];
                        blt_sbpp      <= (opc == OP_PIXBLT_BL || opc == OP_PIXBLT_BXY) ? 5'd1 : psz;
                        blt_sbpp_l    <= (opc == OP_PIXBLT_BL || opc == OP_PIXBLT_BXY) ? 3'd0 : pxs;
                        blt_req_src   <= (rop != 5'd0);
                        blt_dx <= B_DYDX[15:0];
                        blt_dy <= B_DYDX[31:16];
                        blt_dstxy <= B_DADDR;
                        blt_saddr <= B_SADDR;
                        if (opc == OP_PIXBLT_XYL || opc == OP_PIXBLT_XYXY) begin
                            xy_in <= B_SADDR; xy_sh <= sp_sh; xy_wb <= WB_XYIN; xy_ret <= S_BLT0;
                            istep <= 4'd3; state <= S_XY0;
                        end else state <= S_BLT0;
                    end
                end
                default: begin end
                endcase
            end
            default: state <= S_CHECK;
            endcase

        end

        // single register-file write port
        if (rfw_en) rf[rfw_idx] <= rfw_val;
    end

    // window unit operand: CPW uses Rs, PIXT/DRAV use Rd, LINE uses DADDR
    always_comb begin
        if (opc == OP_LINE) win_xy = B_DADDR;
        else if (opc == OP_CPW) win_xy = rsv;
        else win_xy = rdv;
    end

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    assign int_out    = io[R_HSTCTLL][7];
    assign hcount     = hc;
    assign vcount     = vc;
    assign hblank     = (hc < io[R_HEBLNK]) || (hc >= io[R_HSBLNK]);
    assign vblank     = (vc < io[R_VEBLNK]) || (vc >= io[R_VSBLNK]);
    assign r_hesync   = io[R_HESYNC];
    assign r_heblnk   = io[R_HEBLNK];
    assign r_hsblnk   = io[R_HSBLNK];
    assign r_htotal   = io[R_HTOTAL];
    assign r_vesync   = io[R_VESYNC];
    assign r_veblnk   = io[R_VEBLNK];
    assign r_vsblnk   = io[R_VSBLNK];
    assign r_vtotal   = io[R_VTOTAL];
    assign r_dpyctl   = io[R_DPYCTL];
    assign r_dpystrt  = io[R_DPYSTRT];
    assign r_dpytap   = io[R_DPYTAP];
    assign r_dpyadr   = io[R_DPYADR];
    assign dbg_pc     = pc;
    assign dbg_halted = halted;
    assign dbg_idle   = (state == S_CHECK) && !host_pend && !reset_deferred;

    logic unused_ok;
    assign unused_ok = &{1'b0, mul_p[65:64], pw_new};
endmodule
