// SPDX-License-Identifier: Apache-2.0
//============================================================================
// dma_engine_core.sv -- Top of the bus-agnostic DMA core
//
// Instantiates the CSR file, descriptor fetch, data mover and the HOST-port
// arbiter, and runs the descriptor-ring walk FSM that sequences fetch -> move
// for each of DESC_COUNT descriptors. Exposes:
//   * a CSR slave  (host BAR access)
//   * a HOST GMM master (PCIe side -- descriptors + host data)
//   * a SYS  GMM master (local system bus -- adapted to Avalon/AXI4/AHB on top)
//   * an irq line
//============================================================================

module dma_engine_core
  import dma_pkg::*;
(
  input  logic                  clk,
  input  logic                  rst_n,

  // -------- CSR slave (host BAR) --------
  input  logic [CSR_ADDR_W-1:0] csr_address,
  input  logic                  csr_read,
  input  logic                  csr_write,
  input  logic [CSR_DATA_W-1:0] csr_writedata,
  output logic [CSR_DATA_W-1:0] csr_readdata,
  output logic                  csr_readdatavalid,
  output logic                  csr_waitrequest,

  // -------- HOST GMM master (PCIe side) --------
  output logic [HADDR_W-1:0]    host_address,
  output logic                  host_read,
  output logic                  host_write,
  output logic [DATA_W-1:0]     host_writedata,
  output logic [BE_W-1:0]       host_byteenable,
  output logic [BCW-1:0]        host_burstcount,
  input  logic                  host_waitrequest,
  input  logic [DATA_W-1:0]     host_readdata,
  input  logic                  host_readdatavalid,
  input  logic [1:0]            host_response,  // PCIe completion status (00=OKAY) on read beats

  // -------- SYS GMM master (local system bus) --------
  output logic [SADDR_W-1:0]    sys_address,
  output logic                  sys_read,
  output logic                  sys_write,
  output logic [DATA_W-1:0]     sys_writedata,
  output logic [BE_W-1:0]       sys_byteenable,
  output logic [BCW-1:0]        sys_burstcount,
  input  logic                  sys_waitrequest,
  input  logic [DATA_W-1:0]     sys_readdata,
  input  logic                  sys_readdatavalid,

  // -------- SYS bus error / clear (to/from the selected adapter) --------
  input  logic                  sys_bus_err,    // sticky bus-error from adapter
  output logic                  sys_clr,        // clears the adapter's sticky error

  // -------- HOST bus error (PCIe completion status) --------
  output logic                  host_bus_error, // sticky: a HOST read returned a non-OK response

  // -------- interrupt --------
  output logic                  irq
);

  localparam int unsigned LBE  = $clog2(BE_W);
  localparam int unsigned LDB  = $clog2(DESC_BYTES);   // descriptor alignment

  // ---- elaboration-time parameter legality checks (dma_pkg invariants) ----
  // Instantiated only when violated; a legal config produces no generate block.
  if ((DESC_BITS % DATA_W) != 0) begin : gen_dataw_div_check
    $error("dma_pkg: DATA_W (%0d) must divide the %0d-bit descriptor word",
           DATA_W, DESC_BITS);
  end
  if ((MAX_BURST_BEATS * BE_W) > 1024) begin : gen_burst_boundary_check
    $error("dma_pkg: MAX_BURST_BEATS*BE_W (%0d bytes) must be <= 1024 (1 KiB boundary)",
           MAX_BURST_BEATS * BE_W);
  end

  // -------- control / status bundle --------
  logic               go, abort;
  logic [HADDR_W-1:0] desc_base;
  logic [LEN_W-1:0]   desc_count;
  logic               busy, done_sticky, error_sticky;
  logic [7:0]         err_code;
  logic [LEN_W-1:0]   cur_index;
  logic [3:0]         state_dbg;
  logic               irq_done_set, irq_error_set;

  // -------- descriptor fetch wires --------
  logic               f_start, f_valid;
  logic [LEN_W-1:0]   f_index;
  logic [HADDR_W-1:0] f_base;
  logic [HADDR_W-1:0] f_host_addr;
  logic [SADDR_W-1:0] f_sys_addr;
  logic [LEN_W-1:0]   f_length;
  logic               f_dir, f_irq, f_last, f_owned;

  // fetch GMM (-> arbiter m0)
  logic [HADDR_W-1:0] fm_address;
  logic               fm_read, fm_write;
  logic [DATA_W-1:0]  fm_writedata;
  logic [BE_W-1:0]    fm_byteenable;
  logic [BCW-1:0]     fm_burstcount;
  logic               fm_waitrequest;
  logic [DATA_W-1:0]  fm_readdata;
  logic               fm_readdatavalid;

  // -------- data mover wires --------
  logic               m_start, m_done;
  logic [HADDR_W-1:0] m_host_addr;
  logic [SADDR_W-1:0] m_sys_addr;
  logic [LEN_W-1:0]   m_length;
  logic               m_dir;

  // mover HOST GMM (-> arbiter m1)
  logic [HADDR_W-1:0] mh_address;
  logic               mh_read, mh_write;
  logic [DATA_W-1:0]  mh_writedata;
  logic [BE_W-1:0]    mh_byteenable;
  logic [BCW-1:0]     mh_burstcount;
  logic               mh_waitrequest;
  logic [DATA_W-1:0]  mh_readdata;
  logic               mh_readdatavalid;

  logic               clr;        // soft-clear pulse to sub-blocks (abort)
  logic               sys_err_latched;
  logic               host_err_latched;

  assign sys_clr        = clr;           // abort clears the adapter's sticky error too
  assign host_bus_error = host_err_latched; // surfaced at top, cleared by ABORT

  // =================================================================
  // CSR file
  // =================================================================
  dma_csr u_csr (
    .clk(clk), .rst_n(rst_n),
    .csr_address(csr_address), .csr_read(csr_read), .csr_write(csr_write),
    .csr_writedata(csr_writedata), .csr_readdata(csr_readdata),
    .csr_readdatavalid(csr_readdatavalid), .csr_waitrequest(csr_waitrequest),
    .go(go), .abort(abort),
    .desc_base(desc_base), .desc_count(desc_count),
    .busy(busy), .done(done_sticky), .error(error_sticky),
    .err_code(err_code), .cur_index(cur_index), .state(state_dbg),
    .irq_done_set(irq_done_set), .irq_error_set(irq_error_set),
    .irq(irq)
  );

  // =================================================================
  // Descriptor fetch
  // =================================================================
  dma_descriptor_fetch u_fetch (
    .clk(clk), .rst_n(rst_n), .clr(clr),
    .start(f_start), .index(f_index), .base_addr(f_base),
    .valid(f_valid),
    .d_host_addr(f_host_addr), .d_sys_addr(f_sys_addr), .d_length(f_length),
    .d_dir(f_dir), .d_irq(f_irq), .d_last(f_last), .d_owned(f_owned),
    .m_address(fm_address), .m_read(fm_read), .m_write(fm_write),
    .m_writedata(fm_writedata), .m_byteenable(fm_byteenable),
    .m_burstcount(fm_burstcount), .m_waitrequest(fm_waitrequest),
    .m_readdata(fm_readdata), .m_readdatavalid(fm_readdatavalid)
  );

  // =================================================================
  // Data mover
  // =================================================================
  dma_data_mover u_mover (
    .clk(clk), .rst_n(rst_n), .clr(clr),
    .start(m_start), .host_addr(m_host_addr), .sys_addr(m_sys_addr),
    .length(m_length), .dir(m_dir),
    .busy(/* unused: core derives busy from estate below */), .done(m_done),
    .h_address(mh_address), .h_read(mh_read), .h_write(mh_write),
    .h_writedata(mh_writedata), .h_byteenable(mh_byteenable),
    .h_burstcount(mh_burstcount), .h_waitrequest(mh_waitrequest),
    .h_readdata(mh_readdata), .h_readdatavalid(mh_readdatavalid),
    .s_address(sys_address), .s_read(sys_read), .s_write(sys_write),
    .s_writedata(sys_writedata), .s_byteenable(sys_byteenable),
    .s_burstcount(sys_burstcount), .s_waitrequest(sys_waitrequest),
    .s_readdata(sys_readdata), .s_readdatavalid(sys_readdatavalid)
  );

  // =================================================================
  // HOST-port arbiter (m0 = fetch, m1 = mover)
  // =================================================================
  dma_arbiter u_arb (
    .clk(clk), .rst_n(rst_n), .clr(clr),
    .m0_address(fm_address), .m0_read(fm_read), .m0_write(fm_write),
    .m0_writedata(fm_writedata), .m0_byteenable(fm_byteenable),
    .m0_burstcount(fm_burstcount), .m0_waitrequest(fm_waitrequest),
    .m0_readdata(fm_readdata), .m0_readdatavalid(fm_readdatavalid),
    .m1_address(mh_address), .m1_read(mh_read), .m1_write(mh_write),
    .m1_writedata(mh_writedata), .m1_byteenable(mh_byteenable),
    .m1_burstcount(mh_burstcount), .m1_waitrequest(mh_waitrequest),
    .m1_readdata(mh_readdata), .m1_readdatavalid(mh_readdatavalid),
    .o_address(host_address), .o_read(host_read), .o_write(host_write),
    .o_writedata(host_writedata), .o_byteenable(host_byteenable),
    .o_burstcount(host_burstcount), .o_waitrequest(host_waitrequest),
    .o_readdata(host_readdata), .o_readdatavalid(host_readdatavalid)
  );

  // =================================================================
  // Descriptor-ring walk FSM
  // =================================================================
  typedef enum logic [2:0] {
    E_IDLE, E_FETCH, E_FETCH_WAIT, E_RUN, E_DONE, E_ERROR
  } estate_e;
  estate_e estate;

  logic [LEN_W-1:0]   idx, cnt;
  logic [HADDR_W-1:0] base;
  logic               cur_irq, cur_last;

  assign state_dbg = {1'b0, estate};
  assign busy      = (estate == E_FETCH) || (estate == E_FETCH_WAIT) || (estate == E_RUN);
  assign cur_index = idx;
  assign clr       = abort;
  assign f_index   = idx;
  assign f_base    = base;
  assign m_host_addr = f_host_addr;   // latched-stable fetch outputs (see note)
  assign m_sys_addr  = f_sys_addr;
  assign m_length    = f_length;
  assign m_dir       = f_dir;

  // descriptor validity checks (combinational on fetched fields)
  logic bad_len, bad_align, bad_owned;
  assign bad_owned = !f_owned;
  assign bad_len   = (f_length == 0) || (f_length[LBE-1:0] != '0);
  assign bad_align = (f_host_addr[LBE-1:0] != '0) || (f_sys_addr[LBE-1:0] != '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      estate        <= E_IDLE;
      idx           <= '0;
      cnt           <= '0;
      base          <= '0;
      cur_irq       <= 1'b0;
      cur_last      <= 1'b0;
      err_code      <= ERR_NONE[7:0];
      done_sticky   <= 1'b0;
      error_sticky  <= 1'b0;
      f_start       <= 1'b0;
      m_start       <= 1'b0;
      irq_done_set  <= 1'b0;
      irq_error_set <= 1'b0;
    end else begin
      // default pulse clears
      f_start       <= 1'b0;
      m_start       <= 1'b0;
      irq_done_set  <= 1'b0;
      irq_error_set <= 1'b0;

      if (abort) begin
        estate       <= E_IDLE;
        done_sticky  <= 1'b0;
        error_sticky <= 1'b0;
      end else begin
        unique case (estate)
          E_IDLE: begin
            if (go) begin
              base         <= desc_base;
              cnt          <= desc_count;
              idx          <= '0;
              done_sticky  <= 1'b0;
              error_sticky <= 1'b0;
              err_code     <= ERR_NONE[7:0];
              if (desc_base[LDB-1:0] != '0) begin
                err_code <= ERR_BAD_BASE[7:0];   // ring base must be DESC_BYTES aligned
                estate   <= E_ERROR;
              end else if (desc_count == 0) begin
                estate <= E_DONE;
              end else begin
                f_start <= 1'b1;          // launch first fetch
                estate  <= E_FETCH;
              end
            end
          end

          E_FETCH: begin
            // fetch in flight (f_start was pulsed entering here)
            estate <= E_FETCH_WAIT;
          end

          E_FETCH_WAIT: begin
            if (f_valid) begin
              if (host_err_latched) begin
                // the descriptor fetch read itself failed -> contents unreliable
                err_code <= ERR_HOST_BUS[7:0]; estate <= E_ERROR;
              end else if (bad_owned) begin
                err_code <= ERR_DESC_INV[7:0]; estate <= E_ERROR;
              end else if (bad_len) begin
                err_code <= ERR_BAD_LEN[7:0];  estate <= E_ERROR;
              end else if (bad_align) begin
                err_code <= ERR_BAD_ALIGN[7:0]; estate <= E_ERROR;
              end else begin
                cur_irq  <= f_irq;
                cur_last <= f_last;
                m_start  <= 1'b1;          // launch the move
                estate   <= E_RUN;
              end
            end
          end

          E_RUN: begin
            if (m_done) begin
              if (host_err_latched) begin
                err_code <= ERR_HOST_BUS[7:0];       // HOST/PCIe bus error during the move
                estate   <= E_ERROR;
              end else if (sys_err_latched) begin
                err_code <= ERR_SYS_BUS[7:0];        // SYS bus error during the move
                estate   <= E_ERROR;
              end else begin
                idx <= idx + 1'b1;
                if (cur_irq) irq_done_set <= 1'b1;   // per-descriptor IRQ
                if (cur_last || ((idx + 1'b1) == cnt)) begin
                  estate <= E_DONE;
                end else begin
                  f_start <= 1'b1;         // fetch next descriptor
                  estate  <= E_FETCH;
                end
              end
            end
          end

          E_DONE: begin
            done_sticky  <= 1'b1;
            irq_done_set <= 1'b1;          // ring-completion IRQ
            estate       <= E_IDLE;
          end

          E_ERROR: begin
            error_sticky  <= 1'b1;
            irq_error_set <= 1'b1;
            estate        <= E_IDLE;
          end

          default: estate <= E_IDLE;
        endcase
      end
    end
  end

  // latch a SYS bus error seen during the active move (cleared per move / abort)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               sys_err_latched <= 1'b0;
    else if (clr || m_start)  sys_err_latched <= 1'b0;
    else if (sys_bus_err)     sys_err_latched <= 1'b1;
  end

  // latch a HOST/PCIe read-completion error. The HOST port is shared by the
  // descriptor fetch and the data move, so this is re-armed at the start of each
  // fetch (f_start) and each move (m_start) and cleared by abort (clr); a non-OK
  // response on any host read beat sets it sticky until the owning phase checks
  // it (E_FETCH_WAIT / E_RUN) or ABORT clears it.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                          host_err_latched <= 1'b0;
    else if (clr || f_start || m_start)  host_err_latched <= 1'b0;
    else if (host_readdatavalid && (host_response != HRESP_OKAY))
                                         host_err_latched <= 1'b1;
  end

endmodule
