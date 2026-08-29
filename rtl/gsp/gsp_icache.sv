//------------------------------------------------------------------------------
// TMS34010 instruction cache: 1024 x 16-bit words, direct mapped, one word
// per line. Tag = word address bits [27:10] (VRAM lives at 0xff800000 and the
// mirror at 0xffc00000; word address = bit address >> 4, so the top four bits
// of the bit address are always 0xf on this board and are not stored).
//
// Both the data and the tag/valid array live in block RAM (the valid bit is
// stored with the tag, and a line is valid only when its generation number
// equals the current one: `flush` just bumps the generation; when it wraps a
// 1024-cycle sweep rewrites every line as invalid, during which lookups miss
// and fills are dropped).
//
// Lookup is two cycles: present `lu_addr` with `lu_en`, read `hit`/`data`
// the cycle after. Fills write one word. Any write to memory (GSP or host)
// invalidates the line at that index regardless of tag.
//------------------------------------------------------------------------------
`default_nettype none

module gsp_icache (
    input  logic        clk,
    input  logic        reset,
    input  logic        flush,
    // lookup
    input  logic        lu_en,
    input  logic [27:0] lu_addr,      // word address (bit address >> 4)
    output logic        hit,          // valid the cycle after lu_en
    output logic [15:0] data,
    // fill
    input  logic        fill_en,
    input  logic [27:0] fill_addr,
    input  logic [15:0] fill_data,
    // invalidate (memory write)
    input  logic        inv_en,
    input  logic [27:0] inv_addr
);
    (* ramstyle = "no_rw_check" *) logic [15:0] mem_data [0:1023];
    (* ramstyle = "no_rw_check" *) logic [26:0] mem_tag  [0:1023];     // {valid, gen[7:0], tag[17:0]}

    logic [7:0]  gen;
    logic        sweep;
    logic [9:0]  sweep_idx;

    logic [26:0] rd_tag;
    logic [15:0] rd_data;
    logic [17:0] rd_want;
    logic        rd_ok;

    // tag write port: sweep > invalidate > fill
    logic        tw_en;
    logic [9:0]  tw_idx;
    logic [26:0] tw_val;
    always_comb begin
        tw_en = 1'b0; tw_idx = fill_addr[9:0]; tw_val = {1'b1, gen, fill_addr[27:10]};
        if (sweep)        begin tw_en = 1'b1; tw_idx = sweep_idx;        tw_val = 27'd0; end
        else if (inv_en)  begin tw_en = 1'b1; tw_idx = inv_addr[9:0];    tw_val = 27'd0; end
        else if (fill_en) begin tw_en = 1'b1; end
    end

    always_ff @(posedge clk) begin
        rd_tag  <= mem_tag[lu_addr[9:0]];
        rd_data <= mem_data[lu_addr[9:0]];
        rd_want <= lu_addr[27:10];
        rd_ok   <= !(reset || sweep);
    end
    always_ff @(posedge clk) begin
        if (tw_en) mem_tag[tw_idx] <= tw_val;
        if (fill_en && !sweep) mem_data[fill_addr[9:0]] <= fill_data;
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            gen <= 8'd1;
            sweep <= 1'b1;             // clear everything after reset
            sweep_idx <= 10'd0;
        end else if (sweep) begin
            sweep_idx <= sweep_idx + 10'd1;
            if (sweep_idx == 10'd1023) sweep <= 1'b0;
        end else if (flush) begin
            gen <= gen + 8'd1;
            if (gen == 8'd255) begin sweep <= 1'b1; sweep_idx <= 10'd0; end
        end
    end

    assign hit  = rd_ok && rd_tag[26] && (rd_tag[25:18] == gen) && (rd_tag[17:0] == rd_want);
    assign data = rd_data;

    logic unused_lu_en;
    assign unused_lu_en = lu_en;
endmodule
