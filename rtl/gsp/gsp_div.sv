//------------------------------------------------------------------------------
// Sequential 64/32 unsigned divider for the TMS34010 DIVS/DIVU/MODS/MODU
// instructions. Restoring division, one quotient bit per clock (64 clocks).
// The core handles signs and overflow around it.
//
// start: latch {num_hi,num_lo} / den. done pulses with quo/rem valid.
//------------------------------------------------------------------------------
`default_nettype none

module gsp_div (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [63:0] num,
    input  logic [31:0] den,
    output logic        done,
    output logic [63:0] quo,
    output logic [31:0] rem
);
    logic        busy;
    logic [6:0]  cnt;
    logic [63:0] q;
    logic [64:0] r;      // remainder accumulator (one extra bit)
    logic [64:0] rshift;
    logic [64:0] rsub;

    assign rshift = {r[63:0], q[63]};
    assign rsub   = rshift - {33'd0, den};

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            busy <= 1'b0;
            cnt  <= '0;
        end else if (start) begin
            busy <= 1'b1;
            cnt  <= 7'd64;
            q    <= num;
            r    <= '0;
        end else if (busy) begin
            if (rsub[64]) begin          // negative: keep
                r <= rshift;
                q <= {q[62:0], 1'b0};
            end else begin
                r <= rsub;
                q <= {q[62:0], 1'b1};
            end
            cnt <= cnt - 7'd1;
            if (cnt == 7'd1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

    assign quo = q;
    assign rem = r[31:0];
endmodule
