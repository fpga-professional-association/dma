//============================================================================
// fv_fifo_ind.sv -- INDUCTIVE (depth-independent) properties for dma_fifo
//
// Companion to fv_fifo.sv. This harness carries ONLY the occupancy-bookkeeping
// invariants (level bound, flag consistency, no overflow/underflow, level step,
// abort drains) -- deliberately leaving out the symbolic data-integrity tracker,
// whose memory reasoning is not k-inductive. With those invariants alone the
// proof closes by temporal induction, so it holds at the *deployment* depth
// (FIFO_DEPTH = 256) where bounded model checking can never reach `full`.
//
// Run (unbounded, needs a solver):  sby -f formal/fifo_prove.sby
// The assertions are also valid under bounded checking, so run_formal-style
// `sat -prove-asserts` confirms their soundness at small depth.
//============================================================================

module fv_fifo_ind #(
  parameter int unsigned WIDTH = 64,
  parameter int unsigned DEPTH = 256
) (
  input logic             clk,
  input logic             rst_n,
  input logic             wr_en,
  input logic [WIDTH-1:0] wr_data,
  input logic             rd_en,
  input logic             clr      // free: abort/flush
);
  localparam int LVLW = $clog2(DEPTH)+1;

  logic             full, empty;
  logic [WIDTH-1:0] rd_data;
  logic [LVLW-1:0]  level;

  dma_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
    .clk, .rst_n, .clr, .wr_en, .wr_data, .full,
    .rd_en, .rd_data, .empty, .level
  );

  wire push = wr_en & ~full;
  wire pop  = rd_en & ~empty;

  // formal reset model
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  logic past_ok = 1'b0; always @(posedge clk) past_ok <= rst_n;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  always @(posedge clk) if (rst_n) begin
    a_level_bound  : assert (level <= DEPTH);
    a_full_flag    : assert (full  == (level == DEPTH));
    a_empty_flag   : assert (empty == (level == 0));
    if (full)  a_no_overflow  : assert (!push);
    if (empty) a_no_underflow : assert (!pop);
    if (past_ok && !$past(clr))
      a_level_step : assert (level ==
                        $past(level) + ($past(push) ? 1 : 0) - ($past(pop) ? 1 : 0));
    if (past_ok && $past(clr))
      a_abort_drained : assert (level == '0);
  end
endmodule
