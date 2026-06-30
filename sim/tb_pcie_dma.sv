// SPDX-License-Identifier: Apache-2.0
//============================================================================
// tb_pcie_dma.sv -- Self-checking integration testbench for pcie_dma_top
//
// Builds a 2-descriptor ring in host memory and runs:
//   desc0 : H2C  host[0x2000] -> sys[0x100]  256 bytes  (2 full 16-beat bursts)
//   desc1 : C2H  sys[0x200]   -> host[0x3000] 520 bytes  (crosses a 1 KiB
//                                                          boundary on the read)
// then checks both destinations and the completion interrupt.
//
// SYS bus selected at compile time:
//   (default)            -> Avalon-MM   sys slave
//   +define+USE_AXI      -> AXI4        sys slave
//   +define+USE_AHB      -> AHB-Lite    sys slave
// +define+STALLS adds pseudo-random bus back-pressure on every slave.
//============================================================================
`timescale 1ns/1ps

`ifdef USE_AXI
  `define SYSIF_STR "AXI4"
`elsif USE_AHB
  `define SYSIF_STR "AHB"
`else
  `define SYSIF_STR "AVALON"
`endif

`ifdef STALLS
  `define ST 1
`else
  `define ST 0
`endif

module tb_pcie_dma;
  import dma_pkg::*;

  localparam int DW  = DATA_W;
  localparam int HAW = HADDR_W;
  localparam int SAW = SADDR_W;

  // HOST fault-injection word: any host read of this address returns a non-OK
  // PCIe completion (response=SLVERR), exercising the ERR_HOST_BUS path (test G/H).
  localparam logic [63:0] HOST_ERR_ADDR = 64'h0000_4000;
  localparam int          HOST_ERR_WORD = HOST_ERR_ADDR >> $clog2(DW/8);

  // ---- clock / reset ----
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;            // 100 MHz

  // ---- CSR slave bus ----
  logic [CSR_ADDR_W-1:0] csr_address = '0;
  logic                  csr_read = 0, csr_write = 0;
  logic [CSR_DATA_W-1:0] csr_writedata = '0;
  logic [CSR_DATA_W-1:0] csr_readdata;
  logic                  csr_readdatavalid, csr_waitrequest;

  // ---- HOST Avalon-MM master ----
  logic [HAW-1:0] host_address;
  logic           host_read, host_write;
  logic [DW-1:0]  host_writedata;
  logic [BE_W-1:0] host_byteenable;
  logic [BCW-1:0] host_burstcount;
  logic           host_waitrequest;
  logic [DW-1:0]  host_readdata;
  logic           host_readdatavalid;
  logic [1:0]     host_response;

  // ---- SYS Avalon-MM master ----
  logic [SAW-1:0] avm_address;
  logic           avm_read, avm_write;
  logic [DW-1:0]  avm_writedata;
  logic [BE_W-1:0] avm_byteenable;
  logic [BCW-1:0] avm_burstcount;
  logic           avm_waitrequest;
  logic [DW-1:0]  avm_readdata;
  logic           avm_readdatavalid;

  // ---- SYS AXI4 master ----
  logic [0:0]     axi_awid, axi_bid, axi_arid, axi_rid;
  logic [SAW-1:0] axi_awaddr, axi_araddr;
  logic [7:0]     axi_awlen, axi_arlen;
  logic [2:0]     axi_awsize, axi_arsize, axi_awprot, axi_arprot;
  logic [1:0]     axi_awburst, axi_arburst, axi_bresp, axi_rresp;
  logic [3:0]     axi_awcache, axi_arcache;
  logic           axi_awvalid, axi_awready, axi_wvalid, axi_wready, axi_wlast;
  logic           axi_bvalid, axi_bready, axi_arvalid, axi_arready;
  logic           axi_rvalid, axi_rready, axi_rlast;
  logic [DW-1:0]  axi_wdata, axi_rdata;
  logic [BE_W-1:0] axi_wstrb;

  // ---- SYS AHB-Lite master ----
  logic [SAW-1:0] haddr;
  logic [2:0]     hburst, hsize;
  logic [1:0]     htrans;
  logic           hwrite, hready, hresp;
  logic [DW-1:0]  hwdata, hrdata;

  logic irq, sys_bus_error, host_bus_error;

  // =================================================================
  // DUT
  // =================================================================
  pcie_dma_top #(.SYS_IF(`SYSIF_STR)) dut (
    .clk, .rst_n,
    .csr_address, .csr_read, .csr_write, .csr_writedata,
    .csr_readdata, .csr_readdatavalid, .csr_waitrequest,
    .host_address, .host_read, .host_write, .host_writedata,
    .host_byteenable, .host_burstcount, .host_waitrequest,
    .host_readdata, .host_readdatavalid, .host_response,
    .avm_address, .avm_read, .avm_write, .avm_writedata,
    .avm_byteenable, .avm_burstcount, .avm_waitrequest,
    .avm_readdata, .avm_readdatavalid,
    .axi_awid, .axi_awaddr, .axi_awlen, .axi_awsize, .axi_awburst,
    .axi_awcache, .axi_awprot, .axi_awvalid, .axi_awready,
    .axi_wdata, .axi_wstrb, .axi_wlast, .axi_wvalid, .axi_wready,
    .axi_bid, .axi_bresp, .axi_bvalid, .axi_bready,
    .axi_arid, .axi_araddr, .axi_arlen, .axi_arsize, .axi_arburst,
    .axi_arcache, .axi_arprot, .axi_arvalid, .axi_arready,
    .axi_rid, .axi_rdata, .axi_rresp, .axi_rlast, .axi_rvalid, .axi_rready,
    .haddr, .hburst, .hsize, .htrans, .hwrite, .hwdata, .hrdata, .hready, .hresp,
    .irq, .sys_bus_error, .host_bus_error
  );

  // =================================================================
  // HOST memory (Avalon-MM slave)
  // =================================================================
  avalon_mem_model #(.AW(HAW), .DW(DW), .BCW(BCW), .STALL(`ST), .SEED(16'hA1A1),
                     .ERR_WORD(HOST_ERR_WORD))
  host_mem (
    .clk, .rst_n,
    .address(host_address), .read(host_read), .write(host_write),
    .writedata(host_writedata), .byteenable(host_byteenable),
    .burstcount(host_burstcount), .waitrequest(host_waitrequest),
    .readdata(host_readdata), .readdatavalid(host_readdatavalid),
    .response(host_response)
  );

  // =================================================================
  // SYS memory (selected slave) -- always named sys_mem
  // =================================================================
