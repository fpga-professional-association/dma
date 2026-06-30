//============================================================================
// fv_ahb_abort.sv -- Formal proof of the opt-in AHB-Lite ERROR burst-cancel
//
// Same portable yosys-formal style and well-behaved-GMM environment as
// fv_ahb.sv, but the DUT is instantiated with EARLY_ABORT=1. A spec-legal
// two-cycle AHB-Lite ERROR response is MODELLED as assumed slave behaviour
// (first cycle HRESP=ERROR/HREADY=0, second cycle HRESP=ERROR/HREADY=1) and the
// adapter's *cancellation* is proven:
//   * the address phase pending across the ERROR is dropped to HTRANS=IDLE on
//     the completing (HREADY-high) error cycle  (the following transfer is
//     cancelled rather than continued),
//   * control is held stable across an ordinary wait state and is only allowed
//     to change to IDLE the cycle after the ERROR (legal HTRANS sequencing),
//   * the sticky `err` flag is still raised.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/ahb_abort.sby)
//============================================================================

module fv_ahb_abort #(
  parameter int unsigned AW = 8,
  parameter int unsigned DW = 16
) (
  input logic            clk,
  input logic            rst_n,
  // free GMM stimulus
  input logic [AW-1:0]   gmm_address,
  input logic            gmm_read,
  input logic            gmm_write,
  input logic [DW-1:0]   gmm_writedata,
  input logic [DW/8-1:0] gmm_byteenable,
  input logic [dma_pkg::BCW-1:0] gmm_burstcount,
  // free AHB slave responses
  input logic [DW-1:0]   hrdata,
  input logic            hready,
  input logic            hresp
);
  localparam int unsigned BCW  = dma_pkg::BCW;
  localparam int unsigned MAXB = dma_pkg::MAX_BURST_BEATS;
  localparam int STRIDE = DW/8;
  localparam logic [1:0] HT_IDLE=2'b00, HT_BUSY=2'b01, HT_NONSEQ=2'b10, HT_SEQ=2'b11;
  localparam logic [2:0] HSZ = 3'($clog2(DW/8));

  logic            gmm_waitrequest, gmm_readdatavalid;
  logic [DW-1:0]   gmm_readdata;
  logic [AW-1:0]   haddr;
  logic [2:0]      hburst, hsize;
  logic [1:0]      htrans;
  logic            hwrite, err;
  logic [DW-1:0]   hwdata;
  wire clr = 1'b0;   // abort exercised by simulation, not this proof

  gmm_to_ahb #(.AW(AW), .DW(DW), .BCW(BCW), .EARLY_ABORT(1'b1)) dut (.*);

  wire active = (htrans == HT_NONSEQ) || (htrans == HT_SEQ);

  // Port-only mirror of the adapter's single AHB-Lite data phase (a hierarchical
  // ref to DUT internals does not resolve in this yosys flow). A data phase is in
  // flight the cycle after an accepted active address phase, extended while
  // HREADY is low -- exactly the AHB address/data pipeline the adapter implements.
  logic dp;
  always @(posedge clk) begin
    if (!rst_n)      dp <= 1'b0;
    else if (hready) dp <= active;
  end
  // completing (HREADY-high) cycle of a two-cycle ERROR response
  wire dp_err_complete = dp && hready && hresp;

  // formal reset model
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  logic past_ok = 1'b0; always @(posedge clk) past_ok <= rst_n;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  always @(posedge clk) if (rst_n) begin
    // ---------- environment: well-behaved GMM master ----------
    assume (!(gmm_read && gmm_write));
    assume (gmm_burstcount >= 1 && gmm_burstcount <= MAXB);
    if (past_ok && $past((gmm_read||gmm_write) && gmm_waitrequest)) begin
      assume (gmm_address    == $past(gmm_address));
      assume (gmm_burstcount == $past(gmm_burstcount));
      assume (gmm_read       == $past(gmm_read));
      assume (gmm_write      == $past(gmm_write));
      assume (gmm_writedata  == $past(gmm_writedata));
    end

    // ---------- environment: spec-legal two-cycle ERROR response -------------
    if (hresp) assume (dp);                                    // only during a data phase
    if (past_ok) begin
      if (hresp && !$past(hresp))               assume (!hready);          // first cycle
      if ($past(hresp) && !$past(hready)) begin assume (hresp); assume (hready); end // 2nd
      if ($past(hresp) && $past(hready))        assume (!hresp);           // exactly two
    end

    // ---------- AHB-Lite compliance ----------
    assert (htrans != HT_BUSY);
    if (active) begin
      assert (hburst == 3'b001);
      assert (hsize  == HSZ);
    end

    // control held stable while waited -- EXCEPT the master may cancel the
    // pending transfer to IDLE the cycle after an ERROR (legal AHB behaviour)
    if (past_ok && $past(active && !hready)) begin
      if ($past(hresp)) begin
        assert (htrans == HT_IDLE);                            // ERROR -> cancel
      end else begin
        assert (htrans == $past(htrans));                     // ordinary wait -> hold
        assert (haddr  == $past(haddr));
        assert (hwrite == $past(hwrite));
        assert (hsize  == $past(hsize));
        assert (hburst == $past(hburst));
      end
    end

    // a SEQ beat must follow an active address phase
    if (past_ok && (htrans == HT_SEQ))
      assert ($past(active));

    // address increments by the bus width on each accepted active beat
    if (past_ok && (htrans == HT_SEQ) && $past(active && hready))
      assert (haddr == AW'($past(haddr) + STRIDE));

    // a read-data beat only when a data phase completes
    if (gmm_readdatavalid) assert (hready);

    // ---------- burst-cancel on ERROR ----------
    // the address phase pending across the ERROR is dropped: on the completing
    // (HREADY-high) error cycle the adapter presents HTRANS=IDLE, cancelling the
    // following transfer instead of continuing the burst with SEQ.
    if (dp_err_complete) assert (htrans == HT_IDLE);
    // the sticky engine error is still raised after the ERROR response
    if (past_ok && $past(dp_err_complete)) assert (err);
    if (past_ok && $past(err))             assert (err);
  end
endmodule
