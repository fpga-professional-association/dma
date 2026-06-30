// SPDX-License-Identifier: Apache-2.0
//============================================================================
// dma_pkg.sv  --  Global parameters, types and constants for the PCIe DMA engine
//
// This package is the single source of truth for every cross-module contract:
// data/address widths, burst limits, the descriptor layout and the CSR map.
// Every RTL, formal and simulation file in this project includes it.
//
// Conventions used throughout the project
// ----------------------------------------
//   * Single clock domain   : port name `clk`            (rising edge)
//   * Reset                 : port name `rst_n`          (active low, sync deassert)
//   * Generic MM master IF  : "GMM" -- an Avalon-MM pipelined, burst-capable
//                             master.  See docs/interfaces.md for full timing.
//   * All bursts are bounded so they NEVER cross a 4 KiB (PCIe) or 1 KiB (AHB)
//     boundary and never exceed MAX_BURST_BEATS.  The data mover guarantees
//     this by construction, which keeps every bus adapter trivially compliant.
//============================================================================
`ifndef DMA_PKG_SV
`define DMA_PKG_SV

package dma_pkg;

  //--------------------------------------------------------------------------
  // Data path
  //--------------------------------------------------------------------------
  parameter int unsigned DATA_W = 64;          // payload data width (bits); must divide 256
  parameter int unsigned BE_W   = DATA_W/8;    // byte-enable width

  //--------------------------------------------------------------------------
  // Address widths
  //--------------------------------------------------------------------------
  parameter int unsigned HADDR_W = 64;         // host / PCIe-side byte address width
  parameter int unsigned SADDR_W = 32;         // system / local-side byte address width

  //--------------------------------------------------------------------------
  // Burst limits
  //--------------------------------------------------------------------------
  // MAX_BURST_BEATS chosen so that MAX_BURST_BEATS*BE_W <= 1 KiB, guaranteeing
  // no burst ever crosses a 1 KiB (AHB) or 4 KiB (PCIe/AXI) boundary.
  parameter int unsigned MAX_BURST_BEATS = 16;
  parameter int unsigned BCW = $clog2(MAX_BURST_BEATS) + 1;  // burstcount field width (1..MAX)

  //--------------------------------------------------------------------------
  // Transfer length
  //--------------------------------------------------------------------------
  parameter int unsigned LEN_W = 32;           // descriptor byte-length width

  //--------------------------------------------------------------------------
  // Data FIFO
  //--------------------------------------------------------------------------
  parameter int unsigned FIFO_DEPTH = 256;     // beats; must be a power of two

  //--------------------------------------------------------------------------
  // Descriptor format  (see docs/descriptor_format.md)
  //--------------------------------------------------------------------------
  // 32-byte (256-bit) descriptor, little-endian byte order in host memory:
  //   bytes  0.. 7 : host_addr [63:0]
  //   bytes  8..15 : sys_addr  [63:0]   (only SADDR_W bits used)
  //   bytes 16..19 : length    [31:0]   (in bytes)
  //   bytes 20..23 : control   [31:0]
  //   bytes 24..31 : reserved (must be 0) -- no in-band per-descriptor status
  //                  writeback; software uses STATUS/REG_DESC_INDEX/IRQ instead
  parameter int unsigned DESC_BYTES = 32;
  parameter int unsigned DESC_BITS  = DESC_BYTES*8;                 // 256
  parameter int unsigned DESC_BEATS = (DESC_BITS + DATA_W - 1)/DATA_W;

  // Bit offsets inside the assembled little-endian 256-bit descriptor word
  parameter int unsigned DESC_HOST_LSB = 0;
  parameter int unsigned DESC_SYS_LSB  = 64;
  parameter int unsigned DESC_LEN_LSB  = 128;
  parameter int unsigned DESC_CTRL_LSB = 160;

  // Descriptor control-field bit positions
  parameter int unsigned C_VALID = 0;          // 1 = descriptor owned by engine
  parameter int unsigned C_DIR   = 1;          // 0 = H2C (host->sys), 1 = C2H (sys->host)
  parameter int unsigned C_IRQ   = 2;          // 1 = raise completion IRQ for this descriptor
  parameter int unsigned C_LAST  = 3;          // 1 = last descriptor of the ring/chain

  typedef enum logic {DIR_H2C = 1'b0, DIR_C2H = 1'b1} dir_e;

  // Decoded descriptor handed from the fetch unit to the data mover
  typedef struct packed {
    logic [HADDR_W-1:0] host_addr;
    logic [SADDR_W-1:0] sys_addr;
    logic [LEN_W-1:0]   length;     // bytes
    logic               dir;        // dir_e
    logic               irq;
    logic               last;
  } desc_t;

  //--------------------------------------------------------------------------
  // Control / Status Register map  (32-bit registers, word addressed)
  // (see docs/register_map.md).  Accessed by the host through a PCIe BAR.
  //--------------------------------------------------------------------------
  parameter int unsigned CSR_ADDR_W = 8;       // 256 word addressable registers
  parameter int unsigned CSR_DATA_W = 32;

  parameter int unsigned REG_CTRL        = 32'h00; // RW
  parameter int unsigned REG_STATUS      = 32'h01; // RO
  parameter int unsigned REG_DESC_BASE_LO= 32'h02; // RW  host ring base [31:0]
  parameter int unsigned REG_DESC_BASE_HI= 32'h03; // RW  host ring base [63:32]
  parameter int unsigned REG_DESC_COUNT  = 32'h04; // RW  number of descriptors to process
  parameter int unsigned REG_DESC_INDEX  = 32'h05; // RO  completed descriptor count
  parameter int unsigned REG_IRQ_STATUS  = 32'h06; // RW1C
  parameter int unsigned REG_IRQ_ENABLE  = 32'h07; // RW
  parameter int unsigned REG_ERR_INFO    = 32'h08; // RO
  parameter int unsigned REG_VERSION     = 32'h09; // RO
  parameter int unsigned REG_SCRATCH     = 32'h0A; // RW

  // CTRL register bit positions
  parameter int unsigned CTRL_GO     = 0;      // 1 = start processing the descriptor ring
  parameter int unsigned CTRL_ABORT  = 1;      // 1 = abort/clear engine (self-clearing)
  parameter int unsigned CTRL_IRQ_EN = 2;      // global IRQ enable

  // STATUS register bit positions
  parameter int unsigned ST_BUSY  = 0;
  parameter int unsigned ST_DONE  = 1;
  parameter int unsigned ST_ERROR = 2;
  parameter int unsigned ST_STATE_LSB = 4;     // [7:4] engine FSM state

  // IRQ bit positions (IRQ_STATUS / IRQ_ENABLE)
  parameter int unsigned IRQ_DONE  = 0;
  parameter int unsigned IRQ_ERROR = 1;

  // Error codes (ERR_INFO[7:0])
  parameter int unsigned ERR_NONE      = 32'h00;
  parameter int unsigned ERR_BAD_LEN   = 32'h01; // length == 0 or not a multiple of BE_W
  parameter int unsigned ERR_BAD_ALIGN = 32'h02; // address not BE_W aligned
  parameter int unsigned ERR_DESC_INV  = 32'h03; // descriptor C_VALID == 0
  parameter int unsigned ERR_BAD_BASE  = 32'h04; // desc ring base not DESC_BYTES aligned
  parameter int unsigned ERR_SYS_BUS   = 32'h05; // SYS bus (AXI/AHB) error response during a transfer
  parameter int unsigned ERR_HOST_BUS  = 32'h06; // HOST/PCIe bus error response (UR/CA/poison) during a fetch or transfer

  //--------------------------------------------------------------------------
  // HOST (PCIe) read-completion response  (Avalon-MM `response[1:0]`)
  //--------------------------------------------------------------------------
  // The HOST GMM master carries an optional per-beat completion response that
  // accompanies `readdatavalid`, mirroring the PCIe Hard IP TXS status. Any
  // code other than OKAY (Unsupported Request / Completer Abort / poisoned TLP)
  // is captured as ERR_HOST_BUS.
  parameter int unsigned HRESP_W    = 2;
  parameter logic [1:0]  HRESP_OKAY = 2'b00; // OKAY; all other codes are errors

  parameter int unsigned VERSION_ID = 32'h0D3A_0101; // "DMA" v1.1

endpackage : dma_pkg

`endif // DMA_PKG_SV
