//============================================================================
// ahb_mem_model.sv -- AHB-Lite slave with backing memory (sim only)
//
// Mirror of gmm_to_ahb's master. Classic AHB address/data pipeline with
// optional wait states (STALL!=0). Full-word transfers (HSIZE ignored). `mem`
// is word-indexed and poked/peeked by the TB. HRESP always OKAY.
//============================================================================
`timescale 1ns/1ps

module ahb_mem_model #(
  parameter int AW         = 32,
  parameter int DW         = 64,
  parameter int SIZE_WORDS = 1 << 16,
  parameter int STALL      = 0,
  parameter int SEED       = 16'h1234,
  parameter int ERR_WORD   = -1   // word index that responds HRESP=ERROR (-1 = none)
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [AW-1:0]  haddr,
  input  logic [2:0]     hburst,
  input  logic [2:0]     hsize,
  input  logic [1:0]     htrans,
  input  logic           hwrite,
  input  logic [DW-1:0]  hwdata,
  output logic [DW-1:0]  hrdata,
  output logic           hready,
  output logic           hresp
);

  localparam logic [1:0] HT_NONSEQ = 2'b10;
  localparam logic [1:0] HT_SEQ    = 2'b11;
  localparam int LSB = $clog2(DW/8);
  localparam int IXW = $clog2(SIZE_WORDS);

  logic [DW-1:0] mem [0:SIZE_WORDS-1];

  logic [15:0] lfsr;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) lfsr <= SEED[15:0];
    else        lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};

  // data-phase pipeline registers
  logic           dp_valid, dp_write;
  logic [AW-1:0]  dp_addr;
  logic [1:0]     wait_cnt;

  wire active_addr = (htrans == HT_NONSEQ) || (htrans == HT_SEQ);

  function automatic [IXW-1:0] idx(input logic [AW-1:0] a);
    idx = a[LSB +: IXW];
  endfunction

  assign hready = (wait_cnt == 2'd0);
  // HRESP=ERROR during the data phase of the configured error word (fault inject)
  assign hresp  = (ERR_WORD >= 0) && dp_valid && (idx(dp_addr) == IXW'(ERR_WORD));

  assign hrdata = mem[idx(dp_addr)];          // valid during a read data phase

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dp_valid <= 1'b0;
      dp_write <= 1'b0;
      dp_addr  <= '0;
      wait_cnt <= 2'd0;
    end else if (hready) begin
      // complete the data phase that was in flight
      if (dp_valid && dp_write)
        mem[idx(dp_addr)] <= hwdata;
      // accept the address phase presented this cycle
      if (active_addr) begin
        dp_valid <= 1'b1;
        dp_write <= hwrite;
        dp_addr  <= haddr;
      end else begin
        dp_valid <= 1'b0;
      end
      // optionally insert wait states for the next data phase
      wait_cnt <= (STALL != 0) ? lfsr[1:0] : 2'd0;
    end else begin
      wait_cnt <= wait_cnt - 2'd1;
    end
  end

endmodule
