//============================================================================
// axi_mem_model.sv -- AXI4 slave with backing memory (sim only)
//
// Mirror of gmm_to_axi4's master. Single outstanding per direction (matches the
// adapter). INCR bursts, byte strobes honored. Optional pseudo-random latency
// (STALL!=0). `mem` is word-indexed and poked/peeked by the TB.
//============================================================================
`timescale 1ns/1ps

module axi_mem_model #(
  parameter int AW         = 32,
  parameter int DW         = 64,
  parameter int IDW        = 1,
  parameter int SIZE_WORDS = 1 << 16,
  parameter int STALL      = 0,
  parameter int SEED       = 16'hBEEF
) (
  input  logic           clk,
  input  logic           rst_n,
  // AW
  input  logic [IDW-1:0]  awid,
  input  logic [AW-1:0]   awaddr,
  input  logic [7:0]      awlen,
  input  logic [2:0]      awsize,
  input  logic [1:0]      awburst,
  input  logic [3:0]      awcache,
  input  logic [2:0]      awprot,
  input  logic            awvalid,
  output logic            awready,
  // W
  input  logic [DW-1:0]   wdata,
  input  logic [DW/8-1:0] wstrb,
  input  logic            wlast,
  input  logic            wvalid,
  output logic            wready,
  // B
  output logic [IDW-1:0]  bid,
  output logic [1:0]      bresp,
  output logic            bvalid,
  input  logic            bready,
  // AR
  input  logic [IDW-1:0]  arid,
  input  logic [AW-1:0]   araddr,
  input  logic [7:0]      arlen,
  input  logic [2:0]      arsize,
  input  logic [1:0]      arburst,
  input  logic [3:0]      arcache,
  input  logic [2:0]      arprot,
  input  logic            arvalid,
  output logic            arready,
  // R
  output logic [IDW-1:0]  rid,
  output logic [DW-1:0]   rdata,
  output logic [1:0]      rresp,
  output logic            rlast,
  output logic            rvalid,
  input  logic            rready
);

  localparam int LSB    = $clog2(DW/8);
  localparam int IXW    = $clog2(SIZE_WORDS);
  localparam int STRIDE = DW/8;

  logic [DW-1:0] mem [0:SIZE_WORDS-1];

  logic [15:0] lfsr;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) lfsr <= SEED[15:0];
    else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
  wire stall_a = (STALL != 0) && lfsr[1];
  wire stall_w = (STALL != 0) && lfsr[2];
  wire stall_r = (STALL != 0) && lfsr[3];

  function automatic [IXW-1:0] idx(input logic [AW-1:0] a);
    idx = a[LSB +: IXW];
  endfunction

  // ---------------- write channel ----------------
  typedef enum logic [1:0] {WS_AW, WS_W, WS_B} ws_e;
  ws_e           ws;
  logic [AW-1:0] waddr;

  // With back-pressure enabled, model a (legal) slave that gates AWREADY on
  // WVALID -- this deadlocks a master that serialises AW strictly before W, so
  // it exercises the adapter's concurrent AW/W presentation.
  assign awready = (ws == WS_AW) && !stall_a && ((STALL == 0) || wvalid);
  assign wready  = (ws == WS_W)  && !stall_w;
  assign bvalid  = (ws == WS_B);
  assign bresp   = 2'b00;
  assign bid     = '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ws    <= WS_AW;
      waddr <= '0;
    end else begin
      unique case (ws)
        WS_AW: if (awvalid && awready) begin
                 waddr <= awaddr;
                 ws    <= WS_W;
               end
        WS_W:  if (wvalid && wready) begin
                 for (int j = 0; j < DW/8; j++)
                   if (wstrb[j]) mem[idx(waddr)][j*8 +: 8] <= wdata[j*8 +: 8];
                 waddr <= waddr + STRIDE;
                 if (wlast) ws <= WS_B;
               end
        WS_B:  if (bready) ws <= WS_AW;
        default: ws <= WS_AW;
      endcase
    end
  end

  // ---------------- read channel ----------------
  typedef enum logic [0:0] {RS_AR, RS_R} rs_e;
  rs_e           rs;
  logic [AW-1:0] raddr;
  logic [8:0]    rbeats;      // remaining beats (arlen+1, up to 256)

  assign arready = (rs == RS_AR) && !stall_a;
  assign rvalid  = (rs == RS_R) && !stall_r;
  assign rresp   = 2'b00;
  assign rid     = '0;
  assign rlast   = (rs == RS_R) && (rbeats == 9'd1);
  assign rdata   = mem[idx(raddr)];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rs     <= RS_AR;
      raddr  <= '0;
      rbeats <= '0;
    end else begin
      unique case (rs)
        RS_AR: if (arvalid && arready) begin
                 raddr  <= araddr;
                 rbeats <= {1'b0, arlen} + 9'd1;
                 rs     <= RS_R;
               end
        RS_R:  if (rvalid && rready) begin
                 raddr  <= raddr + STRIDE;
                 rbeats <= rbeats - 9'd1;
                 if (rbeats == 9'd1) rs <= RS_AR;
               end
        default: rs <= RS_AR;
      endcase
    end
  end

endmodule
