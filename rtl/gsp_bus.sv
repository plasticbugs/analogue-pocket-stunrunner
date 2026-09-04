//------------------------------------------------------------------------------
// GSP memory-side glue (docs/hardware.md sections 4.2, 4.4-4.6): everything
// the TMS34010 core reaches through its mem_* port that is not its own I/O
// register block.
//
//   ff800000-ffffffff  VRAM in SDRAM (512 KB, mirrored)             -> SDRAM client
//   02000000-020fffff  2bpp expander: one 16-bit write = 8 masked pixels (4 words)
//   f4000000-f40000ff  control_lo latch (word 0 = expander colour)
//   f4800000-f48000ff  control_hi latch (value in address bit 3)
//   f5000000-f5000fff  palette lo (red D15:8, green D7:0), bank-resolved
//   f5800000-f5800fff  palette hi (blue D7:0)
//   anything else      reads 0xffff, writes ignored
//
// Shift-register transfers (mem_srt): a read cycle latches the source row
// address; a write cycle, when the control_hi enable is set, copies the
// source row's CURRENT contents (256 words, or 1024 in the expander region)
// to the destination row -- MAME keeps a pointer to the source row and
// memmoves it at the write (harddriv_v.cpp), and the game relies on that: it
// modifies the source row between the transfer-in and the transfer-out. A
// snapshot taken at the read (tried first) left stale pixels along polygon
// seams. The copy goes through a row buffer over the SDRAM burst port, in
// 32-word pieces (one READ/WRITE per 2 clocks in the open row) so the display
// line fetch never waits more than a piece: ~1,300 clocks a row against
// ~5,000 word by word through the random port, which froze the GSP inside a
// full-screen FILL for most of a frame (docs/verification.md, "the dead frame").
//------------------------------------------------------------------------------
`default_nettype none

module gsp_bus (
    input  logic        clk,
    input  logic        reset,

    // TMS34010 memory port
    input  logic [31:4] mem_addr,
    input  logic        mem_req, mem_we,
    input  logic [15:0] mem_wdata,
    output logic [15:0] mem_rdata,
    output logic        mem_ack,
    input  logic        mem_srt,

    // SDRAM client
    output logic [24:1] sd_addr,
    output logic        sd_req, sd_we,
    output logic [15:0] sd_wdata,
    output logic  [1:0] sd_be,
    input  logic [15:0] sd_rdata,
    input  logic        sd_ack,

    // SDRAM burst client (shift-register rows, blit rows), arbitrated in stunrun_core
    output logic [24:1] sb_addr,
    output logic  [9:0] sb_len,
    output logic        sb_req, sb_we,
    output logic [15:0] sb_wdata,
    output logic  [1:0] sb_be,
    input  logic        sb_wr,
    input  logic  [9:0] sb_idx,
    input  logic [15:0] sb_data,
    input  logic        sb_done,
    input  logic  [9:0] sb_widx,

    // row fast path from the GSP core (see tms34010.sv): copy or fill one row
    // of 8-bpp pixels; rc_req holds until rc_ack pulses
    input  logic        rc_req, rc_fill,
    input  logic [31:0] rc_src, rc_dst,
    input  logic [15:0] rc_len, rc_color,
    input  logic        rc_transp,
    output logic        rc_ack,

    // to the scan-out block
    output logic  [2:0] finescroll,
    output logic  [1:0] palbank,
    output logic        pal_we_rg, pal_we_b,
    output logic  [9:0] pal_waddr,
    output logic [15:0] pal_wdata,
    output logic        vram_copied       // pulse: a shift-register copy changed VRAM (GSP flushes its cache)
);
    localparam [24:1] VRAM_BASE = 24'h100000;

    // region decode (word address = bit address >> 4)
    wire is_vram = (mem_addr[31:23] == 9'h1ff);               // ff800000-ffffffff
    wire is_exp  = (mem_addr[31:20] == 12'h020);              // 02000000-020fffff
    wire is_clo  = (mem_addr[31:8]  == 24'hf40000);
    wire is_chi  = (mem_addr[31:8]  == 24'hf48000);
    wire is_plo  = (mem_addr[31:12] == 20'hf5000);
    wire is_phi  = (mem_addr[31:12] == 20'hf5800);

    logic [15:0] control_lo [0:15];
    logic [15:0] control_hi [0:15];
    logic        srt_enable;
    logic [15:0] pal_lo_q, pal_hi_q, clo_q, chi_q;
    wire   [9:0] pal_idx = {palbank, mem_addr[11:4]};
    // read data lands one cycle after IDLE, i.e. in REG_RD
    sdpram #(.AW(10), .DW(16)) pal_lo (.clk(clk), .we(pal_we_rg), .waddr(pal_waddr), .wdata(pal_wdata), .raddr(pal_idx), .q(pal_lo_q));
    sdpram #(.AW(10), .DW(16)) pal_hi (.clk(clk), .we(pal_we_b),  .waddr(pal_waddr), .wdata(pal_wdata), .raddr(pal_idx), .q(pal_hi_q));
    logic [17:0] srt_src;             // latched source row (VRAM word index, row aligned)

    typedef enum logic [3:0] {IDLE, VRAM_WAIT, EXP0, EXP1, EXP2, EXP3, EXP_WAIT,
                              REG_RD, SRT_BURST, SRT_BURST_WAIT, SRT_BURST_GAP, DONE} st_t;
    st_t st;
    logic  [1:0] exp_n;
    logic [15:0] exp_mask;            // data word driving the 4 masked writes
    logic [15:0] exp_color;
    logic [17:0] exp_base;
    logic [10:0] srt_cnt;             // words transferred so far (piece base)
    logic [10:0] srt_len;             // words in the current phase
    logic [17:0] srt_dst;
    logic        srt_we;              // 0: read the source row into the buffer, 1: write it to the destination
    // Row transfers (shift-register rows and the blit engine's fast rows) go
    // through this buffer: burst reads fill it, burst writes drain it.
    //   xf_src/xf_dst   VRAM word addresses of the phase
    //   xf_sh           source byte shift for blit rows: 0 aligned, 1 = source
    //                   pixel 0 is the high byte (dest word j = {src j+1 lo, src j hi}),
    //                   2 = dest pixel 0 is the high byte (dest word j = {src j lo, src j-1 hi});
    //                   the assembly happens as the source words arrive
    //   xf_be_first/last  byte enables of the first and last destination word
    //   xf_fill/xf_color  fill instead of copy
    logic [17:0] xf_src;
    logic  [1:0] xf_sh, xf_be_first, xf_be_last;
    logic        xf_fill, xf_isrc;    // xf_isrc: this transfer is a blit row (rc), not an SRT row
    logic        xf_transp;           // transparency on zero: a zero destination byte is not written
    logic [15:0] xf_color, xf_prev;
    wire  [10:0] rb_gi   = srt_cnt + {1'b0, sb_idx};           // global index of the arriving word
    wire  [10:0] rb_go   = srt_cnt + {1'b0, sb_widx};          // global index of the word being written
    wire         rb_we   = sb_wr && !(xf_sh == 2'd1 && rb_gi == 11'd0);
    wire   [9:0] rb_wa   = (xf_sh == 2'd1) ? rb_gi[9:0] - 10'd1 : rb_gi[9:0];
    wire  [15:0] rb_wd   = (xf_sh == 2'd0) ? sb_data : {sb_data[7:0], xf_prev[15:8]};
    logic [15:0] rb_q;
    sdpram #(.AW(10), .DW(16)) rowbuf (.clk(clk), .we(rb_we), .waddr(rb_wa), .wdata(rb_wd),
                                       .raddr(rb_go[9:0]), .q(rb_q));
    assign sb_wdata = xf_fill ? xf_color : rb_q;
    assign sb_be    = ((rb_go == 11'd0) ? xf_be_first : 2'b11) & ((rb_go == srt_len - 11'd1) ? xf_be_last : 2'b11)
                    & (xf_transp ? {sb_wdata[15:8] != 8'h00, sb_wdata[7:0] != 8'h00} : 2'b11);
    always_ff @(posedge clk) if (sb_wr) xf_prev <= sb_data;
    // rc geometry: first/last destination words and the source span
    wire         rc_db0 = rc_dst[3];                                   // dest pixel 0 in the high byte
    wire         rc_sb0 = rc_src[3];
    wire  [16:0] rc_lastb = {1'b0, rc_len} + {16'd0, rc_db0} - 17'd1;  // byte offset of the last pixel
    wire  [10:0] rc_ndw   = rc_lastb[11:1] + 11'd1;                    // destination words (len <= 512 -> <= 257)
    wire   [1:0] rc_sh    = (rc_sb0 == rc_db0) ? 2'd0 : rc_sb0 ? 2'd1 : 2'd2;
    wire         rc_unused_ok = &{1'b0, rc_src[31:22], rc_src[2:0], rc_dst[31:22], rc_dst[2:0], rc_lastb[16:12], xf_prev[7:0]};

    wire [17:0] vram_word = mem_addr[21:4];
    // expander destination: 4 words at (region word offset) * 4
    wire [17:0] exp_dst   = {mem_addr[19:4], 2'b00};

    always_ff @(posedge clk) begin
        mem_ack   <= 1'b0;
        rc_ack    <= 1'b0;
        vram_copied <= 1'b0;
        pal_we_rg <= 1'b0;
        pal_we_b  <= 1'b0;
        if (reset) begin
            st <= IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sb_req <= 1'b0; sb_we <= 1'b0;
            finescroll <= '0; palbank <= '0; srt_enable <= 1'b0; srt_src <= '0;
        end else begin
            case (st)
                IDLE: if (rc_req && !rc_ack) begin
                    // blit row: read the source span into the buffer (unless a fill), then write
                    xf_isrc     <= 1'b1;
                    xf_fill     <= rc_fill;
                    xf_transp   <= rc_transp;
                    xf_color    <= rc_color;
                    xf_sh       <= rc_sh;
                    xf_be_first <= rc_db0 ? 2'b10 : 2'b11;
                    xf_be_last  <= rc_lastb[0] ? 2'b11 : 2'b01;
                    xf_src      <= rc_src[21:4];
                    srt_dst     <= rc_dst[21:4];
                    srt_cnt     <= '0;
                    if (rc_fill) begin srt_we <= 1'b1; srt_len <= rc_ndw; end
                    else         begin srt_we <= 1'b0; srt_len <= rc_ndw + ((rc_sh == 2'd1) ? 11'd1 : 11'd0); end
                    st <= SRT_BURST;
                end else if (mem_req && !mem_ack) begin
                    if (is_vram) begin
                        if (mem_srt) begin
                            // shift-register transfer: read = latch source row, write = copy
                            if (!mem_we) begin
                                srt_src <= {vram_word[17:8], 8'd0};
                                mem_rdata <= 16'h0000; mem_ack <= 1'b1;
                            end else if (srt_enable) begin
                                srt_dst <= {vram_word[17:8], 8'd0}; xf_src <= srt_src;
                                xf_isrc <= 1'b0; xf_fill <= 1'b0; xf_transp <= 1'b0; xf_sh <= 2'd0; xf_be_first <= 2'b11; xf_be_last <= 2'b11;
                                srt_we <= 1'b0; srt_len <= 11'd256; srt_cnt <= '0;   // read phase first
                                st <= SRT_BURST;
                            end else
                                mem_ack <= 1'b1;
                        end else begin
                            sd_addr  <= VRAM_BASE + {6'd0, vram_word};
                            sd_we    <= mem_we;
                            sd_wdata <= mem_wdata;
                            sd_be    <= 2'b11;
                            sd_req   <= 1'b1;
                            st       <= VRAM_WAIT;
                        end
                    end else if (is_exp) begin
                        if (mem_srt) begin
                            if (!mem_we) begin
                                srt_src <= {mem_addr[19:12], 10'd0};      // (addr>>2) & ~1023 words
                                mem_rdata <= 16'h0000; mem_ack <= 1'b1;
                            end else if (srt_enable) begin
                                srt_dst <= {mem_addr[19:12], 10'd0}; xf_src <= srt_src;
                                xf_isrc <= 1'b0; xf_fill <= 1'b0; xf_transp <= 1'b0; xf_sh <= 2'd0; xf_be_first <= 2'b11; xf_be_last <= 2'b11;
                                srt_we <= 1'b0; srt_len <= 11'd1024; srt_cnt <= '0;  // read phase first
                                st <= SRT_BURST;
                            end else
                                mem_ack <= 1'b1;
                        end else if (mem_we) begin
                            exp_mask  <= mem_wdata;
                            exp_color <= control_lo[0];
                            exp_base  <= exp_dst;
                            exp_n     <= 2'd0;
                            st        <= EXP0;
                        end else begin
                            mem_rdata <= 16'h0000; mem_ack <= 1'b1;
                        end
                    end else if (is_clo) begin
                        if (mem_we) control_lo[mem_addr[7:4]] <= mem_wdata;
                        clo_q <= control_lo[mem_addr[7:4]];
                        st <= REG_RD;
                    end else if (is_chi) begin
                        if (mem_we) begin
                            control_hi[mem_addr[7:4]] <= mem_wdata;
                            case (mem_addr[6:4])
                                3'd0: srt_enable <= mem_addr[7];
                                3'd1: finescroll <= mem_wdata[2:0];
                                3'd2: palbank[0] <= mem_addr[7];
                                3'd3: palbank[1] <= mem_addr[7];
                                default: ;
                            endcase
                        end
                        chi_q <= control_hi[mem_addr[7:4]];
                        st <= REG_RD;
                    end else if (is_plo) begin
                        if (mem_we) begin
                            pal_we_rg <= 1'b1; pal_waddr <= pal_idx; pal_wdata <= mem_wdata;
                        end
                        st <= REG_RD;
                    end else if (is_phi) begin
                        if (mem_we) begin
                            pal_we_b <= 1'b1; pal_waddr <= pal_idx; pal_wdata <= mem_wdata;
                        end
                        st <= REG_RD;
                    end else begin
                        mem_rdata <= 16'hffff; mem_ack <= 1'b1;
                    end
                end
                VRAM_WAIT: if (sd_ack) begin
                    sd_req <= 1'b0; mem_rdata <= sd_rdata; mem_ack <= 1'b1; st <= IDLE;
                end
                REG_RD: begin
                    mem_rdata <= is_clo ? clo_q : is_chi ? chi_q : is_plo ? pal_lo_q : pal_hi_q;
                    mem_ack <= 1'b1; st <= IDLE;
                end
                // expander: word n gets pixel bits {2n*2+... }: word0 bits 0,2; word1 bits 4,6; word2 bits 8,10; word3 bits 12,14
                EXP0: begin
                    sd_addr  <= VRAM_BASE + {6'd0, exp_base + {16'd0, exp_n}};
                    sd_wdata <= exp_color;
                    sd_we    <= 1'b1;
                    sd_be    <= {exp_mask[{exp_n, 2'b10}], exp_mask[{exp_n, 2'b00}]};
                    if (exp_mask[{exp_n, 2'b10}] | exp_mask[{exp_n, 2'b00}]) begin
                        sd_req <= 1'b1; st <= EXP_WAIT;
                    end else begin
                        if (exp_n == 2'd3) begin mem_ack <= 1'b1; st <= IDLE; end
                        else exp_n <= exp_n + 2'd1;
                    end
                end
                EXP_WAIT: if (sd_ack) begin
                    sd_req <= 1'b0;
                    if (exp_n == 2'd3) begin mem_ack <= 1'b1; st <= IDLE; end
                    else begin exp_n <= exp_n + 2'd1; st <= EXP0; end
                end
                // shift-register transfer, one 32-word burst piece at a time
                SRT_BURST: begin
                    sb_addr <= VRAM_BASE + {6'd0, (srt_we ? srt_dst : xf_src) + {7'd0, srt_cnt}};
                    sb_len  <= (srt_len - srt_cnt > 11'd32) ? 10'd32 : 10'(srt_len - srt_cnt);
                    sb_we   <= srt_we;
                    sb_req  <= 1'b1;
                    st      <= SRT_BURST_WAIT;
                end
                SRT_BURST_WAIT: if (sb_done) begin
                    sb_req  <= 1'b0;
                    srt_cnt <= srt_cnt + {1'b0, sb_len};
                    if (srt_cnt + {1'b0, sb_len} == srt_len) begin
                        if (!srt_we) begin
                            // source is in the buffer: now write the destination words
                            srt_we <= 1'b1; srt_cnt <= '0;
                            srt_len <= xf_isrc ? rc_ndw : srt_len;   // a blit row read one extra word when shifted
                            st <= SRT_BURST_GAP;
                        end else begin
                            if (xf_isrc) rc_ack <= 1'b1; else begin mem_ack <= 1'b1; vram_copied <= 1'b1; end
                            st <= IDLE;
                        end
                    end else
                        st <= SRT_BURST_GAP;       // a clock with sb_req low: the controller re-arms
                end
                SRT_BURST_GAP: st <= SRT_BURST;
                default: st <= IDLE;
            endcase
        end
    end
endmodule
