//------------------------------------------------------------------------------
// Atari JSA II sound board, as fitted to S.T.U.N. Runner.
//
// A 6502 (T65, converted from VHDL) at 1.789772 MHz with 8 KB of RAM and a
// 64 KB program ROM (4 KB banked window at 3000-3FFF), a YM2151 (jt51) at
// 3.579545 MHz and an OKI MSM6295 (jt6295) at 1.193181 MHz, plus the latches
// that talk to the 68010. Everything follows docs/hardware.md §6, which was
// taken from MAME's atarijsa.cpp / atariscom.cpp.
//
// Clocking: the board derives every clock from one 3.579545 MHz crystal. The
// 6502 runs at half the YM2151 rate, so its enable is made here by halving
// `cen_ym` rather than taken from a separate accumulator -- that keeps the CPU
// and the FM chip phase-locked exactly as the PCB does (the jt51 also wants
// its cen_p1 at half rate, which is the same signal).
//
// 6502 bus timing with T65: the core presents A/DO/R_W_n right after an Enable
// edge and samples DI on the next one, ~54 clocks later. Every memory and
// register read here is a registered lookup of the address, which is stable
// for that whole window; writes are performed on the Enable edge itself.
//
// Audio: `audio` is the signed 16-bit mono mix, recomputed on every YM2151
// clock (audio_valid strobes with it). Levels follow MAME's routing --
// YM2151 0.60 x (MIX volume 0..7)/7, OKI 0.75 x (1.0 or 0.5) gated by the
// YM2151's CT1 output, the whole board at 0.5 into the cabinet amp -- so the
// peak of the RTL and of MAME's -wavwrite land at the same place.
//------------------------------------------------------------------------------
`default_nettype none

module jsa2 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_ym,        // 3.579545 MHz enable (YM2151; the 6502 gets every other one)
    input  logic        cen_oki,       // 1.193181 MHz enable (OKI6295)
    input  logic        snd_reset,     // pulse: 68k read of 604000 resets the whole board

    // 68k command/response latch (byte on D15:8 of 600000)
    input  logic        cmd_wr,
    input  logic  [7:0] cmd_data,
    input  logic        resp_rd,
    output logic  [7:0] resp_data,
    output logic        main_irq,      // response latch full -> 68k IRQ4

    // inputs
    input  logic  [2:0] coins,         // active high; Stun Runner's coins are on the main board, these read 0
    input  logic        test,          // 1 = self-test switch on

    // program ROM load (64 KB into block RAM)
    input  logic        rom_we,
    input  logic [15:0] rom_waddr,
    input  logic  [7:0] rom_wdata,

    // ADPCM ROM (256 KB, served from SDRAM by the core)
    output logic [17:0] oki_addr,
    output logic        oki_req,       // level, held until oki_ack
    input  logic  [7:0] oki_data,
    input  logic        oki_ack,

    // mixed output
    output logic signed [15:0] audio,
    output logic        audio_valid,

    // bench observability: every write the 6502 makes to the YM2151 and to the I/O latches
    output logic        dbg_ym_wr,
    output logic        dbg_ym_a0,
    output logic  [7:0] dbg_ym_d,
    output logic        dbg_io_wr,
    output logic  [1:0] dbg_io_sel,    // 0 OKI, 1 WRP, 2 WRIO, 3 MIX
    output logic  [7:0] dbg_io_d,
    output logic        dbg_sync,      // 6502 opcode fetch
    output logic [15:0] dbg_addr
);

    // -------------------------------------------------------------------------
    // Clock enables and reset
    // -------------------------------------------------------------------------
    logic cpu_phase;
    always_ff @(posedge clk) begin
        if (reset) cpu_phase <= 1'b0;
        else if (cen_ym) cpu_phase <= ~cpu_phase;
    end
    wire cen_cpu = cen_ym & cpu_phase;

    // The 68k's sound reset (and the core reset) hold the board in reset for a
    // few CPU cycles so T65 sees a clean Res_n. MAME resets the JSA device and
    // all its children, so the latches, the FM and ADPCM chips and the volume
    // register go back to their power-up state too.
    //
    // The counter is loaded and decremented only on a cen_cpu tick. The 68k's
    // reset pulse arrives on an arbitrary clock, so it is latched in rst_pend
    // and applied at the next tick: board_rst then feeds jt51's reset, and that
    // cone (through the envelope generator's rate adder and comparators) is
    // 10.2 ns on its own -- one clock cannot hold it, and only a source that is
    // stable for a whole cen_cpu period (53 clocks) can be multicycled honestly.
    // The delay this adds is at most one 6502 cycle out of the fifteen the
    // reset is held for.
    logic [3:0] rst_cnt;
    logic       rst_pend;
    always_ff @(posedge clk) begin
        if (reset) begin
            rst_cnt <= 4'hf; rst_pend <= 1'b0;      // board_rst is high from the reset term itself
        end else if (cen_cpu) begin
            if (rst_pend || snd_reset)   rst_cnt <= 4'hf;
            else if (rst_cnt != 4'd0)    rst_cnt <= rst_cnt - 4'd1;
            rst_pend <= 1'b0;
        end else if (snd_reset) begin
            rst_pend <= 1'b1;
        end
    end
    wire board_rst = reset | (rst_cnt != 4'd0);


    // -------------------------------------------------------------------------
    // CPU
    // -------------------------------------------------------------------------
    wire [23:0] A24;
    wire [15:0] A = A24[15:0];
    wire  [7:0] cpu_do;
    wire        rw_n;
    wire        wr = ~rw_n;
    logic [7:0] cpu_di;
    logic       timed_int;
    wire        ym_irq_n;
    wire        irq = timed_int | ~ym_irq_n;
    logic       cmd_full;
    wire        sync;

    T65 u_cpu (
        .Mode    (2'b00),          // NMOS 6502
        .BCD_en  (1'b1),
        .Res_n   (~board_rst),
        .Enable  (cen_cpu),
        .Clk     (clk),
        .Rdy     (1'b1),
        .Abort_n (1'b1),
        .IRQ_n   (~irq),
        .NMI_n   (~cmd_full),
        .SO_n    (1'b1),
        .R_W_n   (rw_n),
        .Sync    (sync),
        .EF      (), .MF (), .XF (), .ML_n (), .VP_n (), .VDA (), .VPA (),
        .A       (A24),
        .DI      (cpu_di),
        .DO      (cpu_do),
        .Regs    (),
        .NMI_ack ()
    );
    assign dbg_sync = sync & cen_cpu;
    assign dbg_addr = A;

    // Not used on this board: the upper address bits (T65 is 24-bit capable),
    // WRIO bits 5:4 (coin counters) and 1 (JSA III OKI bank), the YM2151's
    // CT2 output and its sample strobe.
    wire unused_ok = &{1'b0, A24[23:16], wrio[5:4], wrio[1], ym_ct2, ym_sample};

    // -------------------------------------------------------------------------
    // Address decode (hardware.md §6.1)
    // -------------------------------------------------------------------------
    wire sel_ram  = (A[15:13] == 3'b000);        // 0000-1fff
    wire sel_ym   = (A[15:11] == 5'b00100);      // 2000-27ff
    wire sel_rd   = (A[15:9]  == 7'b0010100);    // 2800-29ff: reads, decoded on A2:1
    wire sel_wr   = (A[15:9]  == 7'b0010101);    // 2a00-2bff: writes, decoded on A2:1
    wire sel_bank = (A[15:12] == 4'h3);          // 3000-3fff banked ROM
    wire sel_rom  = (A[15:14] != 2'b00);         // 4000-ffff
    wire [1:0] io_sel = A[2:1];

    // -------------------------------------------------------------------------
    // RAM and ROM
    // -------------------------------------------------------------------------
    logic [7:0] ram [8192];
    logic [7:0] ram_q;
    always_ff @(posedge clk) begin
        if (cen_cpu && wr && sel_ram) ram[A[12:0]] <= cpu_do;
        ram_q <= ram[A[12:0]];
    end

    logic [1:0]  bank;
    logic [7:0]  rom [65536];
    logic [7:0]  rom_q;
    wire  [15:0] rom_a = sel_bank ? {2'b00, bank, A[11:0]} : A;
    always_ff @(posedge clk) begin
        if (rom_we) rom[rom_waddr] <= rom_wdata;
        rom_q <= rom[rom_a];
    end

    // -------------------------------------------------------------------------
    // 68k <-> 6502 latches (atariscom)
    // -------------------------------------------------------------------------
    logic [7:0] cmd_byte;
    logic       resp_full;
    logic [7:0] resp_byte;
    wire        rd_cmd  = cen_cpu && ~wr && sel_rd && io_sel == 2'd1;
    wire        wr_resp = cen_cpu &&  wr && sel_wr && io_sel == 2'd1;
    always_ff @(posedge clk) begin
        if (board_rst) begin
            cmd_full  <= 1'b0;
            cmd_byte  <= 8'h00;
            resp_full <= 1'b0;
            resp_byte <= 8'h00;
        end else begin
            if (cmd_wr) begin
                cmd_full <= 1'b1;
                cmd_byte <= cmd_data;
            end else if (rd_cmd) begin
                cmd_full <= 1'b0;
            end
            if (wr_resp) begin
                resp_full <= 1'b1;
                resp_byte <= cpu_do;
            end else if (resp_rd) begin
                resp_full <= 1'b0;
            end
        end
    end
    assign resp_data = resp_byte;
    assign main_irq  = resp_full;

    // -------------------------------------------------------------------------
    // Timed interrupt: 3.579545 MHz / 4 / 16 / 16 / 14 = 249.69 Hz, cleared by
    // any access to 2806.
    // -------------------------------------------------------------------------
    logic [13:0] tick;
    wire irq_ack = cen_cpu && sel_rd && io_sel == 2'd3;    // read or write
    always_ff @(posedge clk) begin
        if (board_rst) begin
            tick      <= '0;
            timed_int <= 1'b0;
        end else begin
            if (irq_ack) timed_int <= 1'b0;
            if (cen_ym) begin
                if (tick == 14'd14335) begin
                    tick      <= '0;
                    timed_int <= 1'b1;
                end else begin
                    tick <= tick + 14'd1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // /WRIO and /MIX latches
    // -------------------------------------------------------------------------
    logic [7:0] wrio;
    logic [2:0] ym_vol;
    logic       oki_vol;
    wire wr_io  = cen_cpu && wr && sel_wr && io_sel == 2'd2;
    wire wr_mix = cen_cpu && wr && sel_wr && io_sel == 2'd3;
    always_ff @(posedge clk) begin
        if (board_rst) begin
            wrio    <= 8'h00;          // bank 0, YM and OKI held in reset until the program releases them
            ym_vol  <= 3'd7;           // MAME: volume 1.0 after reset
            oki_vol <= 1'b1;
        end else begin
            if (wr_io)  wrio <= cpu_do;
            if (wr_mix) begin
                ym_vol  <= cpu_do[3:1];
                oki_vol <= cpu_do[0];
                // bit 5 (low-pass filter) is not modelled, as in MAME
            end
        end
    end
    assign bank = wrio[7:6];

    // The two sound chips get their reset through a register of their own.
    // board_rst comes from the core reset synchroniser, which sits at the other
    // end of the die, and jt51's rst is not a plain register clear -- it reaches
    // into the envelope generator's rate adder and comparators and the phase
    // generator, about 8 ns of logic. Driven straight from board_rst the whole
    // thing was one 10.7 ns clock. Registered here, Quartus can place (and
    // duplicate) the driver next to the chip it resets. One clock of extra
    // reset latency out of the ~800 the reset is held for.
    logic ym_rst, oki_rst;
    always_ff @(posedge clk) begin
        ym_rst  <= board_rst | ~wrio[0];
        oki_rst <= board_rst | ~wrio[2];
    end

    // -------------------------------------------------------------------------
    // YM2151
    // -------------------------------------------------------------------------
    // The write strobe is held for the whole CPU cycle (until the next
    // cen_cpu), not pulsed for one clk: jt51 registers the write on every
    // clock but only samples it for its BUSY flag on its own enable, and the
    // 6502 program polls BUSY between writes. A one-clock pulse that misses
    // that enable makes the chip look never-busy and the driver runs one poll
    // iteration (~7 us) faster per write than MAME -- enough to shift the
    // music's timed-interrupt ticks.
    logic       ym_wr_p;
    logic       ym_a0_p;
    logic [7:0] ym_d_p;
    always_ff @(posedge clk) begin
        if (board_rst)   ym_wr_p <= 1'b0;
        else if (cen_cpu) begin
            ym_wr_p <= wr && sel_ym;
            ym_a0_p <= A[0];
            ym_d_p  <= cpu_do;
        end
    end
    always_ff @(posedge clk) dbg_ym_wr <= cen_cpu && wr && sel_ym;
    assign dbg_ym_a0 = ym_a0_p;
    assign dbg_ym_d  = ym_d_p;

    wire  [7:0] ym_dout;
    wire        ym_ct1, ym_ct2;
    wire signed [15:0] ym_l, ym_r;
    wire        ym_sample;

    jt51 u_ym (
        .rst    (ym_rst),
        .clk    (clk),
        .cen    (cen_ym),
        .cen_p1 (cen_cpu),
        .cs_n   (~ym_wr_p),
        .wr_n   (~ym_wr_p),
        .a0     (ym_a0_p),
        .din    (ym_d_p),
        .dout   (ym_dout),
        .ct1    (ym_ct1),
        .ct2    (ym_ct2),
        .irq_n  (ym_irq_n),
        .sample (ym_sample),
        .left   (),
        .right  (),
        .xleft  (ym_l),
        .xright (ym_r)
    );

    // -------------------------------------------------------------------------
    // OKI6295
    // -------------------------------------------------------------------------
    logic       oki_wr_p;
    logic [7:0] oki_d_p;
    always_ff @(posedge clk) begin
        oki_wr_p <= cen_cpu && wr && sel_wr && io_sel == 2'd0;
        oki_d_p  <= cpu_do;
    end

    wire  [7:0] oki_dout;
    wire [17:0] oki_rom_addr;
    logic [7:0] oki_rom_data;
    logic       oki_rom_ok;
    wire signed [13:0] oki_snd;

    jt6295 #(.INTERPOL(0), .SAMPLE(0)) u_oki (
        .rst      (oki_rst),
        .clk      (clk),
        .cen      (cen_oki),
        .ss       (wrio[3]),
        .wrn      (~oki_wr_p),
        .din      (oki_d_p),
        .dout     (oki_dout),
        .rom_addr (oki_rom_addr),
        .rom_data (oki_rom_data),
        .rom_ok   (oki_rom_ok),
        .sound    (oki_snd),
        .sample   ()
    );

    // ROM handshake: jt6295 expects rom_ok to drop within a clock of a new
    // address and to rise once rom_data is valid for that address.
    logic [17:0] oki_cur;
    always_ff @(posedge clk) begin
        if (board_rst) begin
            oki_req    <= 1'b0;
            oki_rom_ok <= 1'b0;
            oki_cur    <= '0;
            oki_addr   <= '0;
            oki_rom_data <= 8'h00;
        end else if (oki_req) begin
            if (oki_ack) begin
                oki_req      <= 1'b0;
                oki_rom_data <= oki_data;
                oki_rom_ok   <= 1'b1;
            end
        end else if (oki_rom_addr != oki_cur || !oki_rom_ok) begin
            oki_cur    <= oki_rom_addr;
            oki_addr   <= oki_rom_addr;
            oki_req    <= 1'b1;
            oki_rom_ok <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // I/O port and CPU read mux
    // -------------------------------------------------------------------------
    // 2804: bit7 self test, bit6 low while a command is waiting, bit5 response
    // latch full, bits 2:0 coins.
    wire [7:0] rdio = {test, ~cmd_full, resp_full, 2'b00, coins};

    always_comb begin
        if      (sel_rom || sel_bank) cpu_di = rom_q;
        else if (sel_ram)             cpu_di = ram_q;
        else if (sel_ym)              cpu_di = ym_dout;
        else if (sel_rd) begin
            case (io_sel)
                2'd0: cpu_di = oki_dout;
                2'd1: cpu_di = cmd_byte;
                2'd2: cpu_di = rdio;
                default: cpu_di = 8'h00;
            endcase
        end
        else                          cpu_di = 8'hff;
    end

    // bench: I/O latch writes
    always_ff @(posedge clk) begin
        dbg_io_wr  <= cen_cpu && wr && sel_wr;
        dbg_io_sel <= io_sel;
        dbg_io_d   <= cpu_do;
    end

    // -------------------------------------------------------------------------
    // Mixer (see header). Fixed point:
    //   ym_term  = (L + R) * ym_vol * 0.3/7      -> * ym_vol * 1404 >> 15
    //   oki_term = (oki14 << 4) * 0.375 * okivol -> oki14 * 6 (or * 3), gated by CT1
    // -------------------------------------------------------------------------
    logic signed [16:0] ym_sum;
    logic signed [30:0] ym_prod;
    logic signed [17:0] oki_term;
    logic signed [18:0] mix;
    // One extra pipeline slot per stage: the volume multiply
    // (ym_sum * ym_vol * 1404) is a 17x3x31 cone, 12 ns at 96 MHz, and
    // capturing it on the clock right after cen_ym gave it one. cen_ym is 26.8
    // clocks apart, so spending four of them costs nothing.
    logic [3:0] mix_ph;
    always_ff @(posedge clk) begin
        if (board_rst) begin
            ym_sum   <= '0;
            ym_prod  <= '0;
            oki_term <= '0;
            mix      <= '0;
            audio    <= '0;
            audio_valid <= 1'b0;
            mix_ph   <= '0;
        end else begin
            audio_valid <= 1'b0;
            mix_ph <= {mix_ph[2:0], cen_ym};
            if (cen_ym) begin
                ym_sum   <= 17'(ym_l) + 17'(ym_r);
                oki_term <= ym_ct1 ? (oki_vol ? 18'(oki_snd) * 18'sd6 : 18'(oki_snd) * 18'sd3) : 18'sd0;
            end
            if (mix_ph[1]) begin
                ym_prod <= ym_sum * $signed({1'b0, ym_vol}) * 31'sd1404;
            end
            if (mix_ph[3]) begin
                mix <= 19'(ym_prod >>> 15) + 19'(oki_term);
                audio_valid <= 1'b1;
            end
            if (audio_valid) begin
                audio <= (mix > 19'sd32767)  ? 16'sh7fff :
                         (mix < -19'sd32768) ? 16'sh8000 : 16'(mix);
            end
        end
    end

endmodule

`default_nettype wire
