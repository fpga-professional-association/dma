// SPDX-License-Identifier: Apache-2.0
//============================================================================
// dma_csr.sv -- Host-facing control/status register file
//
// A single-beat Avalon-MM slave (no bursts, waitrequest tied low, 1-cycle read
// latency). Exports a decoded control bundle to the engine and imports status,
// completion/error events and an interrupt line. See docs/register_map.md.
//
// Register addresses are materialised as CSR_ADDR_W-wide localparams (constant
// context) so the address compares/case use no in-process part-selects.
//============================================================================

module dma_csr
  import dma_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,

  // -------- Avalon-MM slave (host BAR access) --------
  input  logic [CSR_ADDR_W-1:0] csr_address,
  input  logic                  csr_read,
  input  logic                  csr_write,
  input  logic [CSR_DATA_W-1:0] csr_writedata,
  output logic [CSR_DATA_W-1:0] csr_readdata,
  output logic                  csr_readdatavalid,
  output logic                  csr_waitrequest,

  // -------- control out (to engine) --------
  output logic                  go,            // 1-cycle pulse
  output logic                  abort,         // 1-cycle pulse
  output logic [HADDR_W-1:0]    desc_base,
  output logic [LEN_W-1:0]      desc_count,

  // -------- status in (from engine) --------
  input  logic                  busy,
  input  logic                  done,
  input  logic                  error,
  input  logic [7:0]            err_code,
  input  logic [LEN_W-1:0]      cur_index,
  input  logic [3:0]            state,
  input  logic                  irq_done_set,  // 1-cycle pulse
  input  logic                  irq_error_set, // 1-cycle pulse

  // -------- interrupt out --------
  output logic                  irq
);

  // CSR_ADDR_W-wide address constants (folded in constant context)
  localparam [CSR_ADDR_W-1:0] A_CTRL    = REG_CTRL[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_STATUS  = REG_STATUS[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_BASE_LO = REG_DESC_BASE_LO[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_BASE_HI = REG_DESC_BASE_HI[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_COUNT   = REG_DESC_COUNT[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_INDEX   = REG_DESC_INDEX[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_IRQ_ST  = REG_IRQ_STATUS[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_IRQ_EN  = REG_IRQ_ENABLE[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_ERR     = REG_ERR_INFO[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_VER     = REG_VERSION[CSR_ADDR_W-1:0];
  localparam [CSR_ADDR_W-1:0] A_SCRATCH = REG_SCRATCH[CSR_ADDR_W-1:0];

  // stored registers (desc_base split to avoid in-process part-select writes)
  logic                  irq_en_q;
  logic [31:0]           desc_base_lo_q, desc_base_hi_q;
  logic [LEN_W-1:0]      desc_count_q;
  logic [1:0]            irq_status_q;   // [IRQ_ERROR, IRQ_DONE]
  logic [1:0]            irq_enable_q;
  logic [CSR_DATA_W-1:0] scratch_q;

  assign csr_waitrequest = 1'b0;
  assign desc_base       = {desc_base_hi_q, desc_base_lo_q};
  assign desc_count      = desc_count_q;

  wire wr      = csr_write;
  wire is_ctrl = wr && (csr_address == A_CTRL);

  // set/clear masks for the RW1C IRQ_STATUS register.  Bit positions come from
  // dma_pkg (IRQ_DONE/IRQ_ERROR) so the register layout is single-sourced.
  logic [1:0] irq_set, irq_clr;
  always_comb begin
    irq_set            = '0;
    irq_set[IRQ_DONE]  = irq_done_set;
    irq_set[IRQ_ERROR] = irq_error_set;
    irq_clr = (wr && (csr_address == A_IRQ_ST)) ? csr_writedata[1:0] : 2'b00;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      go             <= 1'b0;
      abort          <= 1'b0;
      irq_en_q       <= 1'b0;
      desc_base_lo_q <= '0;
      desc_base_hi_q <= '0;
      desc_count_q   <= '0;
      irq_status_q   <= '0;
      irq_enable_q   <= '0;
      scratch_q      <= '0;
    end else begin
      // self-clearing control pulses
      go    <= is_ctrl && csr_writedata[CTRL_GO];
      abort <= is_ctrl && csr_writedata[CTRL_ABORT];

      if (is_ctrl)                                irq_en_q       <= csr_writedata[CTRL_IRQ_EN];
      if (wr && (csr_address == A_BASE_LO))       desc_base_lo_q <= csr_writedata;
      if (wr && (csr_address == A_BASE_HI))       desc_base_hi_q <= csr_writedata;
      if (wr && (csr_address == A_COUNT))         desc_count_q   <= csr_writedata[LEN_W-1:0];
      if (wr && (csr_address == A_IRQ_EN))        irq_enable_q   <= csr_writedata[1:0];
      if (wr && (csr_address == A_SCRATCH))       scratch_q      <= csr_writedata;

      // RW1C IRQ status: hardware-set wins over same-cycle clear
      irq_status_q <= (irq_status_q & ~irq_clr) | irq_set;
    end
  end

  assign irq = irq_en_q & (|(irq_status_q & irq_enable_q));

  // STATUS read-back word, assembled from the dma_pkg bit positions so the CSR
  // layout is single-sourced and cannot drift from docs/register_map.md.
  logic [CSR_DATA_W-1:0] status_word;
  always_comb begin
    status_word                      = '0;
    status_word[ST_BUSY]             = busy;
    status_word[ST_DONE]             = done;
    status_word[ST_ERROR]            = error;
    status_word[ST_STATE_LSB +: 4]   = state;   // [7:4] engine FSM state
  end

  // ------- read path: 1-cycle latency -------
  logic [CSR_DATA_W-1:0] rdata_next;
  always_comb begin
    case (csr_address)
      A_CTRL:    rdata_next = {{(CSR_DATA_W-3){1'b0}}, irq_en_q, 2'b00};
      A_STATUS:  rdata_next = status_word;
      A_BASE_LO: rdata_next = desc_base_lo_q;
      A_BASE_HI: rdata_next = desc_base_hi_q;
      A_COUNT:   rdata_next = desc_count_q;
      A_INDEX:   rdata_next = cur_index;
      A_IRQ_ST:  rdata_next = {{(CSR_DATA_W-2){1'b0}}, irq_status_q};
      A_IRQ_EN:  rdata_next = {{(CSR_DATA_W-2){1'b0}}, irq_enable_q};
      A_ERR:     rdata_next = {{(CSR_DATA_W-8){1'b0}}, err_code};
      A_VER:     rdata_next = VERSION_ID;
      A_SCRATCH: rdata_next = scratch_q;
      default:   rdata_next = '0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      csr_readdata      <= '0;
      csr_readdatavalid <= 1'b0;
    end else begin
      csr_readdatavalid <= csr_read;
      if (csr_read) csr_readdata <= rdata_next;
    end
  end

endmodule
