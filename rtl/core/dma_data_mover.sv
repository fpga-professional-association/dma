//============================================================================
// dma_data_mover.sv -- Bidirectional read->FIFO->write data mover
//
// Moves `length` bytes for one descriptor. Two independent role engines (a read
// engine and a write engine) share a show-ahead FIFO. A direction crossbar binds
// the read/write roles onto the HOST and SYS GMM ports:
//
//   H2C (dir=0): read HOST(host_addr) -> FIFO -> write SYS(sys_addr)
//   C2H (dir=1): read SYS(sys_addr)   -> FIFO -> write HOST(host_addr)
//
// Bursts are sized so they never exceed MAX_BURST_BEATS and never cross a 1 KiB
// boundary (the tightest, AHB), keeping every bus adapter trivially compliant.
// The read engine reserves FIFO space before issuing, so reads never overflow;
// the write engine only drains beats that are present, so writes never underrun.
//============================================================================

module dma_data_mover
  import dma_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,
  input  logic               clr,            // abort/soft-clear

  // command
  input  logic               start,          // 1-cycle pulse
  input  logic [HADDR_W-1:0] host_addr,
  input  logic [SADDR_W-1:0] sys_addr,
  input  logic [LEN_W-1:0]   length,         // bytes (multiple of BE_W, validated upstream)
  input  logic               dir,            // dir_e

  output logic               busy,
  output logic               done,           // 1-cycle pulse when descriptor complete

  // HOST GMM master (PCIe side, via arbiter)
  output logic [HADDR_W-1:0] h_address,
  output logic               h_read,
  output logic               h_write,
  output logic [DATA_W-1:0]  h_writedata,
  output logic [BE_W-1:0]    h_byteenable,
  output logic [BCW-1:0]     h_burstcount,
  input  logic               h_waitrequest,
  input  logic [DATA_W-1:0]  h_readdata,
  input  logic               h_readdatavalid,

  // SYS GMM master (local system bus)
  output logic [SADDR_W-1:0] s_address,
  output logic               s_read,
  output logic               s_write,
  output logic [DATA_W-1:0]  s_writedata,
  output logic [BE_W-1:0]    s_byteenable,
  output logic [BCW-1:0]     s_burstcount,
  input  logic               s_waitrequest,
  input  logic [DATA_W-1:0]  s_readdata,
  input  logic               s_readdatavalid
);

  localparam int unsigned LBE   = $clog2(BE_W);          // log2(bytes per beat)
  localparam int unsigned DEPTH = FIFO_DEPTH;
  localparam int unsigned LVLW  = $clog2(DEPTH) + 1;

  // ---------------- latched command ----------------
  logic                running, dir_q;

  // ---------------- FIFO ----------------
  logic              fifo_wr, fifo_rd, fifo_empty;
  logic [DATA_W-1:0] fifo_wdata, fifo_rdata;
  logic [LVLW-1:0]   fifo_level;

  dma_fifo #(.WIDTH(DATA_W), .DEPTH(DEPTH)) u_fifo (
    .clk(clk), .rst_n(rst_n), .clr(clr),
    .wr_en(fifo_wr), .wr_data(fifo_wdata),
    .full(/* unused: read engine reserves space via fifo_level/r_space */),
    .rd_en(fifo_rd), .rd_data(fifo_rdata), .empty(fifo_empty),
    .level(fifo_level)
  );

  // ---------------- READ engine (role) ----------------
  typedef enum logic [1:0] {R_IDLE, R_CMD, R_DATA} rstate_e;
  rstate_e            rstate;
  logic [HADDR_W-1:0] r_addr;
  logic [LEN_W-1:0]   r_rem;        // beats left to read
  logic               r_read_q;
  logic [BCW-1:0]     r_burstcount_q;
  logic [BCW-1:0]     r_blen;       // length of in-flight read burst
  logic [BCW-1:0]     r_dcnt;       // data beats still expected

  // role read response (muxed by direction crossbar, below)
  logic               r_waitrequest, r_readdatavalid;
  logic [DATA_W-1:0]  r_readdata;

  // ---------------- WRITE engine (role) ----------------
  typedef enum logic [0:0] {W_IDLE, W_BURST} wstate_e;
  wstate_e            wstate;
  logic [HADDR_W-1:0] w_addr;
  logic [LEN_W-1:0]   w_rem;        // beats left to write
  logic               w_write_q;
  logic [BCW-1:0]     w_burstcount_q;
  logic [BCW-1:0]     w_blen;       // length of in-flight write burst
  logic [BCW-1:0]     w_dcnt;       // beats still to send in current burst

  logic               w_waitrequest;

  // ---------------- burst sizing helpers ----------------
  // beats remaining until the next 1 KiB boundary from `a`
  // (uses shifts/casts, no in-process constant part-selects, for tool portability)
  function automatic [LEN_W-1:0] beats_to_boundary(input logic [HADDR_W-1:0] a);
    /* verilator lint_off UNUSEDSIGNAL */  // only low 10 bits (a mod 1024) are used
    logic [HADDR_W-1:0] a_lo;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [LEN_W-1:0]   bytes_to_b;
    a_lo       = a - ((a >> 10) << 10);          // a mod 1024
    bytes_to_b = 32'd1024 - LEN_W'(a_lo);        // 1 .. 1024
    beats_to_boundary = bytes_to_b >> LBE;
  endfunction

  function automatic [LEN_W-1:0] min3(input logic [LEN_W-1:0] x,
                                      input logic [LEN_W-1:0] y,
                                      input logic [LEN_W-1:0] z);
    logic [LEN_W-1:0] m;
    m = (x < y) ? x : y;
    m = (m < z) ? m : z;
    min3 = m;
  endfunction

  // read burst candidate: min(MAX, rem, boundary, fifo-space)
  logic [LEN_W-1:0] r_space, r_cand;
  logic             r_can_issue;
  always_comb begin
    r_space     = LEN_W'(DEPTH) - LEN_W'(fifo_level);
    r_cand      = min3(LEN_W'(MAX_BURST_BEATS), r_rem, beats_to_boundary(r_addr));
    if (r_space < r_cand) r_cand = r_space;
    r_can_issue = (rstate == R_IDLE) && (r_rem != 0) && (r_cand != 0);
  end

  // write burst candidate: min(MAX, rem, boundary), gated by available beats
  logic [LEN_W-1:0] w_avail, w_bmax, w_cand;
  logic             read_complete, w_can_issue;
  always_comb begin
    w_avail       = LEN_W'(fifo_level);
    w_bmax        = min3(LEN_W'(MAX_BURST_BEATS), w_rem, beats_to_boundary(w_addr));
    read_complete = (r_rem == 0) && (rstate == R_IDLE);
    w_cand        = (w_avail < w_bmax) ? w_avail : w_bmax;
    w_can_issue   = (wstate == W_IDLE) && (w_rem != 0) && (w_cand != 0) &&
                    ((w_avail >= w_bmax) || read_complete);
  end

  // =================================================================
  // Command latch / completion
  // =================================================================
  assign busy = running;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      running     <= 1'b0;
      dir_q       <= 1'b0;
      done        <= 1'b0;
    end else begin
      done <= 1'b0;
      if (clr) begin
        running <= 1'b0;
      end else if (start) begin
        running <= 1'b1;
        dir_q   <= dir;
      end else if (running &&
                   (r_rem == 0) && (w_rem == 0) &&
                   (rstate == R_IDLE) && (wstate == W_IDLE) && fifo_empty) begin
        running <= 1'b0;
        done    <= 1'b1;
      end
    end
  end

  // =================================================================
  // READ engine FSM
  // =================================================================
  assign fifo_wr    = (rstate == R_DATA) && r_readdatavalid;
  assign fifo_wdata = r_readdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate         <= R_IDLE;
      r_addr         <= '0;
      r_rem          <= '0;
      r_read_q       <= 1'b0;
      r_burstcount_q <= '0;
      r_blen         <= '0;
      r_dcnt         <= '0;
    end else if (clr) begin
      rstate   <= R_IDLE;
      r_read_q <= 1'b0;
      r_rem    <= '0;
    end else if (start) begin
      rstate <= R_IDLE;
      r_addr <= (dir == DIR_H2C) ? host_addr : {{(HADDR_W-SADDR_W){1'b0}}, sys_addr};
      r_rem  <= length >> LBE;
      r_read_q <= 1'b0;
    end else begin
      unique case (rstate)
        R_IDLE: begin
          if (r_can_issue) begin
            r_read_q       <= 1'b1;
            r_burstcount_q <= r_cand[BCW-1:0];
            r_blen         <= r_cand[BCW-1:0];
            rstate         <= R_CMD;
          end
        end
        R_CMD: begin
          if (!r_waitrequest) begin
            r_read_q <= 1'b0;          // single burst command accepted
            r_dcnt   <= r_blen;
            rstate   <= R_DATA;
          end
        end
        R_DATA: begin
          if (r_readdatavalid) begin
            if (r_dcnt == BCW'(1)) begin
              r_addr <= r_addr + ({{(HADDR_W-BCW){1'b0}}, r_blen} << LBE);
              r_rem  <= r_rem - {{(LEN_W-BCW){1'b0}}, r_blen};
              rstate <= R_IDLE;
            end else begin
              r_dcnt <= r_dcnt - BCW'(1);
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  // =================================================================
  // WRITE engine FSM
  // =================================================================
  logic w_accept;
  assign w_accept = (wstate == W_BURST) && w_write_q && !w_waitrequest;
  assign fifo_rd  = w_accept;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate         <= W_IDLE;
      w_addr         <= '0;
      w_rem          <= '0;
      w_write_q      <= 1'b0;
      w_burstcount_q <= '0;
      w_blen         <= '0;
      w_dcnt         <= '0;
    end else if (clr) begin
      wstate    <= W_IDLE;
      w_write_q <= 1'b0;
      w_rem     <= '0;
    end else if (start) begin
      wstate    <= W_IDLE;
      w_addr    <= (dir == DIR_H2C) ? {{(HADDR_W-SADDR_W){1'b0}}, sys_addr} : host_addr;
      w_rem     <= length >> LBE;
      w_write_q <= 1'b0;
    end else begin
      unique case (wstate)
        W_IDLE: begin
          if (w_can_issue) begin
            w_write_q      <= 1'b1;
            w_burstcount_q <= w_cand[BCW-1:0];
            w_blen         <= w_cand[BCW-1:0];
            w_dcnt         <= w_cand[BCW-1:0];
            wstate         <= W_BURST;
          end
        end
        W_BURST: begin
          if (w_accept) begin
            if (w_dcnt == BCW'(1)) begin
              w_write_q <= 1'b0;
              w_addr    <= w_addr + ({{(HADDR_W-BCW){1'b0}}, w_blen} << LBE);
              w_rem     <= w_rem - {{(LEN_W-BCW){1'b0}}, w_blen};
              wstate    <= W_IDLE;
            end else begin
              w_dcnt <= w_dcnt - BCW'(1);
            end
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  // =================================================================
  // Direction crossbar: bind read/write roles onto HOST / SYS ports
  // =================================================================
  // HOST port
  always_comb begin
    if (dir_q == DIR_H2C) begin       // HOST is the read source
      h_address    = r_addr;
      h_read       = r_read_q;
      h_write      = 1'b0;
      h_writedata  = '0;
      h_byteenable = {BE_W{1'b1}};
      h_burstcount = r_burstcount_q;
    end else begin                    // HOST is the write destination
      h_address    = w_addr;
      h_read       = 1'b0;
      h_write      = w_write_q;
      h_writedata  = fifo_rdata;
      h_byteenable = {BE_W{1'b1}};
      h_burstcount = w_burstcount_q;
    end
  end

  // SYS port
  always_comb begin
    if (dir_q == DIR_H2C) begin       // SYS is the write destination
      s_address    = SADDR_W'(w_addr);
      s_read       = 1'b0;
      s_write      = w_write_q;
      s_writedata  = fifo_rdata;
      s_byteenable = {BE_W{1'b1}};
      s_burstcount = w_burstcount_q;
    end else begin                    // SYS is the read source
      s_address    = SADDR_W'(r_addr);
      s_read       = r_read_q;
      s_write      = 1'b0;
      s_writedata  = '0;
      s_byteenable = {BE_W{1'b1}};
      s_burstcount = r_burstcount_q;
    end
  end

  // role response muxes
  assign r_waitrequest   = (dir_q == DIR_H2C) ? h_waitrequest   : s_waitrequest;
  assign r_readdata      = (dir_q == DIR_H2C) ? h_readdata      : s_readdata;
  assign r_readdatavalid = (dir_q == DIR_H2C) ? h_readdatavalid : s_readdatavalid;
  assign w_waitrequest   = (dir_q == DIR_H2C) ? s_waitrequest   : h_waitrequest;

endmodule
