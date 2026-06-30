// SPDX-License-Identifier: Apache-2.0
//============================================================================
// gmm_to_avalon.sv -- GMM (Avalon-MM pipelined) -> Avalon-MM master
//
// GMM already IS the Avalon-MM pipelined, burst-capable profile, so this
// adapter is a passthrough that exposes the signals under standard Avalon-MM
// master names. It exists as a named, separately-verifiable bus boundary and as
// the natural insertion point for an Avalon clock-crossing/pipeline bridge.
//============================================================================

module gmm_to_avalon #(
  parameter int unsigned AW  = dma_pkg::SADDR_W,
  parameter int unsigned DW  = dma_pkg::DATA_W,
  parameter int unsigned BCW = dma_pkg::BCW
) (
  input  logic            clk,
  input  logic            rst_n,

  // -------- GMM slave (from core SYS master) --------
  input  logic [AW-1:0]   gmm_address,
  input  logic            gmm_read,
  input  logic            gmm_write,
  input  logic [DW-1:0]   gmm_writedata,
  input  logic [DW/8-1:0] gmm_byteenable,
  input  logic [BCW-1:0]  gmm_burstcount,
  output logic            gmm_waitrequest,
  output logic [DW-1:0]   gmm_readdata,
  output logic            gmm_readdatavalid,

  // -------- Avalon-MM master --------
  output logic [AW-1:0]   avm_address,
  output logic            avm_read,
  output logic            avm_write,
  output logic [DW-1:0]   avm_writedata,
  output logic [DW/8-1:0] avm_byteenable,
  output logic [BCW-1:0]  avm_burstcount,
  input  logic            avm_waitrequest,
  input  logic [DW-1:0]   avm_readdata,
  input  logic            avm_readdatavalid,

  input  logic            clr,         // unused (Avalon-MM has no error response)
  output logic            err          // tied 0 (Avalon-MM has no error response here)
);

  assign avm_address       = gmm_address;
  assign avm_read          = gmm_read;
  assign avm_write         = gmm_write;
  assign avm_writedata     = gmm_writedata;
  assign avm_byteenable    = gmm_byteenable;
  assign avm_burstcount    = gmm_burstcount;

  assign gmm_waitrequest   = avm_waitrequest;
  assign gmm_readdata      = avm_readdata;
  assign gmm_readdatavalid = avm_readdatavalid;

  assign err               = 1'b0;

  // keep clk/rst_n/clr in the port list for drop-in pipeline-bridge replacement
  wire _unused = &{1'b0, clk, rst_n, clr};

endmodule