`ifdef USE_AXI
  axi_mem_model #(.AW(SAW), .DW(DW), .STALL(`ST)) sys_mem (
    .clk, .rst_n,
    .awid(axi_awid), .awaddr(axi_awaddr), .awlen(axi_awlen), .awsize(axi_awsize),
    .awburst(axi_awburst), .awcache(axi_awcache), .awprot(axi_awprot),
    .awvalid(axi_awvalid), .awready(axi_awready),
    .wdata(axi_wdata), .wstrb(axi_wstrb), .wlast(axi_wlast),
    .wvalid(axi_wvalid), .wready(axi_wready),
    .bid(axi_bid), .bresp(axi_bresp), .bvalid(axi_bvalid), .bready(axi_bready),
    .arid(axi_arid), .araddr(axi_araddr), .arlen(axi_arlen), .arsize(axi_arsize),
    .arburst(axi_arburst), .arcache(axi_arcache), .arprot(axi_arprot),
    .arvalid(axi_arvalid), .arready(axi_arready),
    .rid(axi_rid), .rdata(axi_rdata), .rresp(axi_rresp), .rlast(axi_rlast),
    .rvalid(axi_rvalid), .rready(axi_rready)
  );
`elsif USE_AHB
  ahb_mem_model #(.AW(SAW), .DW(DW), .STALL(`ST), .ERR_WORD(32'h0800/(DW/8))) sys_mem (
    .clk, .rst_n,
    .haddr(haddr), .hburst(hburst), .hsize(hsize), .htrans(htrans),
    .hwrite(hwrite), .hwdata(hwdata), .hrdata(hrdata), .hready(hready), .hresp(hresp)
  );
