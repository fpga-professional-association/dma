//============================================================================
// reset_sync.sv -- Optional reset synchronizer (async assert, sync deassert)
//
// Productizes the "Reset" integration note in docs/architecture.md. The
// reference core consumes rst_n directly at the flops (async assert, sync
// deassert assumed). In a real, possibly multi-domain system, drive each clock
// domain's rst_n through one of these per domain so that reset *deassertion* is
// synchronized to that clock: reset removal/recovery then becomes a normal
// timed path inside the clk domain, while the raw asynchronous assertion stays
// a false path (see quartus/pcie_dma.sdc set_false_path -from rst_n, which
// correctly covers the asynchronous input to the first synchronizer flop).
//
// pcie_dma_top instantiates this only when RESET_SYNC=1; the default keeps the
// historical direct-rst_n datapath bit-for-bit unchanged.
//
// Standalone (no package import) so it gate-maps directly under yosys and lints
// under Verilator -Wall.
//============================================================================

module reset_sync #(
  parameter int unsigned STAGES = 2          // synchronizer depth (must be >= 2)
) (
  input  logic clk,
  input  logic arst_n,                       // raw asynchronous active-low reset in
  output logic rst_n                         // async-asserted, clk-sync-deasserted out
);

  // Synthesis hint to keep the chain intact / placed together on real silicon;
  // ignored by the open-source lint/synth flows used in CI.
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n) begin
    if (!arst_n) sync_q <= '0;                          // async assert -> all zero
    else         sync_q <= {sync_q[STAGES-2:0], 1'b1};  // shift in 1s (sync deassert)
  end

  assign rst_n = sync_q[STAGES-1];

endmodule
