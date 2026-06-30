// SPDX-License-Identifier: Apache-2.0
//============================================================================
// fv_arbiter.sv -- Formal properties for dma_arbiter
//
// Portable yosys-formal immediate-assertion style. Proves the essential
// arbiter safety from the (fully observable) port behaviour:
//   * the downstream port never carries two commands at once;
//   * at most one upstream master is accepted at a time (grant mutual exclusion);
//   * read responses are mutually exclusive and only appear during an active
//     read transaction;
//   * a forwarded write payload always comes from one of the masters.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/arbiter.sby)
//============================================================================

module fv_arbiter #(
  parameter int unsigned AW = 8,
  parameter int unsigned DW = 16
) (
  input logic            clk,
  input logic            rst_n,
  // free master 0
  input logic [AW-1:0]   m0_address,
  input logic            m0_read, m0_write,
  input logic [DW-1:0]   m0_writedata,
  input logic [DW/8-1:0] m0_byteenable,
  input logic [dma_pkg::BCW-1:0] m0_burstcount,
  // free master 1
  input logic [AW-1:0]   m1_address,
  input logic            m1_read, m1_write,
  input logic [DW-1:0]   m1_writedata,
  input logic [DW/8-1:0] m1_byteenable,
  input logic [dma_pkg::BCW-1:0] m1_burstcount,
  // free downstream slave
  input logic            o_waitrequest,
  input logic [DW-1:0]   o_readdata,
  input logic            o_readdatavalid,
  // free abort input (issue #7: abort coverage)
  input logic            clr
);
  localparam int unsigned BCW = dma_pkg::BCW;

  logic m0_waitrequest, m0_readdatavalid, m1_waitrequest, m1_readdatavalid;
  logic [DW-1:0] m0_readdata, m1_readdata;
  logic [AW-1:0]   o_address;
  logic            o_read, o_write;
  logic [DW-1:0]   o_writedata;
  logic [DW/8-1:0] o_byteenable;
  logic [BCW-1:0]  o_burstcount;

  dma_arbiter #(.AW(AW), .DW(DW), .BCW(BCW)) dut (.*);

  // ---- cover witnesses (issue #7: rule out vacuous passes) ----
  (* keep *) wire cov_grant0 = (m0_read | m0_write) && !m0_waitrequest; // m0 accepted on the bus
  (* keep *) wire cov_grant1 = (m1_read | m1_write) && !m1_waitrequest; // m1 accepted on the bus
  (* keep *) wire cov_abort  = clr && (o_read | o_write);               // abort while a cmd is driven

  // formal reset model
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  logic past_ok = 1'b0; always @(posedge clk) past_ok <= rst_n;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  always @(posedge clk) if (rst_n) begin
    // ---------- environment ----------
    assume (!(m0_read && m0_write));
    assume (!(m1_read && m1_write));
    if (m0_read||m0_write) assume (m0_burstcount >= 1 && m0_burstcount <= dma_pkg::MAX_BURST_BEATS);
    if (m1_read||m1_write) assume (m1_burstcount >= 1 && m1_burstcount <= dma_pkg::MAX_BURST_BEATS);
    // a single-outstanding slave returns read data only for the in-flight read
    if (o_readdatavalid) assume (dut.active && dut.is_read);

    // ---------- downstream: never two commands at once ----------
    assert (!(o_read && o_write));

    // ---------- grant mutual exclusion: at most one master accepted ----------
    assert (!(!m0_waitrequest && !m1_waitrequest));

    // ---------- read responses: mutually exclusive, only during an active read ----------
    assert (!(m0_readdatavalid && m1_readdatavalid));
    if (m0_readdatavalid || m1_readdatavalid) assert (dut.active && dut.is_read);
    if (m0_readdatavalid) assert (o_readdatavalid);
    if (m1_readdatavalid) assert (o_readdatavalid);

    // ---------- a forwarded write payload comes from one of the masters ----------
    if (o_write) assert (o_writedata == m0_writedata || o_writedata == m1_writedata);

    // ---------- abort safety (issue #7): clr drops the in-flight transaction ----------
    // After abort, no read response is routed to either master (proven from ports;
    // the in-flight transaction is dropped so the routing qualifier goes inactive).
    if (past_ok && $past(clr)) a_abort_no_resp : assert (!m0_readdatavalid && !m1_readdatavalid);
    // With no fresh request pending, no stray downstream command is issued.
    if (past_ok && $past(clr) && !(m0_read | m0_write | m1_read | m1_write))
                               a_abort_no_stray : assert (!o_read && !o_write);

    // ---------- cover witnesses (reachability checked by run_formal.sh / sby) ----------
    c_grant0 : cover (cov_grant0);
    c_grant1 : cover (cov_grant1);
    c_abort  : cover (cov_abort);
  end
endmodule
