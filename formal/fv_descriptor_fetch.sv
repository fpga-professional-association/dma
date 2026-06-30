//============================================================================
// fv_descriptor_fetch.sv -- Formal properties for dma_descriptor_fetch
//
// Proves the descriptor-fetch addressing and command shape -- the analogue of
// the data-mover boundary proof for the descriptor ring walk: a wrong index
// stride or burst length would fetch the wrong 32-byte descriptor.
//
// Properties (on the GMM master PORTS, which is all the portable yosys front-end
// can resolve):
//   * the read command targets base_addr + index*DESC_BYTES;
//   * the burst is exactly DESC_BEATS, with full byteenable, and the master is
//     read-only (never writes);
//   * the command is held stable (address/burstcount) across wait states;
//   * `valid` is a single-cycle pulse (never asserted two cycles running).
//
// The ring base / index are treated as stable configuration (assumed constant),
// matching how the engine drives them from latched registers during a fetch.
//
// Run:  ../scripts/run_formal.sh   (or sby -f formal/descriptor_fetch.sby)
//============================================================================

module fv_descriptor_fetch (
  input logic                        clk,
  input logic                        rst_n,
  // free control stimulus
  input logic                        start,
  input logic [dma_pkg::LEN_W-1:0]   index,
  input logic [dma_pkg::HADDR_W-1:0] base_addr,
  // free GMM slave responses
  input logic                        m_waitrequest,
  input logic [dma_pkg::DATA_W-1:0]  m_readdata,
  input logic                        m_readdatavalid
);
  localparam int unsigned HADDR_W = dma_pkg::HADDR_W;
  localparam int unsigned SADDR_W = dma_pkg::SADDR_W;
  localparam int unsigned LEN_W   = dma_pkg::LEN_W;
  localparam int unsigned DATA_W  = dma_pkg::DATA_W;
  localparam int unsigned BE_W    = dma_pkg::BE_W;
  localparam int unsigned BCW     = dma_pkg::BCW;
  localparam int unsigned DESC_BEATS = dma_pkg::DESC_BEATS;
  localparam int unsigned LDB     = $clog2(dma_pkg::DESC_BYTES);   // index stride

  // DUT outputs
  logic                 valid, d_dir, d_irq, d_last, d_owned;
  logic [HADDR_W-1:0]   d_host_addr;
  logic [SADDR_W-1:0]   d_sys_addr;
  logic [LEN_W-1:0]     d_length;
  logic [HADDR_W-1:0]   m_address;
  logic                 m_read, m_write;
  logic [DATA_W-1:0]    m_writedata;
  logic [BE_W-1:0]      m_byteenable;
  logic [BCW-1:0]       m_burstcount;
  wire clr = 1'b0;   // abort exercised by simulation, not this proof

  dma_descriptor_fetch dut (.*);

  // formal reset model
  logic f_init = 1'b1;  always @(posedge clk) f_init <= 1'b0;
  logic past_ok = 1'b0; always @(posedge clk) past_ok <= rst_n;
  always @(posedge clk) begin
    if (f_init) assume (!rst_n); else assume (rst_n);
  end

  // expected fetch address: base + index*DESC_BYTES
  wire [HADDR_W-1:0] exp_addr =
      base_addr + ({{(HADDR_W-LEN_W){1'b0}}, index} << LDB);

  always @(posedge clk) if (rst_n) begin
    // ---------- environment: ring base/index are stable configuration ----------
    if (past_ok) begin
      assume (base_addr == $past(base_addr));
      assume (index     == $past(index));
    end

    // ---------- command shape ----------
    a_burst : assert (m_burstcount == BCW'(DESC_BEATS));   // exactly one descriptor
    a_nowr  : assert (m_write == 1'b0);                    // read-only master
    a_be    : assert (m_byteenable == {BE_W{1'b1}});

    // ---------- addressing ----------
    if (m_read) a_addr : assert (m_address == exp_addr);   // base + index*DESC_BYTES

    // ---------- command held stable across wait states ----------
    if (past_ok && $past(m_read && m_waitrequest)) begin
      a_hold_rd   : assert (m_read);
      a_hold_addr : assert (m_address    == $past(m_address));
      a_hold_bc   : assert (m_burstcount == $past(m_burstcount));
    end

    // ---------- valid is a single-cycle pulse ----------
    if (past_ok && $past(valid)) a_valid_pulse : assert (!valid);
  end
endmodule
