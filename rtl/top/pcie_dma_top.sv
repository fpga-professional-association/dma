// SPDX-License-Identifier: Apache-2.0
//============================================================================
// pcie_dma_top.sv -- Configurable PCIe DMA engine top level
//
// Wraps dma_engine_core and selects the system-bus adapter with the SYS_IF
// parameter: "AVALON" | "AXI4" | "AHB". All three bus port groups are present
// on the module (SystemVerilog ports are static); the unselected groups are
// driven to their idle/zero values.
//
//   * HOST port  : Avalon-MM master -> PCIe Hard IP TXS (host memory access)
//   * CSR  port  : Avalon-MM slave  <- PCIe Hard IP BAR (host register access)
//   * SYS  port  : one of Avalon-MM / AXI4 / AHB master (local system bus)
//============================================================================

module pcie_dma_top
  import dma_pkg::*;
#(
  parameter SYS_IF = "AVALON"            // "AVALON" | "AXI4" | "AHB"
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // ================= CSR slave (host BAR) =================
  input  logic [CSR_ADDR_W-1:0] csr_address,
  input  logic                  csr_read,
  input  logic                  csr_write,
  input  logic [CSR_DATA_W-1:0] csr_writedata,
  output logic [CSR_DATA_W-1:0] csr_readdata,
  output logic                  csr_readdatavalid,
  output logic                  csr_waitrequest,

  // ================= HOST Avalon-MM master (PCIe TXS) =================
  output logic [HADDR_W-1:0]    host_address,
  output logic                  host_read,
  output logic                  host_write,
  output logic [DATA_W-1:0]     host_writedata,
  output logic [BE_W-1:0]       host_byteenable,
  output logic [BCW-1:0]        host_burstcount,
  input  logic                  host_waitrequest,
  input  logic [DATA_W-1:0]     host_readdata,
  input  logic                  host_readdatavalid,
  input  logic [1:0]            host_response,   // PCIe completion status (00=OKAY) on read beats

  // ================= SYS Avalon-MM master (SYS_IF=="AVALON") =================
  // Inputs of the non-selected SYS bus are legitimately unused; waive UNUSEDSIGNAL
  // for this whole group (inert for the outputs and for the selected config).
  /* verilator lint_off UNUSEDSIGNAL */
  output logic [SADDR_W-1:0]    avm_address,
  output logic                  avm_read,
  output logic                  avm_write,
  output logic [DATA_W-1:0]     avm_writedata,
  output logic [BE_W-1:0]       avm_byteenable,
  output logic [BCW-1:0]        avm_burstcount,
  input  logic                  avm_waitrequest,
  input  logic [DATA_W-1:0]     avm_readdata,
  input  logic                  avm_readdatavalid,
  /* verilator lint_on UNUSEDSIGNAL */

  // ================= SYS AXI4 master (SYS_IF=="AXI4") =================
  /* verilator lint_off UNUSEDSIGNAL */  // unused inputs when this SYS bus not selected
  output logic [0:0]            axi_awid,
  output logic [SADDR_W-1:0]    axi_awaddr,
  output logic [7:0]            axi_awlen,
  output logic [2:0]            axi_awsize,
  output logic [1:0]            axi_awburst,
  output logic [3:0]            axi_awcache,
  output logic [2:0]            axi_awprot,
  output logic                  axi_awvalid,
  input  logic                  axi_awready,
  output logic [DATA_W-1:0]     axi_wdata,
  output logic [BE_W-1:0]       axi_wstrb,
  output logic                  axi_wlast,
  output logic                  axi_wvalid,
  input  logic                  axi_wready,
  input  logic [0:0]            axi_bid,
  input  logic [1:0]            axi_bresp,
  input  logic                  axi_bvalid,
  output logic                  axi_bready,
  output logic [0:0]            axi_arid,
  output logic [SADDR_W-1:0]    axi_araddr,
  output logic [7:0]            axi_arlen,
  output logic [2:0]            axi_arsize,
  output logic [1:0]            axi_arburst,
  output logic [3:0]            axi_arcache,
  output logic [2:0]            axi_arprot,
  output logic                  axi_arvalid,
  input  logic                  axi_arready,
  input  logic [0:0]            axi_rid,
  input  logic [DATA_W-1:0]     axi_rdata,
  input  logic [1:0]            axi_rresp,
  input  logic                  axi_rlast,
  input  logic                  axi_rvalid,
  output logic                  axi_rready,
  /* verilator lint_on UNUSEDSIGNAL */

  // ================= SYS AHB-Lite master (SYS_IF=="AHB") =================
  /* verilator lint_off UNUSEDSIGNAL */  // unused inputs when this SYS bus not selected
  output logic [SADDR_W-1:0]    haddr,
  output logic [2:0]            hburst,
  output logic [2:0]            hsize,
  output logic [1:0]            htrans,
  output logic                  hwrite,
  output logic [DATA_W-1:0]     hwdata,
  input  logic [DATA_W-1:0]     hrdata,
  input  logic                  hready,
  input  logic                  hresp,
  /* verilator lint_on UNUSEDSIGNAL */

  // ================= misc =================
  output logic                  irq,
  output logic                  sys_bus_error,
  output logic                  host_bus_error    // HOST/PCIe read returned a non-OK response
);

  // -------- adapter <-> core error / clear --------
  logic               adapter_err, sys_clr_w;
  assign sys_bus_error = adapter_err;

  // -------- core SYS GMM master (driven into the selected adapter) --------
  logic [SADDR_W-1:0] sg_address;
  logic               sg_read, sg_write;
  logic [DATA_W-1:0]  sg_writedata;
  logic [BE_W-1:0]    sg_byteenable;
  logic [BCW-1:0]     sg_burstcount;
  logic               sg_waitrequest;
  logic [DATA_W-1:0]  sg_readdata;
  logic               sg_readdatavalid;

  // =================================================================
  // DMA core
  // =================================================================
  dma_engine_core u_core (
    .clk(clk), .rst_n(rst_n),
    .csr_address(csr_address), .csr_read(csr_read), .csr_write(csr_write),
    .csr_writedata(csr_writedata), .csr_readdata(csr_readdata),
    .csr_readdatavalid(csr_readdatavalid), .csr_waitrequest(csr_waitrequest),
    .host_address(host_address), .host_read(host_read), .host_write(host_write),
    .host_writedata(host_writedata), .host_byteenable(host_byteenable),
    .host_burstcount(host_burstcount), .host_waitrequest(host_waitrequest),
    .host_readdata(host_readdata), .host_readdatavalid(host_readdatavalid),
    .host_response(host_response),
    .sys_address(sg_address), .sys_read(sg_read), .sys_write(sg_write),
    .sys_writedata(sg_writedata), .sys_byteenable(sg_byteenable),
    .sys_burstcount(sg_burstcount), .sys_waitrequest(sg_waitrequest),
    .sys_readdata(sg_readdata), .sys_readdatavalid(sg_readdatavalid),
    .sys_bus_err(adapter_err), .sys_clr(sys_clr_w),
    .host_bus_error(host_bus_error),
    .irq(irq)
  );

  // =================================================================
  // System-bus adapter select
  // =================================================================
  /* verilator lint_off WIDTHEXPAND */  // string-literal compares have differing widths
  generate
    if (SYS_IF == "AXI4") begin : g_axi
      gmm_to_axi4 #(.AW(SADDR_W), .DW(DATA_W), .BCW(BCW)) u_adapt (
        .clk(clk), .rst_n(rst_n),
        .gmm_address(sg_address), .gmm_read(sg_read), .gmm_write(sg_write),
        .gmm_writedata(sg_writedata), .gmm_byteenable(sg_byteenable),
        .gmm_burstcount(sg_burstcount), .gmm_waitrequest(sg_waitrequest),
        .gmm_readdata(sg_readdata), .gmm_readdatavalid(sg_readdatavalid),
        .axi_awid(axi_awid), .axi_awaddr(axi_awaddr), .axi_awlen(axi_awlen),
        .axi_awsize(axi_awsize), .axi_awburst(axi_awburst), .axi_awcache(axi_awcache),
        .axi_awprot(axi_awprot), .axi_awvalid(axi_awvalid), .axi_awready(axi_awready),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wlast(axi_wlast),
        .axi_wvalid(axi_wvalid), .axi_wready(axi_wready),
        .axi_bid(axi_bid), .axi_bresp(axi_bresp), .axi_bvalid(axi_bvalid),
        .axi_bready(axi_bready),
        .axi_arid(axi_arid), .axi_araddr(axi_araddr), .axi_arlen(axi_arlen),
        .axi_arsize(axi_arsize), .axi_arburst(axi_arburst), .axi_arcache(axi_arcache),
        .axi_arprot(axi_arprot), .axi_arvalid(axi_arvalid), .axi_arready(axi_arready),
        .axi_rid(axi_rid), .axi_rdata(axi_rdata), .axi_rresp(axi_rresp),
        .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid), .axi_rready(axi_rready),
        .clr(sys_clr_w), .err(adapter_err)
      );
      // idle the unused bus groups
      assign {avm_address, avm_read, avm_write, avm_writedata,
              avm_byteenable, avm_burstcount} = '0;
      assign {haddr, hburst, hsize, htrans, hwrite, hwdata} = '0;

    end else if (SYS_IF == "AHB") begin : g_ahb
      gmm_to_ahb #(.AW(SADDR_W), .DW(DATA_W), .BCW(BCW)) u_adapt (
        .clk(clk), .rst_n(rst_n),
        .gmm_address(sg_address), .gmm_read(sg_read), .gmm_write(sg_write),
        .gmm_writedata(sg_writedata), .gmm_byteenable(sg_byteenable),
        .gmm_burstcount(sg_burstcount), .gmm_waitrequest(sg_waitrequest),
        .gmm_readdata(sg_readdata), .gmm_readdatavalid(sg_readdatavalid),
        .haddr(haddr), .hburst(hburst), .hsize(hsize), .htrans(htrans),
        .hwrite(hwrite), .hwdata(hwdata), .hrdata(hrdata), .hready(hready),
        .hresp(hresp), .clr(sys_clr_w), .err(adapter_err)
      );
      assign {avm_address, avm_read, avm_write, avm_writedata,
              avm_byteenable, avm_burstcount} = '0;
      assign {axi_awid, axi_awaddr, axi_awlen, axi_awsize, axi_awburst, axi_awcache,
              axi_awprot, axi_awvalid, axi_wdata, axi_wstrb, axi_wlast, axi_wvalid,
              axi_bready, axi_arid, axi_araddr, axi_arlen, axi_arsize, axi_arburst,
              axi_arcache, axi_arprot, axi_arvalid, axi_rready} = '0;

    end else begin : g_avalon
      gmm_to_avalon #(.AW(SADDR_W), .DW(DATA_W), .BCW(BCW)) u_adapt (
        .clk(clk), .rst_n(rst_n),
        .gmm_address(sg_address), .gmm_read(sg_read), .gmm_write(sg_write),
        .gmm_writedata(sg_writedata), .gmm_byteenable(sg_byteenable),
        .gmm_burstcount(sg_burstcount), .gmm_waitrequest(sg_waitrequest),
        .gmm_readdata(sg_readdata), .gmm_readdatavalid(sg_readdatavalid),
        .avm_address(avm_address), .avm_read(avm_read), .avm_write(avm_write),
        .avm_writedata(avm_writedata), .avm_byteenable(avm_byteenable),
        .avm_burstcount(avm_burstcount), .avm_waitrequest(avm_waitrequest),
        .avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid),
        .clr(sys_clr_w), .err(adapter_err)
      );
      assign {axi_awid, axi_awaddr, axi_awlen, axi_awsize, axi_awburst, axi_awcache,
              axi_awprot, axi_awvalid, axi_wdata, axi_wstrb, axi_wlast, axi_wvalid,
              axi_bready, axi_arid, axi_araddr, axi_arlen, axi_arsize, axi_arburst,
              axi_arcache, axi_arprot, axi_arvalid, axi_rready} = '0;
      assign {haddr, hburst, hsize, htrans, hwrite, hwdata} = '0;
    end
  endgenerate
  /* verilator lint_on WIDTHEXPAND */

endmodule
