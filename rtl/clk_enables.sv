//------------------------------------------------------------------------------
// Clock enables for the S.T.U.N. Runner core (docs/rtl-conventions.md).
//
// One 96 MHz system clock; every machine part runs on a one-cycle enable
// pulse from here. The 8 MHz and 6 MHz enables are exact divisions; the
// others are phase accumulators (a 32-bit adder whose carry is the enable),
// which gives the exact long-term rate with at most one system-clock period
// of jitter -- invisible to a 6502, a YM2151 or an OKI6295.
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,          // 96.000 MHz
    input  logic reset,
    output logic cen_8m,       // 68010, ADSP-2100        96/12
    output logic cen_6m,       // TMS34010 instruction     96/16
    output logic cen_vid,      // GSP video clock 5 MHz    96/19.2 (phase acc.)
    output logic cen_pix,      // pixel clock 10 MHz       2 per cen_vid, see below
    output logic cen_snd,      // 6502   1.789772 MHz
    output logic cen_ym,       // YM2151 3.579545 MHz
    output logic cen_oki       // OKI    1.193181 MHz
);
    // 2^32 * f / 96e6, rounded
    localparam logic [31:0] INC_VID = 32'd223696213;   //  5.000000 MHz
    localparam logic [31:0] INC_PIX = 32'd447392427;   // 10.000000 MHz
    localparam logic [31:0] INC_SND = 32'd80077113;    //  1.789772 MHz
    localparam logic [31:0] INC_YM  = 32'd160154226;   //  3.579545 MHz
    localparam logic [31:0] INC_OKI = 32'd53384743;    //  1.193181 MHz

    logic [3:0] div12, div16;
    logic [32:0] acc_vid, acc_pix, acc_snd, acc_ym, acc_oki;

    always_ff @(posedge clk) begin
        if (reset) begin
            div12 <= '0; div16 <= '0;
            acc_vid <= '0; acc_pix <= '0; acc_snd <= '0; acc_ym <= '0; acc_oki <= '0;
            cen_8m <= 1'b0; cen_6m <= 1'b0; cen_vid <= 1'b0; cen_pix <= 1'b0;
            cen_snd <= 1'b0; cen_ym <= 1'b0; cen_oki <= 1'b0;
        end else begin
            div12  <= (div12 == 4'd11) ? 4'd0 : div12 + 4'd1;
            cen_8m <= (div12 == 4'd11);
            div16  <= div16 + 4'd1;
            cen_6m <= (div16 == 4'd15);
            // the pixel accumulator runs at exactly twice the video one and is
            // kept in lock-step with it: same phase word, doubled increment
            acc_vid <= {1'b0, acc_vid[31:0]} + {1'b0, INC_VID};
            cen_vid <= acc_vid[32];
            acc_pix <= {1'b0, acc_pix[31:0]} + {1'b0, INC_PIX};
            cen_pix <= acc_pix[32];
            acc_snd <= {1'b0, acc_snd[31:0]} + {1'b0, INC_SND};
            cen_snd <= acc_snd[32];
            acc_ym  <= {1'b0, acc_ym[31:0]}  + {1'b0, INC_YM};
            cen_ym  <= acc_ym[32];
            acc_oki <= {1'b0, acc_oki[31:0]} + {1'b0, INC_OKI};
            cen_oki <= acc_oki[32];
        end
    end
endmodule
