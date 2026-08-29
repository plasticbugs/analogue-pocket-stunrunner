//------------------------------------------------------------------------------
// Multisync main board, 68010 side (docs/hardware.md sections 2 and 3).
//
// The TG68K.C kernel (CPU="01" = 68010: VBR, MOVEC, MOVES, format-0 frames)
// steps once per `clkena_in`; a memory access is presented on addr_out/
// busstate and completed on the step that has data_in valid. Every bus
// cycle is paced to STEP_DIV system-clock-enable pulses so the kernel runs
// close to a real 8 MHz 68010, and stretched while SDRAM (program ROM)
// answers.
//
// Everything the 68010 can touch that is *on this board* is here: work RAM,
// ZRAM (timekeeper + EEPROM), the latches, ADC0809, the DUART stub, the
// 244 Hz timer, the interrupt priority encoder. The GSP host port, the ADSP
// board and the JSA II board are reached through the ports at the bottom.
//------------------------------------------------------------------------------
`default_nettype none

module stunrun_main #(
    // Kernel step pacing: a step costs STEP_COST tokens, each cen_8m pulse
    // adds STEP_GAIN. 4/15 = 3.75 cen_8m per step, measured against a MAME
    // trace of the first three boot frames to run within ~3 % of a real
    // 8 MHz 68010 (sim/run_main.sh reports the simulated time).
    parameter STEP_GAIN = 4,
    parameter STEP_COST = 15
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_8m,

    // program ROM in SDRAM (memory request interface)
    output logic [24:1] rom_addr,
    output logic        rom_req,
    input  logic [15:0] rom_rdata,
    input  logic        rom_ack,

    // inputs
    input  logic  [7:0] in0,          // bits 0,5,6,7 (diag, test, coin2, coin1); 1-4 generated here
    input  logic  [7:0] sw1,
    input  logic  [2:0] a80000,       // {start, button2, button1} active high
    input  logic  [7:0] stick_x, stick_y,
    input  logic        vblank_n, hblank_n,

    // ZRAM external port (NVRAM load / save), byte addressed 0..4095
    input  logic [11:0] nv_addr,
    input  logic        nv_we,
    input  logic  [7:0] nv_wdata,
    output logic  [7:0] nv_rdata,
    output logic        nv_dirty,     // toggles on every game write to ZRAM

    // GSP host interface
    output logic  [1:0] host_addr,
    output logic        host_rd, host_wr,
    output logic [15:0] host_wdata,
    input  logic [15:0] host_rdata,
    input  logic        host_ready,
    input  logic        gsp_int,      // level 3
    output logic        gsp_reset_n,  // /GSPRES latch

    // ADSP board
    output logic [12:0] pm_addr,      // program RAM (24-bit words)
    output logic        pm_we,
    output logic [23:0] pm_wdata,
    input  logic [23:0] pm_rdata,     // 1-cycle latency
    output logic [12:0] dm_addr,      // data RAM
    output logic        dm_we,
    output logic [15:0] dm_wdata,
    input  logic [15:0] dm_rdata,     // 1-cycle latency
    output logic [13:0] som_addr,     // {bank, offset}
    output logic        som_we,
    output logic  [1:0] som_be,
    output logic [15:0] som_wdata,
    input  logic [15:0] som_rdata,    // 1-cycle latency
    output logic        adsp_bank,    // SOM bank the 68k sees
    output logic        adsp_halt,    // /HALT or /BR active
    output logic        adsp_reset,   // active high
    input  logic        adsp_int,     // /GINT latched (level 2)
    output logic        adsp_int_clr,
    input  logic        adsp_xflag,

    // JSA II
    output logic        snd_cmd_wr,
    output logic  [7:0] snd_cmd,
    output logic        snd_resp_rd,
    input  logic  [7:0] snd_resp,
    input  logic        snd_int,      // level 4
    output logic        snd_reset,

    // watchdog: the game kicks 608000 every frame; FatalError stops the CPU
    // and relies on this to reboot the machine (docs/boot-sequence.md)
    output logic        wdog_reset,   // 1 for WDOG_PULSE cen_8m pulses after WDOG_PERIOD without a kick

    // debug
    output logic [31:0] dbg_pc,
    output logic        dbg_step
);
    localparam int WDOG_PERIOD = 8_000_000;   // 1 s of cen_8m
    localparam int WDOG_PULSE  = 8_000;       // 1 ms
    // ------------------------------------------------------------------------
    // TG68K kernel
    // ------------------------------------------------------------------------
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    logic [31:0] addr_out;
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic        nResetOut;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    logic  [2:0] fc;
    logic        longword, clr_berr, skipFetch;
    logic  [2:0] step_gap;          // holds the bus FSM off for 3 clocks after clkena

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b01 ),
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out )
    );

    wire [23:1] A     = addr_out[23:1];
    wire        is_wr = (busstate == 2'b11);
    wire        is_rd = (busstate == 2'b00) || (busstate == 2'b10);
    wire        uds   = ~nUDS;             // D15:8
    wire        lds   = ~nLDS;             // D7:0

    // ------------------------------------------------------------------------
    // Address decode
    // ------------------------------------------------------------------------
    wire sel_rom   = (A[23:20] == 4'h0);
    wire sel_snd   = (A[23:14] == 10'b0110_0000_00);   // 600000-603fff
    wire sel_sres  = (A[23:14] == 10'b0110_0000_01);   // 604000-607fff
    wire sel_wdog  = (A[23:14] == 10'b0110_0000_10);   // 608000-60bfff
    wire sel_port0 = (A[23:14] == 10'b0110_0000_11);   // 60c000-60ffff
    wire sel_pm    = (A[23:15] == 9'b1000_0000_0);     // 800000-807fff
    wire sel_dm    = (A[23:14] == 10'b1000_0000_10);   // 808000-80bfff
    wire sel_som   = (A[23:14] == 10'b1000_0001_00);   // 810000-813fff
    wire sel_actl  = (A[23:5]  == 19'h40c00);          // 818000-81801f
    wire sel_aclr  = (A[23:5]  == 19'h40c03);          // 818060-81807f
    wire sel_astat = (A[23:15] == 9'b1000_0011_1);     // 838000-83ffff
    wire sel_a8    = (A[23:19] == 5'b1010_1);          // a80000-afffff
    wire sel_adc8  = (A[23:19] == 5'b1011_0);          // b00000-b7ffff
    wire sel_adc12 = (A[23:19] == 5'b1011_1);          // b80000-bfffff
    wire sel_gsp   = (A[23:14] == 10'b1100_0000_00);   // c00000-c03fff
    wire sel_duart = (A[23:5]  == 19'h7f800);          // ff0000-ff001f
    wire sel_zram  = (A[23:12] == 12'hff4);            // ff4000-ff4fff
    wire sel_ram   = (A[23:15] == 9'b1111_1111_1);     // ff8000-ffffff

    // ------------------------------------------------------------------------
    // Work RAM 16K x 16 and ZRAM 2K x 16, byte-lane block RAMs
    // ------------------------------------------------------------------------
    logic [1:0][7:0] wram [0:16383];
    logic [15:0]     wram_q;
    logic [15:0]     zram_q;
    logic [15:0]     zram_ext_w;
    logic            zram_we_cpu;
    logic  [1:0]     zram_be_cpu;
    logic [10:0]     zram_addr_cpu;
    logic [15:0]     zram_wdata_cpu;
    logic            zp1, zp2;
    wire             zram_wp = !(zp1 == 1'b0 && zp2 == 1'b1);   // writes allowed only when ZP1=0, ZP2=1

    // ------------------------------------------------------------------------
    // Bus cycle sequencer
    // ------------------------------------------------------------------------
    typedef enum logic [3:0] {B_IDLE, B_WAIT_ROM, B_WAIT_GSP, B_PM_RD, B_PM_MERGE, B_RAM_RD, B_DM_RD, B_DM_MERGE} bst_t;
    bst_t bst;
    logic [5:0] tok;                 // step tokens from cen_8m
    logic       irq_timer_pend;
    logic [15:0] rd_mux;
    logic  [7:0] adc_data;
    logic        adc_eoc;
    logic [14:0] timer_cnt;
    logic [15:0] duart_q;
    logic        br_n_lat, halt_n_lat;   // /BR, /HALT latches (power-up: BR released, HALT asserted)
    logic  [7:0] adc_ctl;
    logic        adc12_byte;

    // port 0
    wire [15:0] port0 = { sw1,
                          in0[7], in0[6], in0[5], adc_eoc, 1'b1, vblank_n, hblank_n, in0[0] };
    wire [15:0] a8port = { 13'h1fff, ~a80000[2], ~a80000[1], ~a80000[0] };

    // ADSP IRQ state: 0xfffd, bit1 set by XFLAG, bit0 cleared by pending IRQ
    wire [15:0] astat = { 14'h3fff, adsp_xflag, ~adsp_int };

    // DUART stub: SRA/SRB report transmitter ready+empty, ISR nothing pending
    always_comb begin
        case (A[4:1])
            4'h1, 4'h9: duart_q = 16'h0cff;
            default:    duart_q = 16'h00ff;
        endcase
    end

    // read multiplexer for the sources that answer in one cycle
    always_comb begin
        rd_mux = 16'hffff;
        if (sel_ram)   rd_mux = wram_q;
        else if (sel_zram) rd_mux = zram_q;
        else if (sel_port0) rd_mux = port0;
        else if (sel_a8)   rd_mux = a8port;
        else if (sel_adc8) rd_mux = {8'hff, adc_data};
        else if (sel_adc12) rd_mux = adc12_byte ? 16'hff0f : 16'hffff;
        else if (sel_astat) rd_mux = astat;
        else if (sel_snd)  rd_mux = {snd_resp, 8'hff};
        else if (sel_duart) rd_mux = duart_q;
        else if (sel_dm)   rd_mux = dm_rdata;
        else if (sel_som)  rd_mux = som_rdata;
        else if (sel_pm)   rd_mux = A[1] ? pm_rdata[15:0] : {8'h00, pm_rdata[23:16]};
    end

    // one-cycle strobes
    always_ff @(posedge clk) begin
        host_rd <= 1'b0; host_wr <= 1'b0;
        snd_cmd_wr <= 1'b0; snd_resp_rd <= 1'b0; snd_reset <= 1'b0;
        adsp_int_clr <= 1'b0;
        pm_we <= 1'b0; dm_we <= 1'b0; som_we <= 1'b0; zram_we_cpu <= 1'b0; wdog_kick <= 1'b0;
        rom_req <= rom_req;
        clkena  <= 1'b0;
        dbg_step <= 1'b0;
        step_gap <= {step_gap[1:0], clkena};

        if (reset) begin
            bst <= B_IDLE; tok <= '0; clkena <= 1'b0; rom_req <= 1'b0; step_gap <= '0;
            zp1 <= 1'b0; zp2 <= 1'b0; gsp_reset_n <= 1'b0;
            adsp_bank <= 1'b0; br_n_lat <= 1'b1; halt_n_lat <= 1'b0; adsp_reset <= 1'b1;
            irq_timer_pend <= 1'b0; timer_cnt <= '0;
            adc_ctl <= '0; adc12_byte <= 1'b0; nv_dirty <= 1'b0;
        end else begin
            // step pacing
            if (cen_8m && tok < 6'd48) tok <= tok + 6'(STEP_GAIN);

            // 244.14 Hz timer: 32768 cen_8m pulses
            if (cen_8m) begin
                timer_cnt <= timer_cnt + 15'd1;
                if (timer_cnt == 15'd32767) irq_timer_pend <= 1'b1;
            end

            case (bst)
                B_IDLE: begin
                    // Do not sample the bus for four clocks after a step. The
                    // kernel's registers update on the edge that ends the
                    // clkena cycle, and every one of this module's captures of
                    // a kernel output -- busstate/skipFetch into bst, tok and
                    // clkena, and A/data_write/uds/lds into the peripheral and
                    // RAM write ports -- happens on the sampling tick. Without
                    // the gap that is a ONE-clock path, and the widest of those
                    // cones (kernel state -> address decode -> the work-RAM
                    // write port) measures 31.8 ns. `!clkena` blocks the first
                    // clock; step_gap blocks the next three, so the sample lands
                    // four clocks after the kernel moved and the 4/3 multicycle
                    // in the SDC describes real silicon. The step rate is set by
                    // the token bucket (one step per 3.75 cen_8m, about 45
                    // clocks), so five clocks of bus FSM cost nothing.
                    if (tok >= 6'(STEP_COST) && !clkena && step_gap == 3'd0) begin
                        // skipFetch: the kernel is in a read state whose bus
                        // cycle must NOT happen (68010 CLR/SF/etc. do not read
                        // their destination); step without touching the bus,
                        // exactly as the TG68K.vhd wrapper does. Performing the
                        // read anyway costs time and, on the GSP host port
                        // with INCR set, advances HSTADR by a word per CLR.
                        if (busstate == 2'b01 || skipFetch) begin
                            clkena <= 1'b1; tok <= tok - 6'(STEP_COST);
                        end else if (is_wr) begin
                            // writes complete immediately (posted)
                            tok <= tok - 6'(STEP_COST);
                            if (sel_ram) begin
                                if (uds) wram[A[14:1]][1] <= data_write[15:8];
                                if (lds) wram[A[14:1]][0] <= data_write[7:0];
                                clkena <= 1'b1;
                            end else if (sel_zram) begin
                                if (!zram_wp) begin
                                    zram_we_cpu <= 1'b1; zram_be_cpu <= {uds, lds};
                                    zram_addr_cpu <= A[11:1]; zram_wdata_cpu <= data_write;
                                    nv_dirty <= ~nv_dirty;
                                end
                                clkena <= 1'b1;
                            end else if (sel_snd) begin
                                snd_cmd_wr <= 1'b1; snd_cmd <= data_write[15:8]; clkena <= 1'b1;
                            end else if (sel_sres) begin
                                // /NWR latch: sel = A[3:1], value = A[4]
                                case (A[3:1])
                                    3'd4: zp1 <= A[4];
                                    3'd5: zp2 <= A[4];
                                    3'd6: gsp_reset_n <= A[4];
                                    default: ;
                                endcase
                                clkena <= 1'b1;
                            end else if (sel_wdog) begin
                                wdog_kick <= 1'b1; clkena <= 1'b1;           // watchdog kick
                            end else if (sel_port0) begin
                                irq_timer_pend <= 1'b0; clkena <= 1'b1;      // IRQ5 ack
                            end else if (sel_pm) begin
                                pm_addr <= A[14:2];
                                bst <= B_PM_RD;                              // read-modify-write of the 24-bit word
                            end else if (sel_dm) begin
                                dm_addr <= A[13:1];
                                if (uds && lds) begin
                                    dm_we <= 1'b1; dm_wdata <= data_write; clkena <= 1'b1;
                                end else
                                    bst <= B_DM_RD;                          // byte write: merge with the other byte
                            end else if (sel_som) begin
                                som_addr <= {adsp_bank, A[13:1]}; som_we <= 1'b1; som_be <= {uds, lds}; som_wdata <= data_write;
                                clkena <= 1'b1;
                            end else if (sel_actl) begin
                                case (A[3:1])
                                    3'd3: adsp_bank  <= A[4];
                                    3'd5: br_n_lat   <= A[4];                          // /BR
                                    3'd6: halt_n_lat <= A[4];                          // /HALT
                                    3'd7: adsp_reset <= ~A[4];
                                    default: ;
                                endcase
                                clkena <= 1'b1;
                            end else if (sel_aclr) begin
                                adsp_int_clr <= 1'b1; clkena <= 1'b1;
                            end else if (sel_adc12) begin
                                adc_ctl <= data_write[7:0]; adc12_byte <= data_write[7];
                                clkena <= 1'b1;
                            end else if (sel_gsp) begin
                                host_addr <= {A[3], ~A[2]}; host_wr <= 1'b1; host_wdata <= data_write;
                                bst <= B_WAIT_GSP;
                            end else begin
                                clkena <= 1'b1;                              // wdog, wr0/1/2, msp, duart: ignored
                            end
                        end else if (is_rd) begin
                            tok <= tok - 6'(STEP_COST);
                            if (sel_rom) begin
                                if (A[23:1] < 23'h60000) begin
                                    rom_addr <= {1'b0, A[23:1]}; rom_req <= 1'b1; bst <= B_WAIT_ROM;
                                end else begin
                                    data_in <= 16'hffff; clkena <= 1'b1;
                                end
                            end else if (sel_gsp) begin
                                host_addr <= {A[3], ~A[2]}; host_rd <= 1'b1; bst <= B_WAIT_GSP;
                            end else begin
                                // block RAMs answer next cycle; latches are combinational
                                if (sel_pm) pm_addr <= A[14:2];
                                if (sel_dm) dm_addr <= A[13:1];
                                if (sel_som) som_addr <= {adsp_bank, A[13:1]};
                                if (sel_snd) snd_resp_rd <= 1'b1;          // clears IRQ4
                                if (sel_sres) snd_reset <= 1'b1;
                                bst <= B_RAM_RD;
                            end
                        end
                    end
                end
                B_RAM_RD: begin
                    data_in <= rd_mux; clkena <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_ROM: begin
                    if (rom_ack) begin
                        rom_req <= 1'b0; data_in <= rom_rdata; clkena <= 1'b1; bst <= B_IDLE;
                    end
                end
                B_WAIT_GSP: begin
                    if (host_ready) begin
                        data_in <= host_rdata; clkena <= 1'b1; bst <= B_IDLE;
                    end
                end
                B_DM_RD: bst <= B_DM_MERGE;          // dm_rdata valid next cycle
                B_DM_MERGE: begin
                    dm_wdata <= {uds ? data_write[15:8] : dm_rdata[15:8], lds ? data_write[7:0] : dm_rdata[7:0]};
                    dm_we <= 1'b1; clkena <= 1'b1; bst <= B_IDLE;
                end
                B_PM_RD: bst <= B_PM_MERGE;          // pm_rdata valid next cycle
                B_PM_MERGE: begin
                    pm_wdata <= pm_rdata;
                    if (A[1]) begin
                        if (uds) pm_wdata[15:8] <= data_write[15:8];
                        if (lds) pm_wdata[7:0]  <= data_write[7:0];
                    end else begin
                        if (lds) pm_wdata[23:16] <= data_write[7:0];
                    end
                    pm_we <= 1'b1; clkena <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase
            if (clkena) dbg_step <= 1'b1;
        end
    end

    // /BR and /HALT are independent latches; either asserted halts the ADSP
    assign adsp_halt = !(br_n_lat && halt_n_lat);

    // block RAM read ports (registered)
    always_ff @(posedge clk) begin
        wram_q <= wram[A[14:1]];
    end
    // ZRAM: port A = 68k (word, byte lanes), port B = save/load port (bytes).
    // The save image is the 4 KB ZRAM as the 68k sees it: word w -> bytes 2w
    // (D15:8, 200E timekeeper) and 2w+1 (D7:0, 210E EEPROM).
    // The CPU write is issued one cycle after the decision from its own
    // registered address/data (the kernel steps on that cycle); reads use the
    // live address, which is stable for the read cycle.
    dpram_be #(.AW(11)) zram (
        .clk(clk),
        .a_addr(zram_we_cpu ? zram_addr_cpu : A[11:1]), .a_we(zram_we_cpu), .a_be(zram_be_cpu), .a_wdata(zram_wdata_cpu), .a_rdata(zram_q),
        .b_addr(nv_addr[11:1]), .b_we(nv_we), .b_be(nv_addr[0] ? 2'b01 : 2'b10), .b_wdata({nv_wdata, nv_wdata}), .b_rdata(zram_ext_w)
    );
    logic nv_addr0_d;
    always_ff @(posedge clk) nv_addr0_d <= nv_addr[0];
    assign nv_rdata = nv_addr0_d ? zram_ext_w[7:0] : zram_ext_w[15:8];

    // ------------------------------------------------------------------------
    // Watchdog
    // ------------------------------------------------------------------------
    logic [23:0] wdog_cnt;
    logic        wdog_kick;
    always_ff @(posedge clk) begin
        if (reset) begin wdog_cnt <= '0; wdog_reset <= 1'b0; end
        else if (wdog_kick) wdog_cnt <= '0;
        else if (cen_8m) begin
            if (wdog_cnt != 24'(WDOG_PERIOD + WDOG_PULSE)) wdog_cnt <= wdog_cnt + 24'd1;
            wdog_reset <= (wdog_cnt >= 24'(WDOG_PERIOD)) && (wdog_cnt < 24'(WDOG_PERIOD + WDOG_PULSE));
        end
    end

    // ------------------------------------------------------------------------
    // ADC0809: channel latched and conversion started on the START bit's
    // rising edge; EOC low for ~72 us then the result is available.
    // ------------------------------------------------------------------------
    logic       adc_start_d;
    logic [9:0] adc_timer;
    logic [2:0] adc_chan;
    always_ff @(posedge clk) begin
        if (reset) begin
            adc_eoc <= 1'b1; adc_timer <= '0; adc_start_d <= 1'b0; adc_data <= 8'h80; adc_chan <= '0;
        end else begin
            adc_start_d <= adc_ctl[3];
            if (adc_ctl[3] && !adc_start_d) begin
                adc_chan <= adc_ctl[2:0]; adc_eoc <= 1'b0; adc_timer <= 10'd576;   // 72 us of cen_8m
            end else if (!adc_eoc && cen_8m) begin
                adc_timer <= adc_timer - 10'd1;
                if (adc_timer == 10'd0) begin
                    adc_eoc <= 1'b1;
                    case (adc_chan)
                        3'd0: adc_data <= stick_x;
                        3'd2: adc_data <= stick_y;
                        default: adc_data <= 8'hff;
                    endcase
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Interrupts: level 2 ADSP, 3 GSP, 4 sound, 5 timer, (6 DUART: never)
    // ------------------------------------------------------------------------
    always_comb begin
        if (irq_timer_pend)  ipl_n = ~3'd5;
        else if (snd_int)    ipl_n = ~3'd4;
        else if (gsp_int)    ipl_n = ~3'd3;
        else if (adsp_int)   ipl_n = ~3'd2;
        else                 ipl_n = 3'b111;
    end

    assign dbg_pc = addr_out;
endmodule
