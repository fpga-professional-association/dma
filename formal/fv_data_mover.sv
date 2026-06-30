//============================================================================
// fv_data_mover.sv -- Formal burst-soundness properties for dma_data_mover
//
// Closes the package-level soundness gap: the "no burst ever crosses a
// 1 KiB/4 KiB boundary" contract that every bus-adapter proof silently relies
// on lives, unverified, in the data mover's beats_to_boundary() burst sizing.
// This harness proves it directly, on the actual GMM command the mover drives
// onto each bus port. Portable yosys-formal immediate-assertion style, provable
// with the open-source yosys+SAT engine or SymbiYosys.
//
// Properties (checked on every read/write command the mover issues, on either
// the HOST or the SYS GMM master port):
//   * burstcount in [1, MAX_BURST_BEATS];
//   * the byte window [addr, addr + burstcount*BE_W) stays inside the aligned
//     1 KiB page of addr  (=> never crosses a 1 KiB or 4 KiB boundary);
//   * read/write are mutually exclusive on each port, and only one port carries
//     the (single) read engine / write engine at a time;
//   * full-beat byteenable.
//
// Note: properties are stated only on the module's PORTS, because the portable
// yosys Verilog front-end does not resolve hierarchical references into a DUT
// instance. The bus command is exactly the protocol-critical observable.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/data_mover.sby)
//============================================================================

module fv_data_mover (
  input logic                        clk,
  input logic                        rst_n,
  // free command stimulus
  input logic                        start,
  input logic [dma_pkg::HADDR_W-1:0] host_addr,
  input logic [dma_pkg::SADDR_W-1:0] sys_addr,
  input logic [dma_pkg::LEN_W-1:0]   length,
  input logic                        dir,
  // free bus responses (HOST + SYS GMM slaves)
  input logic                        h_waitrequest,
  input logic [dma_pkg::DATA_W-1:0]  h_readdata,
  input logic                        h_readdatavalid,
  input logic                        s_waitrequest,
  input logic [dma_pkg::DATA_W-1:0]  s_readdata,
  input logic                        s_readdatavalid
);
  localparam int unsigned HADDR_W = dma_pkg::HADDR_W;
  localparam int unsigned SADDR_W = dma_pkg::SADDR_W;
  localparam int unsigned BCW     = dma_pkg::BCW;
  localparam int unsigned MAXB    = dma_pkg::MAX_BURST_BEATS;
  localparam int unsigned BE_W    = dma_pkg::BE_W;
  localparam int unsigned LBE     = $clog2(BE_W);                // log2(bytes/beat)
  localparam logic [HADDR_W-1:0] PAGE  = HADDR_W'(1024);         // 1 KiB page
  localparam logic [HADDR_W-1:0] PMASK = PAGE - 1'b1;            // low-10-bit mask

  // DUT outputs (all genuinely connected -- asserted on directly)
  logic                       busy, done;
  logic [HADDR_W-1:0]         h_address;
  logic                       h_read, h_write;
  logic [dma_pkg::DATA_W-1:0] h_writedata;
  logic [BE_W-1:0]            h_byteenable;
  logic [BCW-1:0]             h_burstcount;
  logic [SADDR_W-1:0]         s_address;
  logic                       s_read, s_write;
  logic [dma_pkg::DATA_W-1:0] s_writedata;
  logic [BE_W-1:0]            s_byteenable;
  logic [BCW-1:0]             s_burstcount;

  wire clr = 1'b0;   // abort path is exercised by simulation, not this proof

  dma_data_mover dut (
    .clk, .rst_n, .clr,
    .start, .host_addr, .sys_addr, .length, .dir,
    .busy, .done,
    .h_address, .h_read, .h_write, .h_writedata, .h_byteenable, .h_burstcount,
    .h_waitrequest, .h_readdata, .h_readdatavalid,
    .s_address, .s_read, .s_write, .s_writedata, .s_byteenable, .s_burstcount,
    .s_waitrequest, .s_readdata, .s_readdatavalid
  );

  // formal reset model (matches the other harnesses)
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  // page offset + burst byte-span for each port's live command
  logic [HADDR_W-1:0] h_lo, h_end;          // HOST port (64-bit address)
  logic [HADDR_W-1:0] s_lo, s_end;          // SYS port  (32-bit addr, zero-extended)
  always_comb begin
    h_lo  = h_address & PMASK;
    h_end = h_lo + (HADDR_W'(h_burstcount) << LBE);
    s_lo  = {{(HADDR_W-SADDR_W){1'b0}}, s_address} & PMASK;
    s_end = s_lo + (HADDR_W'(s_burstcount) << LBE);
  end

  always @(posedge clk) if (rst_n) begin
    // ---------- environment: engine launches one move at a time ----------
    if (busy) assume (!start);

    // ---------- HOST-port command soundness ----------
    if (h_read || h_write) begin
      a_h_bcount  : assert (h_burstcount >= 1 && h_burstcount <= MAXB);
      a_h_nocross : assert (h_end <= PAGE);     // stays in the aligned 1 KiB page
      a_h_be      : assert (h_byteenable == {BE_W{1'b1}});
    end

    // ---------- SYS-port command soundness ----------
    if (s_read || s_write) begin
      a_s_bcount  : assert (s_burstcount >= 1 && s_burstcount <= MAXB);
      a_s_nocross : assert (s_end <= PAGE);
      a_s_be      : assert (s_byteenable == {BE_W{1'b1}});
    end

    // ---------- per-port read/write mutual exclusion ----------
    a_h_excl : assert (!(h_read && h_write));
    a_s_excl : assert (!(s_read && s_write));

    // ---------- single read engine / single write engine across ports ----------
    a_one_rd : assert (!(h_read  && s_read));
    a_one_wr : assert (!(h_write && s_write));
  end
endmodule
