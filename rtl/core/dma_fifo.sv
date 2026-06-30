//============================================================================
// dma_fifo.sv -- Synchronous show-ahead (first-word fall-through) FIFO
//
// rd_data combinationally reflects the head whenever !empty; a pop occurs when
// rd_en & !empty. A push occurs when wr_en & !full. `level` gives the current
// occupancy (0..DEPTH) so producers can reserve space and consumers can size
// drain bursts.
//
// The memory is read asynchronously, so on Altera this maps to MLAB/LUT-RAM.
// For deep instances that should use M20K, replace with `scfifo`
// (lpm_showahead="ON"); the port semantics are identical.
//============================================================================

module dma_fifo #(
  parameter int unsigned WIDTH = 64,
  parameter int unsigned DEPTH = 256          // must be a power of two
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     clr,        // synchronous flush (abort)
  // write side
  input  logic                     wr_en,
  input  logic [WIDTH-1:0]         wr_data,
  output logic                     full,
  // read side (show-ahead)
  input  logic                     rd_en,
  output logic [WIDTH-1:0]         rd_data,
  output logic                     empty,
  // occupancy
  output logic [$clog2(DEPTH):0]   level        // 0 .. DEPTH
);

  localparam int unsigned AW = $clog2(DEPTH);

  // elaboration-time check (outside translate_off so synthesis honours it too)
  if (DEPTH != (1 << AW)) begin : gen_depth_check
    $error("dma_fifo: DEPTH (%0d) must be a power of two", DEPTH);
  end

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0]      wptr, rptr;               // one extra bit for wrap/level
  logic             push, pop;

  assign push = wr_en & ~full;
  assign pop  = rd_en & ~empty;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end else if (clr) begin                   // flush: drop all queued beats
      wptr <= '0;
      rptr <= '0;
    end else begin
      if (push) wptr <= wptr + 1'b1;
      if (pop)  rptr <= rptr + 1'b1;
    end
  end

  // separate always block for inferred RAM (no reset on memory)
  always_ff @(posedge clk) begin
    if (push) mem[wptr[AW-1:0]] <= wr_data;
  end

  assign level   = wptr - rptr;               // 0..DEPTH (never exceeds DEPTH)
  assign full    = (level == DEPTH[AW:0]);
  assign empty   = (level == '0);
  assign rd_data = mem[rptr[AW-1:0]];          // show-ahead: head is always visible

endmodule
