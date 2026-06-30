//============================================================================
// gmm_to_ahb.sv -- GMM (Avalon-MM pipelined) -> AHB-Lite master
//
// Translates the core's single-outstanding GMM bursts into AHB-Lite INCR
// bursts. The AHB address/data pipeline is handled with a single-depth
// `dp_pending` flag (AHB-Lite has exactly one outstanding data phase):
//
//   * read  : GMM read command accepted in one cycle, then N address phases
//             are issued (NONSEQ, then SEQ); each completed data phase yields a
//             readdatavalid beat (the core always sinks read data).
//   * write : each address phase consumes one GMM write beat into hwdata_q,
//             which drives HWDATA during the following data phase.
//
// Bursts are pre-bounded by the data mover (<= MAX_BURST_BEATS, never crossing
// a 1 KiB boundary), so a plain INCR burst is always legal. Full-word transfers
// only (HSIZE = bus width); HRESP!=OKAY sets a sticky error.
//============================================================================

module gmm_to_ahb #(
  parameter int unsigned AW  = dma_pkg::SADDR_W,
  parameter int unsigned DW  = dma_pkg::DATA_W,
  parameter int unsigned BCW = dma_pkg::BCW
) (
  input  logic            clk,
  input  logic            rst_n,

  // -------- GMM slave (from core SYS master) --------
  input  logic [AW-1:0]   gmm_address,
  input  logic            gmm_read,
  input  logic            gmm_write,
  input  logic [DW-1:0]   gmm_writedata,
  input  logic [DW/8-1:0] gmm_byteenable,   // ignored: full-word transfers only
  input  logic [BCW-1:0]  gmm_burstcount,
  output logic            gmm_waitrequest,
  output logic [DW-1:0]   gmm_readdata,
  output logic            gmm_readdatavalid,

  // -------- AHB-Lite master --------
  output logic [AW-1:0]   haddr,
  output logic [2:0]      hburst,
  output logic [2:0]      hsize,
  output logic [1:0]      htrans,
  output logic            hwrite,
  output logic [DW-1:0]   hwdata,
  input  logic [DW-1:0]   hrdata,
  input  logic            hready,
  input  logic            hresp,           // AHB-Lite single-bit: 0=OKAY, 1=ERROR

  input  logic            clr,             // clears the sticky error (abort)
  output logic            err              // sticky: HRESP error was seen
);

  localparam logic [1:0] HT_IDLE   = 2'b00;
  localparam logic [1:0] HT_NONSEQ = 2'b10;
  localparam logic [1:0] HT_SEQ    = 2'b11;
  localparam logic [2:0] HB_INCR   = 3'b001;
  localparam logic [2:0] HSIZE_W   = 3'($clog2(DW/8));
  localparam int unsigned LBE      = $clog2(DW/8);

  typedef enum logic [1:0] {H_IDLE, H_READ, H_WRITE} st_e;
  st_e            st;
  logic [BCW-1:0] n;            // beats in the active burst
  logic [BCW-1:0] a_idx;        // address phases issued
  logic [BCW-1:0] d_idx;        // data phases completed
  logic           dp_pending;   // a data phase is in progress this cycle
  logic [AW-1:0]  base;
  logic [DW-1:0]  hwdata_q;

  // are we presenting an address phase this cycle?
  logic issuing;
  assign issuing = ((st == H_READ) || (st == H_WRITE)) && (a_idx < n);

  // ---- AHB address-phase outputs ----
  assign htrans = issuing ? ((a_idx == '0) ? HT_NONSEQ : HT_SEQ) : HT_IDLE;
  assign hburst = HB_INCR;
  assign hsize  = HSIZE_W;
  assign hwrite = (st == H_WRITE);
  assign haddr  = base + ({{(AW-BCW){1'b0}}, a_idx} << LBE);
  assign hwdata = hwdata_q;

  // ---- GMM responses ----
  assign gmm_readdata      = hrdata;
  assign gmm_readdatavalid = (st == H_READ) && dp_pending && hready;

  // ---- GMM back-pressure ----
  always_comb begin
    unique case (st)
      H_IDLE:  gmm_waitrequest = gmm_read ? 1'b0 : 1'b1;  // read cmd accepted instantly
      H_WRITE: gmm_waitrequest = issuing ? !hready : 1'b1; // accept a beat per addr phase
      default: gmm_waitrequest = 1'b1;                     // H_READ: no more GMM handshakes
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st         <= H_IDLE;
      n          <= '0;
      a_idx      <= '0;
      d_idx      <= '0;
      dp_pending <= 1'b0;
      base       <= '0;
      hwdata_q   <= '0;
    end else begin
      unique case (st)
        H_IDLE: begin
          a_idx      <= '0;
          d_idx      <= '0;
          dp_pending <= 1'b0;
          base       <= gmm_address;
          n          <= gmm_burstcount;
          if (gmm_read)       st <= H_READ;
          else if (gmm_write) st <= H_WRITE;
        end

        H_READ, H_WRITE: begin
          if (hready) begin
            // capture write data for the just-accepted address phase
            if ((st == H_WRITE) && issuing) hwdata_q <= gmm_writedata;

            // a data phase completes this cycle
            if (dp_pending) begin
              if (d_idx == (n - 1'b1)) begin
                st         <= H_IDLE;       // last beat done
                dp_pending <= 1'b0;
              end else begin
                d_idx      <= d_idx + 1'b1;
              end
            end

            // accept the address phase presented this cycle
            if (issuing) a_idx <= a_idx + 1'b1;

            // next-cycle data phase exists iff we issued an address this cycle,
            // unless we are finishing the final beat (handled above).
            if (!(dp_pending && (d_idx == (n - 1'b1))))
              dp_pending <= issuing;
          end
        end

        default: st <= H_IDLE;
      endcase
    end
  end

  // sticky bus-error: HRESP=ERROR sampled on a completing data phase, clearable
  // by clr/abort. (A fully-compliant AHB master also two-cycle-aborts the burst
  // on ERROR; here the burst is bounded and the error is reported to the engine.)
  wire dphase_err = ((st == H_READ) || (st == H_WRITE)) && hready && dp_pending && hresp;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          err <= 1'b0;
    else if (clr)        err <= 1'b0;
    else if (dphase_err) err <= 1'b1;
  end

  // tie-off unused byteenable (full-word transfers)
  wire _unused = &{1'b0, gmm_byteenable};

endmodule
