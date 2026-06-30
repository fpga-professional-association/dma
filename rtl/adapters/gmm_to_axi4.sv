//============================================================================
// gmm_to_axi4.sv -- GMM (Avalon-MM pipelined) -> AXI4 master
//
// Translates the core's single-outstanding GMM bursts into AXI4 transactions:
//   * read  burst -> one AR + N R beats (RREADY held high -- the core always
//                    sinks read data, guaranteed by FIFO reservation)
//   * write burst -> one AW + N W beats (WLAST on the Nth) + one B response
//
// AXI rules honored: VALID never waits on READY, payload/VALID stable until
// handshake, AWBURST/ARBURST = INCR, single ID. Bursts are pre-bounded by the
// data mover so AWLEN/ARLEN <= MAX_BURST_BEATS-1 and never cross 4 KiB.
//============================================================================

module gmm_to_axi4 #(
  parameter int unsigned AW  = dma_pkg::SADDR_W,
  parameter int unsigned DW  = dma_pkg::DATA_W,
  parameter int unsigned BCW = dma_pkg::BCW,
  parameter int unsigned IDW = 1
) (
  input  logic            clk,
  input  logic            rst_n,

  // -------- GMM slave (from core SYS master) --------
  input  logic [AW-1:0]   gmm_address,
  input  logic            gmm_read,
  input  logic            gmm_write,
  input  logic [DW-1:0]   gmm_writedata,
  input  logic [DW/8-1:0] gmm_byteenable,
  input  logic [BCW-1:0]  gmm_burstcount,
  output logic            gmm_waitrequest,
  output logic [DW-1:0]   gmm_readdata,
  output logic            gmm_readdatavalid,

  // -------- AXI4 master: write address --------
  output logic [IDW-1:0]  axi_awid,
  output logic [AW-1:0]   axi_awaddr,
  output logic [7:0]      axi_awlen,
  output logic [2:0]      axi_awsize,
  output logic [1:0]      axi_awburst,
  output logic [3:0]      axi_awcache,
  output logic [2:0]      axi_awprot,
  output logic            axi_awvalid,
  input  logic            axi_awready,
  // write data
  output logic [DW-1:0]   axi_wdata,
  output logic [DW/8-1:0] axi_wstrb,
  output logic            axi_wlast,
  output logic            axi_wvalid,
  input  logic            axi_wready,
  // write response
  /* verilator lint_off UNUSEDSIGNAL */  // bid: single ID; bresp[0]: only [1]=error used
  input  logic [IDW-1:0]  axi_bid,
  input  logic [1:0]      axi_bresp,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic            axi_bvalid,
  output logic            axi_bready,
  // read address
  output logic [IDW-1:0]  axi_arid,
  output logic [AW-1:0]   axi_araddr,
  output logic [7:0]      axi_arlen,
  output logic [2:0]      axi_arsize,
  output logic [1:0]      axi_arburst,
  output logic [3:0]      axi_arcache,
  output logic [2:0]      axi_arprot,
  output logic            axi_arvalid,
  input  logic            axi_arready,
  // read data
  /* verilator lint_off UNUSEDSIGNAL */  // rid: single ID; rresp[0]: only [1]=error used
  input  logic [IDW-1:0]  axi_rid,
  input  logic [DW-1:0]   axi_rdata,
  input  logic [1:0]      axi_rresp,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic            axi_rlast,
  input  logic            axi_rvalid,
  output logic            axi_rready,

  input  logic            clr,         // clears the sticky error (abort)
  output logic            err          // sticky: a non-OKAY response was seen
);

  localparam logic [1:0] BURST_INCR = 2'b01;
  localparam logic [2:0] AXSIZE     = 3'($clog2(DW/8));

  // elaboration-time check: AXI AWLEN/ARLEN are 8 bits, so the GMM burstcount
  // width (beats-1) must fit; the {{(8-BCW){...}}} pad underflows when BCW > 8.
  if (BCW > 8) begin : gen_axlen_width_check
    $error("gmm_to_axi4: BCW (%0d) exceeds the 8-bit AXI AWLEN/ARLEN field", BCW);
  end

  // AX_W presents AW and W concurrently (aw_done/w_done track which has
  // completed) so the adapter is robust against a slave that gates AWREADY on
  // WVALID, and against any legal AW/W ordering.
  typedef enum logic [2:0] {AX_IDLE, AX_RA, AX_RD, AX_W, AX_WB} st_e;
  st_e            st;
  logic [BCW-1:0] wbeat;            // write beats sent so far
  logic           aw_done, w_done;  // AW handshaked / all W beats sent
  logic [AW-1:0]  aw_addr_q;        // latched write address
  logic [BCW-1:0] aw_len_q;         // latched write burst length (beats-1)

  // constant qualifiers
  assign axi_awid    = '0;
  assign axi_arid    = '0;
  assign axi_awburst = BURST_INCR;
  assign axi_arburst = BURST_INCR;
  assign axi_awsize  = AXSIZE;
  assign axi_arsize  = AXSIZE;
  assign axi_awcache = 4'b0011;     // normal non-cacheable bufferable
  assign axi_arcache = 4'b0011;
  assign axi_awprot  = 3'b000;
  assign axi_arprot  = 3'b000;

  // Write address/length are LATCHED at burst start: the W beats may all be
  // accepted before AWREADY, after which the GMM master is free to move on, so
  // AWADDR/AWLEN must not track live gmm_*. Read uses live gmm_* (single AR
  // command, master holds it until ARREADY).
  assign axi_awaddr  = aw_addr_q;
  assign axi_awlen   = {{(8-BCW){1'b0}}, aw_len_q};
  assign axi_araddr  = gmm_address;
  assign axi_arlen   = {{(8-BCW){1'b0}}, (gmm_burstcount - 1'b1)};
  assign axi_wdata   = gmm_writedata;
  assign axi_wstrb   = gmm_byteenable;
  assign axi_wlast   = (wbeat == aw_len_q);

  // channel valid/ready (AW and W presented together, each retired independently)
  assign axi_arvalid = (st == AX_RA);
  assign axi_rready  = (st == AX_RD);
  assign axi_awvalid = (st == AX_W) && !aw_done;
  assign axi_wvalid  = (st == AX_W) && !w_done;
  assign axi_bready  = (st == AX_WB);

  // GMM responses
  assign gmm_readdata      = axi_rdata;
  assign gmm_readdatavalid = (st == AX_RD) && axi_rvalid;

  // handshake events
  wire aw_fire = axi_awvalid && axi_awready;
  wire w_fire  = axi_wvalid  && axi_wready;

  // back-pressure: read command accepted on ARREADY, each write beat on WREADY
  always_comb begin
    unique case (st)
      AX_RA:   gmm_waitrequest = !axi_arready;
      AX_W:    gmm_waitrequest = w_done ? 1'b1 : !axi_wready;
      default: gmm_waitrequest = 1'b1;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st      <= AX_IDLE;
      wbeat   <= '0;
      aw_done <= 1'b0;
      w_done  <= 1'b0;
    end else begin
      unique case (st)
        AX_IDLE: begin
          wbeat     <= '0;
          aw_done   <= 1'b0;
          w_done    <= 1'b0;
          aw_addr_q <= gmm_address;
          aw_len_q  <= gmm_burstcount - 1'b1;
          if (gmm_write)     st <= AX_W;
          else if (gmm_read) st <= AX_RA;
        end
        AX_RA: if (axi_arready) st <= AX_RD;
        AX_RD: if (axi_rvalid && axi_rlast) st <= AX_IDLE;
        AX_W: begin
          if (aw_fire) aw_done <= 1'b1;
          if (w_fire) begin
            if (axi_wlast) w_done <= 1'b1;
            else           wbeat  <= wbeat + 1'b1;
          end
          // advance once AW has handshaked and the last W beat has been sent
          if ((aw_done || aw_fire) && (w_done || (w_fire && axi_wlast)))
            st <= AX_WB;
        end
        AX_WB: if (axi_bvalid) st <= AX_IDLE;
        default: st <= AX_IDLE;
      endcase
    end
  end

  // sticky bus-error (RRESP/BRESP non-OKAY), clearable by clr/abort
  wire rresp_err = (st == AX_RD) && axi_rvalid && axi_rresp[1];
  wire bresp_err = (st == AX_WB) && axi_bvalid && axi_bresp[1];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                     err <= 1'b0;
    else if (clr)                   err <= 1'b0;
    else if (rresp_err || bresp_err) err <= 1'b1;
  end

endmodule