`else
  avalon_mem_model #(.AW(SAW), .DW(DW), .BCW(BCW), .STALL(`ST), .SEED(16'h5C5C))
  sys_mem (
    .clk, .rst_n,
    .address(avm_address), .read(avm_read), .write(avm_write),
    .writedata(avm_writedata), .byteenable(avm_byteenable),
    .burstcount(avm_burstcount), .waitrequest(avm_waitrequest),
    .readdata(avm_readdata), .readdatavalid(avm_readdatavalid),
    .response(/* SYS slave has no fault injection */)
  );
`endif

  // =================================================================
  // Test geometry
  // =================================================================
  localparam logic [63:0] HOST_DESC_BASE = 64'h0000_1000;
  localparam logic [63:0] HOST_SRC       = 64'h0000_2000; // H2C src
  localparam logic [63:0] HOST_DST       = 64'h0000_3000; // C2H dst
  localparam logic [31:0] SYS_DST        = 32'h0000_0100; // H2C dst
  localparam logic [31:0] SYS_SRC        = 32'h0000_0200; // C2H src
  localparam int LEN0 = 256;   // bytes, H2C
  localparam int LEN1 = 520;   // bytes, C2H (crosses 0x400 boundary on sys read)

  function automatic int widx(input logic [63:0] byte_addr);
    widx = int'(byte_addr >> $clog2(DW/8));
  endfunction

  task automatic write_desc(input int i,
                            input logic [63:0] host, input logic [31:0] sys,
                            input logic [31:0] len, input logic [31:0] ctrl);
    int b = widx(HOST_DESC_BASE) + i*(DESC_BYTES/(DW/8));
    host_mem.mem[b+0] = host;
    host_mem.mem[b+1] = {32'b0, sys};
    host_mem.mem[b+2] = {ctrl, len};
    host_mem.mem[b+3] = 64'b0;
  endtask

  // ---- CSR access tasks (nonblocking stimulus to avoid clock-edge races) ----
  task automatic csr_wr(input logic [7:0] a, input logic [31:0] d);
    @(posedge clk); csr_address <= a; csr_writedata <= d; csr_write <= 1'b1;
    @(posedge clk); csr_write <= 1'b0;
  endtask

  task automatic csr_rd(input logic [7:0] a, output logic [31:0] d);
    @(posedge clk); csr_address <= a; csr_read <= 1'b1;
    @(posedge clk); csr_read <= 1'b0;     // DUT samples read=1 here
    @(posedge clk); d = csr_readdata;     // fixed 1-cycle latency: data valid now
  endtask

  integer errors = 0;
  task automatic check(input string what, input logic [63:0] got, input logic [63:0] exp);
    if (got !== exp) begin
      errors++;
      $display("  MISMATCH [%s]: got %h exp %h", what, got, exp);
    end
  endtask

  // program a ring and wait until DONE or ERROR (or timeout)
  task automatic launch_and_wait(input logic [31:0] base, input logic [31:0] count,
                                 output logic [31:0] status);
    int k;
    csr_wr(REG_DESC_BASE_LO[7:0], base);
    csr_wr(REG_DESC_BASE_HI[7:0], 32'd0);
    csr_wr(REG_DESC_COUNT[7:0],   count);
    csr_wr(REG_CTRL[7:0], (32'h1<<CTRL_GO));
    status = 0; k = 0;
    while ((k < 20000) && (status[ST_DONE] !== 1'b1) && (status[ST_ERROR] !== 1'b1)) begin
      csr_rd(REG_STATUS[7:0], status); k++;
    end
  endtask

  task automatic abort_clear;
    csr_wr(REG_CTRL[7:0], (32'h1<<CTRL_ABORT));
    repeat (3) @(posedge clk);
  endtask

  // =================================================================
  // Stimulus
  // =================================================================
  logic [31:0] st, ver, scr, ec;
  int i;

  initial begin
`ifdef DUMP
    $dumpfile("tb_pcie_dma.vcd");
    $dumpvars(0, tb_pcie_dma);
`endif
    $display("=== tb_pcie_dma : SYS_IF=%s STALLS=%0d ===", `SYSIF_STR, `ST);

    // hold reset
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- preload source data ----
    for (i = 0; i < LEN0/(DW/8); i++)
      host_mem.mem[widx(HOST_SRC)+i] = {32'hAAAA0000, i[31:0]};
    for (i = 0; i < LEN1/(DW/8); i++)
      sys_mem.mem[widx({32'b0,SYS_SRC})+i] = {32'h55550000, i[31:0]};

    // ---- build descriptor ring ----
    // desc0: H2C, valid
    write_desc(0, HOST_SRC, SYS_DST, LEN0, (32'h1 << C_VALID));
    // desc1: C2H, valid|dir|irq|last
    write_desc(1, HOST_DST, SYS_SRC, LEN1,
               (32'h1<<C_VALID)|(32'h1<<C_DIR)|(32'h1<<C_IRQ)|(32'h1<<C_LAST));

    // ---- sanity: VERSION + SCRATCH ----
    csr_rd(REG_VERSION[7:0], ver);
    check("VERSION", ver, VERSION_ID);
    csr_wr(REG_SCRATCH[7:0], 32'hDEAD_BEEF);
    csr_rd(REG_SCRATCH[7:0], scr);
    check("SCRATCH", scr, 32'hDEAD_BEEF);

    // ---- program & launch ----
    csr_wr(REG_DESC_BASE_LO[7:0], HOST_DESC_BASE[31:0]);
    csr_wr(REG_DESC_BASE_HI[7:0], HOST_DESC_BASE[63:32]);
    csr_wr(REG_DESC_COUNT[7:0],   32'd2);
    csr_wr(REG_IRQ_ENABLE[7:0],   32'h3);
    csr_wr(REG_CTRL[7:0], (32'h1<<CTRL_GO)|(32'h1<<CTRL_IRQ_EN));

    // ---- wait for completion ----
    st = 0;
    i  = 0;
    while ((i < 20000) && (st[ST_DONE] !== 1'b1) && (st[ST_ERROR] !== 1'b1)) begin
      csr_rd(REG_STATUS[7:0], st);
      i++;
    end
    if (st[ST_ERROR]) begin $display("  ENGINE ERROR, STATUS=%h", st); errors++; end
    if (!st[ST_DONE])  begin $display("  TIMEOUT waiting for DONE");    errors++; end

    // ---- check IRQ asserted, then clear ----
    if (irq !== 1'b1) begin $display("  IRQ not asserted after done"); errors++; end
    csr_wr(REG_IRQ_STATUS[7:0], 32'h3);   // W1C
    @(posedge clk);
    if (irq !== 1'b0) begin $display("  IRQ not cleared by W1C"); errors++; end

    // ---- verify data movement ----
    for (i = 0; i < LEN0/(DW/8); i++)
      check("H2C", sys_mem.mem[widx({32'b0,SYS_DST})+i], host_mem.mem[widx(HOST_SRC)+i]);
    for (i = 0; i < LEN1/(DW/8); i++)
      check("C2H", host_mem.mem[widx(HOST_DST)+i], sys_mem.mem[widx({32'b0,SYS_SRC})+i]);

    // =====================================================================
    // error-path / control coverage (single-descriptor rings at the ring base)
    // =====================================================================
    // A) invalid descriptor (C_VALID=0) -> ERROR=DESC_INV, then ABORT clears it
    write_desc(0, HOST_SRC, SYS_DST, LEN0, 32'h0);
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    if (!st[ST_ERROR]) begin $display("  expected ERROR on invalid desc"); errors++; end
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_DESC_INV", ec, ERR_DESC_INV);
    abort_clear;
    csr_rd(REG_STATUS[7:0], st);
    if (st[ST_ERROR]) begin $display("  ABORT did not clear ERROR"); errors++; end

    // B) bad length (not a multiple of DATA_W/8) -> ERROR=BAD_LEN
    write_desc(0, HOST_SRC, SYS_DST, 32'd4, (32'h1<<C_VALID));
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_BAD_LEN", ec, ERR_BAD_LEN);
    abort_clear;

    // C) misaligned address -> ERROR=BAD_ALIGN
    write_desc(0, HOST_SRC + 64'd4, SYS_DST, LEN0, (32'h1<<C_VALID));
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_BAD_ALIGN", ec, ERR_BAD_ALIGN);
    abort_clear;

    // D) count == 0 -> immediate DONE, no error
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd0, st);
    if (!st[ST_DONE]) begin $display("  count==0 did not reach DONE"); errors++; end
    if (st[ST_ERROR]) begin $display("  count==0 raised ERROR");      errors++; end

    // E) ABORT mid-transfer must leave a clean, restartable datapath
    //    (regression for: FIFO not flushed -> corruption/hang; arbiter not
    //     reset -> HOST deadlock on the next descriptor). Kick a C2H burst
    //    (exercises the HOST write path), abort while busy, then run a fresh
    //    H2C and require it to complete with CORRECT data.
    write_desc(0, HOST_DST, SYS_SRC, LEN1, (32'h1<<C_VALID)|(32'h1<<C_DIR));
    csr_wr(REG_DESC_BASE_LO[7:0], HOST_DESC_BASE[31:0]);
    csr_wr(REG_DESC_BASE_HI[7:0], 32'd0);
    csr_wr(REG_DESC_COUNT[7:0],   32'd1);
    csr_wr(REG_CTRL[7:0], (32'h1<<CTRL_GO));
    st = 0; i = 0;
    while ((i < 2000) && !st[ST_BUSY]) begin csr_rd(REG_STATUS[7:0], st); i++; end
    repeat (14) @(posedge clk);          // land somewhere mid-transfer
    abort_clear;
    csr_rd(REG_STATUS[7:0], st);
    if (st[ST_BUSY]) begin $display("  engine stuck BUSY after abort"); errors++; end
    // corrupt the H2C destination so stale aborted beats would be visible
    for (i = 0; i < LEN0/(DW/8); i++) sys_mem.mem[widx({32'b0,SYS_DST})+i] = 64'h0;
    write_desc(0, HOST_SRC, SYS_DST, LEN0, (32'h1<<C_VALID)|(32'h1<<C_LAST));
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    if (!st[ST_DONE]) begin $display("  post-abort transfer hung (deadlock)"); errors++; end
    for (i = 0; i < LEN0/(DW/8); i++)
      check("post-abort H2C", sys_mem.mem[widx({32'b0,SYS_DST})+i], host_mem.mem[widx(HOST_SRC)+i]);

    // F) SYS bus error (AHB only): a write to the fault-injected word must raise
    //    STATUS.ERROR / ERR_INFO==ERR_SYS_BUS, and ABORT must clear sys_bus_error.
`ifdef USE_AHB
    write_desc(0, HOST_SRC, 32'h0000_0800, LEN0, (32'h1<<C_VALID));   // H2C -> SYS err word
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    if (!st[ST_ERROR]) begin $display("  SYS bus error not reported"); errors++; end
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_SYS_BUS", ec, ERR_SYS_BUS);
    abort_clear;
    if (sys_bus_error) begin $display("  ABORT did not clear sys_bus_error"); errors++; end
