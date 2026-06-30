//============================================================================
// fv_ahb.sv -- Formal AHB-Lite-compliance properties for gmm_to_ahb
//
// Portable yosys-formal immediate-assertion style. Environment: a well-behaved
// GMM master. The adapter's AHB-Lite outputs are proven compliant: legal HTRANS
// sequencing, INCR bursts, control held stable across wait states, address
// incrementing by the bus width.
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
