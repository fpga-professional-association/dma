// SPDX-License-Identifier: Apache-2.0
//============================================================================
// fv_axi4.sv -- Formal AXI4-compliance properties for gmm_to_axi4
//
// Portable yosys-formal immediate-assertion style (clocked always + $past),
// provable with open-source yosys+SAT or SymbiYosys. Environment: a well-behaved
// GMM master; the adapter's AXI4 master outputs are proven compliant.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/axi4.sby)
//============================================================================

module fv_axi4 #(
  parameter int unsigned AW = 8,        // small for tractable BMC (proof is width-agnostic)
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
  // free AXI slave responses
  input logic            axi_awready,
  input logic            axi_wready,
  input logic [0:0]      axi_bid,
  input logic [1:0]      axi_bresp,
  input logic            axi_bvalid,
  input logic            axi_arready,
  input logic [0:0]      axi_rid,
  input logic [DW-1:0]   axi_rdata,
  input logic [1:0]      axi_rresp,
  input logic            axi_rlast,
  input logic            axi_rvalid
);
  localparam int unsigned BCW = dma_pkg::BCW;
  localparam int unsigned MAXB = dma_pkg::MAX_BURST_BEATS;
  localparam logic [2:0]  SZ = 3'($clog2(DW/8));

  // adapter outputs
  logic            gmm_waitrequest, gmm_readdatavalid;
  logic [DW-1:0]   gmm_readdata;
  logic [0:0]      axi_awid, axi_arid;
  logic [AW-1:0]   axi_awaddr, axi_araddr;
  logic [7:0]      axi_awlen, axi_arlen;
  logic [2:0]      axi_awsize, axi_arsize, axi_awprot, axi_arprot;
  logic [1:0]      axi_awburst, axi_arburst;
  logic [3:0]      axi_awcache, axi_arcache;
  logic            axi_awvalid, axi_wvalid, axi_wlast, axi_bready;
  logic            axi_arvalid, axi_rready, err;
  logic [DW-1:0]   axi_wdata;
  logic [DW/8-1:0] axi_wstrb;
  wire clr = 1'b0;   // abort exercised by simulation, not this proof

  gmm_to_axi4 #(.AW(AW), .DW(DW), .BCW(BCW)) dut (.*);

  // formal reset model
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  logic past_ok = 1'b0; always @(posedge clk) past_ok <= rst_n;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  // FV-side W-beat counter (independent of the DUT) to check WLAST placement
  logic [8:0] wcnt;
  always @(posedge clk)
    if (!rst_n)                       wcnt <= '0;
    else if (axi_wvalid && axi_wready) wcnt <= axi_wlast ? 9'd0 : wcnt + 9'd1;

  always @(posedge clk) if (rst_n) begin
    // ---------- environment: well-behaved GMM master ----------
    assume (!(gmm_read && gmm_write));
    assume (gmm_burstcount >= 1 && gmm_burstcount <= MAXB);   // Avalon: burstcount is always >= 1
    // an Avalon write-burst master keeps `write` asserted for the whole burst
    if (axi_wvalid) assume (gmm_write);
    if (past_ok && $past((gmm_read||gmm_write) && gmm_waitrequest)) begin
      assume (gmm_address    == $past(gmm_address));
      assume (gmm_burstcount == $past(gmm_burstcount));
      assume (gmm_read       == $past(gmm_read));
      assume (gmm_write      == $past(gmm_write));
      assume (gmm_writedata  == $past(gmm_writedata));
      assume (gmm_byteenable == $past(gmm_byteenable));
    end

    // ---------- AXI4 handshake: VALID + payload stable until READY ----------
    if (past_ok && $past(axi_awvalid && !axi_awready)) begin
      assert (axi_awvalid);
      assert (axi_awaddr  == $past(axi_awaddr));
      assert (axi_awlen   == $past(axi_awlen));
      assert (axi_awsize  == $past(axi_awsize));
      assert (axi_awburst == $past(axi_awburst));
    end
    if (past_ok && $past(axi_arvalid && !axi_arready)) begin
      assert (axi_arvalid);
      assert (axi_araddr  == $past(axi_araddr));
      assert (axi_arlen   == $past(axi_arlen));
    end
    if (past_ok && $past(axi_wvalid && !axi_wready)) begin
      assert (axi_wvalid);
      assert (axi_wdata == $past(axi_wdata));
      assert (axi_wstrb == $past(axi_wstrb));
      assert (axi_wlast == $past(axi_wlast));
    end

    // ---------- burst encoding ----------
    // AWLEN is latched at burst start (so it stays valid after the GMM master
    // moves on); check it is a bounded INCR burst. ARLEN tracks the live read
    // command (single AR, held until ARREADY) so its exact value is checked.
    if (axi_awvalid) begin
      assert (axi_awburst == 2'b01);
      assert (axi_awsize  == SZ);
      assert (axi_awlen   <= (MAXB - 1));
    end
    if (axi_arvalid) begin
      assert (axi_arburst == 2'b01);
      assert (axi_arsize  == SZ);
      assert (axi_arlen   == (gmm_burstcount - 1));
    end

    // ---------- WLAST aligns with AWLEN (last W beat of the burst) ----------
    if (axi_wvalid)
      assert (axi_wlast == (wcnt == {1'b0, axi_awlen}));

    // ---------- never both address channels active ----------
    assert (!(axi_awvalid && axi_arvalid));

    // ---------- read data only inside the read-data phase ----------
    if (gmm_readdatavalid) assert (axi_rvalid);
  end
endmodule