`endif

    // G) HOST bus error on an H2C data read (all SYS configs): an H2C whose host
    //    SOURCE is the fault-injected word must raise STATUS.ERROR /
    //    ERR_INFO==ERR_HOST_BUS, be visible at the top-level host_bus_error, and
    //    ABORT must clear it. (Descriptor fetch is clean; the move read fails.)
    write_desc(0, HOST_ERR_ADDR, SYS_DST, LEN0, (32'h1<<C_VALID));
    launch_and_wait(HOST_DESC_BASE[31:0], 32'd1, st);
    if (!st[ST_ERROR]) begin $display("  HOST bus error (H2C read) not reported"); errors++; end
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_HOST_BUS H2C", ec, ERR_HOST_BUS);
    if (!host_bus_error) begin $display("  host_bus_error not visible at top (H2C)"); errors++; end
    abort_clear;
    if (host_bus_error) begin $display("  ABORT did not clear host_bus_error (H2C)"); errors++; end

    // H) HOST bus error on a descriptor FETCH read (covers the C2H path): point the
    //    ring base AT the fault-injected word. The fetch read fails, so the engine
    //    must report ERR_HOST_BUS even though the descriptor is marked valid
    //    (fetch-error has priority over descriptor-content checks).
    host_mem.mem[widx(HOST_ERR_ADDR)+0] = HOST_DST;            // host_addr
    host_mem.mem[widx(HOST_ERR_ADDR)+1] = {32'b0, SYS_SRC};    // sys_addr
    host_mem.mem[widx(HOST_ERR_ADDR)+2] =
        {((32'h1<<C_VALID)|(32'h1<<C_DIR)|(32'h1<<C_LAST)), LEN1};
    host_mem.mem[widx(HOST_ERR_ADDR)+3] = 64'b0;
    launch_and_wait(HOST_ERR_ADDR[31:0], 32'd1, st);
    if (!st[ST_ERROR]) begin $display("  HOST bus error (C2H fetch) not reported"); errors++; end
    csr_rd(REG_ERR_INFO[7:0], ec);  check("ERR_HOST_BUS C2H", ec, ERR_HOST_BUS);
    if (!host_bus_error) begin $display("  host_bus_error not visible at top (C2H)"); errors++; end
    abort_clear;
    if (host_bus_error) begin $display("  ABORT did not clear host_bus_error (C2H)"); errors++; end

    // ---- report ----
    if (sys_bus_error)  begin $display("  sys_bus_error asserted");  errors++; end
    if (host_bus_error) begin $display("  host_bus_error asserted"); errors++; end
    if (errors == 0) $display("=== PASS : all checks ok ===");
    else             $display("=== FAIL : %0d error(s) ===", errors);
    $finish;
  end

  // watchdog
  initial begin
    #5_000_000;
    $display("=== FATAL: global timeout ===");
    $finish;
  end

endmodule
