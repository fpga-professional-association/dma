// SPDX-License-Identifier: Apache-2.0
//============================================================================
// fv_ahb.sv -- Formal AHB-Lite-compliance properties for gmm_to_ahb
//
// Portable yosys-formal immediate-assertion style. Environment: a well-behaved
// GMM master. The adapter's AHB-Lite outputs are proven compliant: legal HTRANS
// sequencing, INCR bursts, control held stable across wait states, address
// incrementing by the bus width.
//
// This harness drives the DUT in its default (drain) mode (EARLY_ABORT=0) and
// additionally MODELS a spec-legal two-cycle AHB-Lite ERROR response from the
// slave (first cycle HRESP=ERROR/HREADY=0, second cycle HRESP=ERROR/HREADY=1)
// and proves the adapter reacts legally: control is held stable across the
// HREADY-low error cycle and the sticky `err` flag is raised. The opt-in
// burst-cancel (EARLY_ABORT=1) is proven separately in formal/fv_ahb_abort.sv.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/ahb.sby)
//============================================================================

module fv_ahb #(
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
  input logic            hresp,
  // free abort input (issue #7: abort / error-clear coverage)
  input logic            clr
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

  gmm_to_ahb #(.AW(AW), .DW(DW), .BCW(BCW)) dut (.*);

  wire active = (htrans == HT_NONSEQ) || (htrans == HT_SEQ);

  // Port-only mirror of the adapter's single AHB-Lite data phase (a hierarchical
  // ref to DUT internals does not resolve in this yosys flow). A data phase is in
  // flight the cycle after an accepted active address phase, and is extended while
  // HREADY is low -- exactly the AHB address/data pipeline the adapter implements.
  logic dp;   // a data phase is in flight this cycle
  always @(posedge clk) begin
    if (!rst_n)      dp <= 1'b0;
    else if (hready) dp <= active;   // accepted addr phase -> next-cycle data phase
  end
  // completing (HREADY-high) cycle of a two-cycle ERROR response
  wire dp_err_complete = dp && hready && hresp;

  // ---- cover witnesses (issue #7: rule out vacuous passes) ----
  (* keep *) wire cov_rd_seq  = !hwrite && (htrans == HT_SEQ); // read burst NONSEQ->SEQ chain
  (* keep *) wire cov_wr_seq  =  hwrite && (htrans == HT_SEQ); // write burst NONSEQ->SEQ chain
  (* keep *) wire cov_rdvalid = gmm_readdatavalid;            // a read data phase completes
  (* keep *) wire cov_err     = err;                          // error path is reachable

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
    if (dut.st == 2'd2 /*H_WRITE*/) assume (gmm_write);   // master holds write across the burst
    if (past_ok && $past((gmm_read||gmm_write) && gmm_waitrequest)) begin
      assume (gmm_address    == $past(gmm_address));
      assume (gmm_burstcount == $past(gmm_burstcount));
      assume (gmm_read       == $past(gmm_read));
      assume (gmm_write      == $past(gmm_write));
      assume (gmm_writedata  == $past(gmm_writedata));
    end

    // ---------- environment: spec-legal two-cycle ERROR response -------------
    // ERROR is only signalled while a data phase is in flight.
    if (hresp) assume (dp);
    if (past_ok) begin
      // first ERROR cycle (HRESP rises) extends the data phase: HREADY=0
      if (hresp && !$past(hresp))               assume (!hready);
      // the response completes the next cycle: HRESP held, HREADY=1
      if ($past(hresp) && !$past(hready)) begin assume (hresp); assume (hready); end
      // ERROR lasts exactly two cycles: drop HRESP after the completing cycle
      if ($past(hresp) && $past(hready))        assume (!hresp);
    end

    // ---------- AHB-Lite compliance ----------
    assert (htrans != HT_BUSY);                              // adapter never issues BUSY
    if (active) begin
      assert (hburst == 3'b001);                             // INCR
      assert (hsize  == HSZ);
    end

    // control held stable while the slave is not ready (AHB requirement)
    if (past_ok && $past(active && !hready)) begin
      assert (htrans == $past(htrans));
      assert (haddr  == $past(haddr));
      assert (hwrite == $past(hwrite));
      assert (hsize  == $past(hsize));
      assert (hburst == $past(hburst));
    end

    // a SEQ beat must follow an active address phase (held across wait states)
    if (past_ok && (htrans == HT_SEQ))
      assert ($past(active));

    // address increments by the bus width on each accepted active beat
    // (AW-width arithmetic so it wraps the same way as the DUT)
    if (past_ok && (htrans == HT_SEQ) && $past(active && hready))
      assert (haddr == AW'($past(haddr) + STRIDE));

    // a read-data beat only when a data phase completes
    if (gmm_readdatavalid) assert (hready);

    // ---------- reaction to the modelled two-cycle ERROR (issue #11) ----------
    // (control held stable across the HREADY-low error cycle is covered by the
    //  "control held stable while the slave is not ready" assertion above.)
    // the sticky engine error is raised the cycle after a completed ERROR phase
    // (unless an abort intervened -- clr is now a free input, issue #7).
    if (past_ok && !$past(clr) && $past(dp_err_complete)) assert (err);

    // ---------- sticky bus-error behaviour (issue #7), proven from observable ------
    // ---------- signals only: HRESP=1 on a ready data beat sets err; abort clears --
    if (past_ok && $past(clr))                        a_err_clr    : assert (!err);
    if (past_ok && !$past(clr) && $past(err))         a_err_sticky : assert (err);
    // err only ever rises after a non-OKAY response on a ready cycle
    if (past_ok && !$past(clr) && !$past(err) && err)
                                                      a_err_cause  : assert ($past(hready) && $past(hresp));
    // a read data beat completing with HRESP=ERROR must raise err
    if (past_ok && !$past(clr) && $past(gmm_readdatavalid) && $past(hresp))
                                                      a_err_rdset  : assert (err);

    // ---------- cover witnesses (reachability checked by run_formal.sh / sby) -------
    c_rd_seq  : cover (cov_rd_seq);
    c_wr_seq  : cover (cov_wr_seq);
    c_rdvalid : cover (cov_rdvalid);
    c_err     : cover (cov_err);
  end
endmodule
