//============================================================================
// avalon_mem_model.sv -- Avalon-MM pipelined slave with backing memory (sim)
//
// Serves both the HOST port (PCIe TXS, AW=64) and, in the AVALON config, the
// SYS port (AW=32). Supports read/write bursts, >=1-cycle read latency, and
// pseudo-random waitrequest back-pressure (STALL!=0). Single outstanding read
// (matches the DMA masters). Memory is word-indexed; the TB pokes/peeks `mem`
// via a hierarchical reference.
//
// NOTE: simulation model only -- not synthesizable.
//============================================================================
`timescale 1ns/1ps

module avalon_mem_model #(
  parameter int AW         = 64,
  parameter int DW         = 64,
  parameter int BCW        = 5,
  parameter int SIZE_WORDS = 1 << 16,
  parameter int STALL      = 0,        // 0 = never stall, else pseudo-random
  parameter int SEED       = 16'hACE1,
  parameter int ERR_WORD   = -1        // word index that returns response=SLVERR (-1 = none)
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [AW-1:0]  address,
  input  logic           read,
  input  logic           write,
  input  logic [DW-1:0]  writedata,
  input  logic [DW/8-1:0] byteenable,
  input  logic [BCW-1:0] burstcount,
  output logic           waitrequest,
  output logic [DW-1:0]  readdata,
  output logic           readdatavalid,
  output logic [1:0]     response        // per-beat read completion status (00=OKAY)
);

  localparam int LSB    = $clog2(DW/8);
  localparam int IXW    = $clog2(SIZE_WORDS);
  localparam int STRIDE = DW/8;

  logic [DW-1:0] mem [0:SIZE_WORDS-1];

  // pseudo-random stall
  logic [15:0] lfsr;
  wire         stall = (STALL != 0) && lfsr[0];

  // read burst state (single outstanding)
  logic [BCW-1:0] rrem;
  logic [AW-1:0]  raddr;
  logic [DW-1:0]  rdata_q;
  logic           rdv_q;
  logic [1:0]     resp_q;

  // write burst state
  logic           wactive;
  logic [BCW-1:0] wrem;
  logic [AW-1:0]  waddr;

  assign waitrequest   = stall || (rrem != 0);
  assign readdata      = rdata_q;
  assign readdatavalid = rdv_q;
  assign response      = resp_q;

  function automatic [IXW-1:0] idx(input logic [AW-1:0] a);
    idx = a[LSB +: IXW];
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr    <= SEED[15:0];
      rrem    <= '0;
      raddr   <= '0;
      rdata_q <= '0;
      rdv_q   <= 1'b0;
      resp_q  <= 2'b00;
      wactive <= 1'b0;
      wrem    <= '0;
      waddr   <= '0;
    end else begin
      lfsr   <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
      rdv_q  <= 1'b0;
      resp_q <= 2'b00;

      // ---- read data emission (back-to-back after acceptance) ----
      if (rrem != 0) begin
        rdv_q   <= 1'b1;
        rdata_q <= mem[idx(raddr)];
        // fault-inject a non-OK completion on the configured word (SLVERR=2'b10)
        resp_q  <= (ERR_WORD >= 0 && idx(raddr) == IXW'(ERR_WORD)) ? 2'b10 : 2'b00;
        raddr   <= raddr + STRIDE;
        rrem    <= rrem - 1'b1;
      end

      // ---- command acceptance ----
      if (!waitrequest) begin
        if (read) begin
          raddr <= address;
          rrem  <= burstcount;
        end else if (write) begin
          // perform this beat
          for (int j = 0; j < DW/8; j++)
            if (byteenable[j])
              mem[idx(wactive ? waddr : address)][j*8 +: 8] <= writedata[j*8 +: 8];
          if (!wactive) begin
            waddr   <= address + STRIDE;
            wrem    <= burstcount - 1'b1;
            wactive <= (burstcount > 1);
          end else begin
            waddr <= waddr + STRIDE;
            wrem  <= wrem - 1'b1;
            if (wrem == 1) wactive <= 1'b0;
          end
        end
      end
    end
  end

endmodule
