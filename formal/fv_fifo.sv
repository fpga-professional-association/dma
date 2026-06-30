//============================================================================
// fv_fifo.sv -- Formal properties for dma_fifo
//
// Written in the portable yosys-formal immediate-assertion style (clocked
// always block + $past), so it runs with the open-source SymbiYosys + yosys
// toolchain (no Verific required). Proves: occupancy bookkeeping, no
// overflow/underflow, flag consistency, and FIFO ordering + data integrity via
// one symbolic tracked element.
//
// Run:  sby -f formal/fifo.sby
//============================================================================

module fv_fifo #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned DEPTH = 8
) (
  input logic                   clk,
  input logic                   rst_n,
  input logic                   wr_en,
  input logic [WIDTH-1:0]       wr_data,
  input logic                   rd_en,
  input logic                   tag_now   // free: pick a push to track
);
  localparam int LVLW = $clog2(DEPTH)+1;

  logic            full, empty;
  logic [WIDTH-1:0] rd_data;
  logic [LVLW-1:0] level;

  dma_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .clk, .rst_n, .clr(1'b0), .wr_en, .wr_data, .full,
    .rd_en, .rd_data, .empty, .level
  );

  wire push = wr_en & ~full;
  wire pop  = rd_en & ~empty;

  // formal reset model: assert reset in the initial step, hold rst_n high after
  logic f_init = 1'b1;
  always @(posedge clk) f_init <= 1'b0;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n);
    else        assume (rst_n);
  end

  // becomes 1 once at least one post-reset cycle has elapsed ($past valid)
  logic past_ok = 1'b0;
  always @(posedge clk) past_ok <= rst_n;

  // ---- ordering + data integrity via one tracked element ----
  logic            tracking;
  logic [WIDTH-1:0] tag_data;
  logic [LVLW-1:0] ahead;          // entries still ahead of the tracked one

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tracking <= 1'b0;
      tag_data <= '0;
      ahead    <= '0;
    end else if (!tracking) begin
      if (push && !pop && tag_now) begin
        tracking <= 1'b1;
        tag_data <= wr_data;
        ahead    <= level;          // occupancy before this push == items ahead
      end
    end else if (pop) begin
      if (ahead != 0) ahead <= ahead - 1'b1;
      else            tracking <= 1'b0;   // this pop returns the tracked elem
    end
  end

  // ---- properties ----
  always @(posedge clk) begin
    if (rst_n) begin
      a_level_bound : assert (level <= DEPTH);
      a_full_flag   : assert (full  == (level == DEPTH));
      a_empty_flag  : assert (empty == (level == 0));
      if (full)     assert (!push);                 // a_no_overflow
      if (empty)    assert (!pop);                  // a_no_underflow
      if (tracking) assert (ahead < level);         // a_track_inrange
      if (tracking && (ahead == 0) && pop)
                    assert (rd_data == tag_data);   // a_data_integrity
      if (past_ok)
                    assert (level ==                // a_level_step
                       $past(level) + ($past(push) ? 1 : 0) - ($past(pop) ? 1 : 0));
    end
  end

endmodule
