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
// Shift-register transfers (mem_srt): a read cycle captures the source row
// (256 words, or 1024 in the expander region) into a row buffer -- the VRAM
// shift register -- and a write cycle, when the control_hi enable is set,
// streams the buffer into the destination row. Both go over the SDRAM burst
// port in 32-word pieces (one READ/WRITE per 2 clocks in the open row) so the
// display line fetch never waits more than a piece. Doing this word by word
// through the random port cost ~5,000 clocks a row and froze the GSP inside a
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

    // SDRAM burst client (shift-register rows), arbitrated in stunrun_core
    output logic [24:1] sb_addr,
    output logic  [9:0] sb_len,
    output logic        sb_req, sb_we,
    output logic [15:0] sb_wdata,
    input  logic        sb_wr,
    input  logic  [9:0] sb_idx,
    input  logic [15:0] sb_data,
    input  logic        sb_done,
    input  logic  [9:0] sb_widx,

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
    logic [10:0] srt_len;
    logic [17:0] srt_dst;
    logic        srt_we;              // 0: capture source row, 1: write destination row
    // the shift register: 1024 x 16, written by burst reads, read by burst writes
    sdpram #(.AW(10), .DW(16)) rowbuf (.clk(clk), .we(sb_wr), .waddr(srt_cnt[9:0] + sb_idx), .wdata(sb_data),
                                       .raddr(srt_cnt[9:0] + sb_widx), .q(sb_wdata));

    wire [17:0] vram_word = mem_addr[21:4];
    // expander destination: 4 words at (region word offset) * 4
    wire [17:0] exp_dst   = {mem_addr[19:4], 2'b00};

    always_ff @(posedge clk) begin
        mem_ack   <= 1'b0;
        vram_copied <= 1'b0;
        pal_we_rg <= 1'b0;
        pal_we_b  <= 1'b0;
        if (reset) begin
            st <= IDLE; sd_req <= 1'b0; sd_we <= 1'b0; sb_req <= 1'b0; sb_we <= 1'b0;
            finescroll <= '0; palbank <= '0; srt_enable <= 1'b0; srt_src <= '0;
        end else begin
            case (st)
                IDLE: if (mem_req && !mem_ack) begin
                    if (is_vram) begin
                        if (mem_srt) begin
                            // shift-register transfer: read = latch source row, write = copy
                            if (!mem_we) begin
                                srt_src <= {vram_word[17:8], 8'd0};
                                srt_we <= 1'b0; srt_len <= 11'd256; srt_cnt <= '0;
                                mem_rdata <= 16'h0000;
                                st <= SRT_BURST;
                            end else if (srt_enable) begin
                                srt_dst <= {vram_word[17:8], 8'd0};
                                srt_we <= 1'b1; srt_len <= 11'd256; srt_cnt <= '0;
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
                                srt_we <= 1'b0; srt_len <= 11'd1024; srt_cnt <= '0;
                                mem_rdata <= 16'h0000;
                                st <= SRT_BURST;
                            end else if (srt_enable) begin
                                srt_dst <= {mem_addr[19:12], 10'd0};
                                srt_we <= 1'b1; srt_len <= 11'd1024; srt_cnt <= '0;
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
                    sb_addr <= VRAM_BASE + {6'd0, (srt_we ? srt_dst : srt_src) + {7'd0, srt_cnt}};
                    sb_len  <= 10'd32;
                    sb_we   <= srt_we;
                    sb_req  <= 1'b1;
                    st      <= SRT_BURST_WAIT;
                end
                SRT_BURST_WAIT: if (sb_done) begin
                    sb_req  <= 1'b0;
                    srt_cnt <= srt_cnt + 11'd32;
                    if (srt_cnt + 11'd32 == srt_len) begin
                        mem_ack <= 1'b1;
                        if (srt_we) vram_copied <= 1'b1;
                        st <= IDLE;
                    end else
                        st <= SRT_BURST_GAP;       // a clock with sb_req low: the controller re-arms
                end
                SRT_BURST_GAP: st <= SRT_BURST;
                default: st <= IDLE;
            endcase
        end
    end
endmodule
