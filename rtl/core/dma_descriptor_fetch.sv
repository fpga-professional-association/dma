//============================================================================
// dma_descriptor_fetch.sv -- Reads and decodes a descriptor from host memory
//
// On `start`, reads DESC_BEATS beats (a 32-byte descriptor) from
// base + index*DESC_BYTES over a GMM master, assembles them little-endian and
// presents the decoded fields with a one-cycle `valid` pulse.
//============================================================================

module dma_descriptor_fetch
  import dma_pkg::*;
(
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 clr,            // abort/soft-clear

  // control
  input  logic                 start,          // 1-cycle pulse
  input  logic [LEN_W-1:0]     index,          // descriptor index in the ring
  input  logic [HADDR_W-1:0]   base_addr,      // ring base (host addr)

  // decoded descriptor out
  output logic                 valid,          // 1-cycle pulse when fields are ready
  output logic [HADDR_W-1:0]   d_host_addr,
  output logic [SADDR_W-1:0]   d_sys_addr,
  output logic [LEN_W-1:0]     d_length,
  output logic                 d_dir,
  output logic                 d_irq,
  output logic                 d_last,
  output logic                 d_owned,        // control[C_VALID]

  // GMM master (to host via arbiter)
  output logic [HADDR_W-1:0]   m_address,
  output logic                 m_read,
  output logic                 m_write,
  output logic [DATA_W-1:0]    m_writedata,
  output logic [BE_W-1:0]      m_byteenable,
  output logic [BCW-1:0]       m_burstcount,
  input  logic                 m_waitrequest,
  input  logic [DATA_W-1:0]    m_readdata,
  input  logic                 m_readdatavalid
);

  typedef enum logic [1:0] {S_IDLE, S_CMD, S_DATA} state_e;
  state_e state;

  localparam int unsigned BCNT_W = (DESC_BEATS > 1) ? $clog2(DESC_BEATS) : 1;
  logic [HADDR_W-1:0]      addr_q;
  logic [BCNT_W-1:0]       beat_cnt;     // counts beats received
  logic [DATA_W-1:0]       beats [0:DESC_BEATS-1];

  // write side of GMM is unused (read-only master)
  assign m_write      = 1'b0;
  assign m_writedata  = '0;
  assign m_byteenable = {BE_W{1'b1}};
  assign m_burstcount = BCW'(DESC_BEATS);
  assign m_address    = addr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      m_read   <= 1'b0;
      addr_q   <= '0;
      beat_cnt <= '0;
      valid    <= 1'b0;
    end else begin
      valid <= 1'b0;                    // default; pulsed in S_DATA completion

      if (clr) begin
        state  <= S_IDLE;
        m_read <= 1'b0;
      end else begin
        unique case (state)
          S_IDLE: begin
            if (start) begin
              // addr = base + index * DESC_BYTES
              addr_q   <= base_addr +
                          ({{(HADDR_W-LEN_W){1'b0}}, index} << $clog2(DESC_BYTES));
              beat_cnt <= '0;
              m_read   <= 1'b1;
              state    <= S_CMD;
            end
          end

          S_CMD: begin
            // hold read until command accepted
            if (!m_waitrequest) begin
              m_read <= 1'b0;           // single burst command issued
              state  <= S_DATA;
            end
          end

          S_DATA: begin
            if (m_readdatavalid) begin
              beats[beat_cnt] <= m_readdata;
              if (beat_cnt == BCNT_W'(DESC_BEATS-1)) begin
                state <= S_IDLE;
                valid <= 1'b1;          // all beats in -> decode is valid next cycle
              end else begin
                beat_cnt <= beat_cnt + 1'b1;
              end
            end
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

  // assemble little-endian descriptor word and decode
  /* verilator lint_off UNUSEDSIGNAL */  // reserved bytes + unused-high sys_addr bits
  logic [DESC_BITS-1:0] d;
  /* verilator lint_on UNUSEDSIGNAL */
  always_comb begin
    d = '0;
    for (int k = 0; k < DESC_BEATS; k++)
      d[k*DATA_W +: DATA_W] = beats[k];
  end

  wire [31:0] ctrl_field = d[DESC_CTRL_LSB +: 32];

  assign d_host_addr = d[DESC_HOST_LSB +: HADDR_W];
  assign d_sys_addr  = d[DESC_SYS_LSB  +: SADDR_W];
  assign d_length    = d[DESC_LEN_LSB  +: LEN_W];
  assign d_dir       = ctrl_field[C_DIR];
  assign d_irq       = ctrl_field[C_IRQ];
  assign d_last      = ctrl_field[C_LAST];
  assign d_owned     = ctrl_field[C_VALID];

endmodule
