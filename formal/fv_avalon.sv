//============================================================================
// fv_avalon.sv -- Formal passthrough-equivalence properties for gmm_to_avalon
//
// gmm_to_avalon is the default-SYS adapter and, until now, the only bus boundary
// with no harness. GMM already is the Avalon-MM pipelined profile, so the adapter
// is a pure passthrough; this proof pins that contract down (every Avalon master
// output equals its GMM source, every GMM response equals its Avalon source,
// err == 0) so it stays a verified baseline before any future bridge is dropped
// in at the documented insertion point.
//
// Portable yosys-formal immediate-assertion style, provable with the open-source
// yosys+SAT engine or SymbiYosys. Small widths keep BMC trivial; the equivalence
// is width-independent.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/avalon.sby)
//============================================================================

module fv_avalon #(
  parameter int unsigned AW = 8,        // small for tractable BMC (proof is width-agnostic)
  parameter int unsigned DW = 16
) (
  input logic            clk,
  input logic            rst_n,
  // free GMM master command (slave side of the adapter)
  input logic [AW-1:0]   gmm_address,
  input logic            gmm_read,
  input logic            gmm_write,
  input logic [DW-1:0]   gmm_writedata,
  input logic [DW/8-1:0] gmm_byteenable,
  input logic [dma_pkg::BCW-1:0] gmm_burstcount,
  // free Avalon slave responses (master side of the adapter)
  input logic            avm_waitrequest,
  input logic [DW-1:0]   avm_readdata,
  input logic            avm_readdatavalid
);
  localparam int unsigned BCW = dma_pkg::BCW;

  // adapter outputs
  logic            gmm_waitrequest, gmm_readdatavalid;
  logic [DW-1:0]   gmm_readdata;
  logic [AW-1:0]   avm_address;
  logic            avm_read, avm_write;
  logic [DW-1:0]   avm_writedata;
  logic [DW/8-1:0] avm_byteenable;
  logic [BCW-1:0]  avm_burstcount;
  logic            err;
  wire clr = 1'b0;   // unused by the adapter; tied off like the other harnesses

  gmm_to_avalon #(.AW(AW), .DW(DW), .BCW(BCW)) dut (.*);

  // formal reset model (matches the other harnesses)
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  always @(posedge clk) if (rst_n) begin
    // ---------- GMM command -> Avalon master (passthrough) ----------
    a_addr  : assert (avm_address    == gmm_address);
    a_read  : assert (avm_read       == gmm_read);
    a_write : assert (avm_write      == gmm_write);
    a_wdata : assert (avm_writedata  == gmm_writedata);
    a_be    : assert (avm_byteenable == gmm_byteenable);
    a_bcnt  : assert (avm_burstcount == gmm_burstcount);

    // ---------- Avalon slave responses -> GMM (passthrough) ----------
    a_wait  : assert (gmm_waitrequest   == avm_waitrequest);
    a_rdata : assert (gmm_readdata      == avm_readdata);
    a_rdv   : assert (gmm_readdatavalid == avm_readdatavalid);

    // ---------- no error response on the Avalon boundary ----------
    a_err   : assert (err == 1'b0);
  end
endmodule
