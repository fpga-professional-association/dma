// SPDX-License-Identifier: Apache-2.0
//============================================================================
// dma_arbiter.sv -- 2:1 GMM master arbiter (round-robin, burst-atomic)
//
// Shares one downstream GMM master port between two upstream GMM masters
// (m0 = descriptor fetch, m1 = data-mover host side). A grant is held for the
// entire duration of a burst transaction -- the arbiter counts beats itself
// (readdatavalid beats for reads, accepted write beats for writes) so that two
// transactions are never outstanding at once and read responses are
// unambiguously routed back to their owner.
//
// Requires slaves with read latency >= 1 cycle (readdatavalid never coincident
// with command acceptance) -- see docs/interfaces.md.
//============================================================================

module dma_arbiter #(
  parameter int unsigned AW  = dma_pkg::HADDR_W,
  parameter int unsigned DW  = dma_pkg::DATA_W,
  parameter int unsigned BCW = dma_pkg::BCW
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            clr,        // abort: drop the in-flight transaction

  // -------- upstream master 0 (descriptor fetch) --------
  input  logic [AW-1:0]   m0_address,
  input  logic            m0_read,
  input  logic            m0_write,
  input  logic [DW-1:0]   m0_writedata,
  input  logic [DW/8-1:0] m0_byteenable,
  input  logic [BCW-1:0]  m0_burstcount,
  output logic            m0_waitrequest,
  output logic [DW-1:0]   m0_readdata,
  output logic            m0_readdatavalid,

  // -------- upstream master 1 (data mover, host side) --------
  input  logic [AW-1:0]   m1_address,
  input  logic            m1_read,
  input  logic            m1_write,
  input  logic [DW-1:0]   m1_writedata,
  input  logic [DW/8-1:0] m1_byteenable,
  input  logic [BCW-1:0]  m1_burstcount,
  output logic            m1_waitrequest,
  output logic [DW-1:0]   m1_readdata,
  output logic            m1_readdatavalid,

  // -------- downstream GMM master (to PCIe host port) --------
  output logic [AW-1:0]   o_address,
  output logic            o_read,
  output logic            o_write,
  output logic [DW-1:0]   o_writedata,
  output logic [DW/8-1:0] o_byteenable,
  output logic [BCW-1:0]  o_burstcount,
  input  logic            o_waitrequest,
  input  logic [DW-1:0]   o_readdata,
  input  logic            o_readdatavalid
);

  logic            active;     // a transaction is in flight
  logic            owner;      // 0 -> m0, 1 -> m1
  logic            is_read;
  logic [BCW-1:0]  beats_rem;  // outstanding beats (read: rdv beats; write: send beats)
  logic            rr;         // round-robin preference

  logic req0, req1, any_req;
  logic grant;                 // chosen master when idle
  logic sel;                   // master currently driving the bus
  logic drive_en;

  assign req0    = m0_read | m0_write;
  assign req1    = m1_read | m1_write;
  assign any_req = req0 | req1;

  // round-robin pick when idle
  always_comb begin
    if (rr == 1'b0) grant = req0 ? 1'b0 : 1'b1;  // prefer m0
    else            grant = req1 ? 1'b1 : 1'b0;  // prefer m1
  end

  assign sel      = active ? owner : grant;
  assign drive_en = active | any_req;

  // command/beat acceptance on the downstream port
  logic cmd_fire;        // a fresh command was accepted this cycle
  logic wbeat_fire;      // a write beat was accepted this cycle
  assign cmd_fire   = (o_read | o_write) & ~o_waitrequest;
  assign wbeat_fire = o_write & ~o_waitrequest;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active    <= 1'b0;
      owner     <= 1'b0;
      is_read   <= 1'b0;
      beats_rem <= '0;
      rr        <= 1'b0;
    end else if (clr) begin
      // abort: forget the in-flight transaction so the next requester is granted.
      // The downstream HOST burst is abandoned -- ABORT is a hard datapath reset
      // for error recovery (see docs/register_map.md), not a graceful drain.
      active    <= 1'b0;
      beats_rem <= '0;
    end else if (!active) begin
      if (any_req && cmd_fire) begin
        owner <= sel;
        rr    <= ~sel;                       // rotate preference away from winner
        if (o_read) begin
          active    <= 1'b1;                 // reads always wait for response beats
          is_read   <= 1'b1;
          beats_rem <= o_burstcount;
        end else begin                       // write
          is_read <= 1'b0;
          if (o_burstcount == {{(BCW-1){1'b0}},1'b1}) begin
            active <= 1'b0;                   // single-beat write completes now
          end else begin
            active    <= 1'b1;
            beats_rem <= o_burstcount - 1'b1; // first beat accepted this cycle
          end
        end
      end
    end else begin
      // transaction in flight
      if (is_read) begin
        if (o_readdatavalid) begin
          if (beats_rem == {{(BCW-1){1'b0}},1'b1}) active <= 1'b0;
          beats_rem <= beats_rem - 1'b1;
        end
      end else begin
        if (wbeat_fire) begin
          if (beats_rem == {{(BCW-1){1'b0}},1'b1}) active <= 1'b0;
          beats_rem <= beats_rem - 1'b1;
        end
      end
    end
  end

  // ---- downstream drive: selected master, gated by drive_en ----
  always_comb begin
    if (drive_en && sel == 1'b1) begin
      o_address    = m1_address;
      o_read       = m1_read;
      o_write      = m1_write;
      o_writedata  = m1_writedata;
      o_byteenable = m1_byteenable;
      o_burstcount = m1_burstcount;
    end else if (drive_en && sel == 1'b0) begin
      o_address    = m0_address;
      o_read       = m0_read;
      o_write      = m0_write;
      o_writedata  = m0_writedata;
      o_byteenable = m0_byteenable;
      o_burstcount = m0_burstcount;
    end else begin
      o_address    = '0;
      o_read       = 1'b0;
      o_write      = 1'b0;
      o_writedata  = '0;
      o_byteenable = '0;
      o_burstcount = '0;
    end
  end

  // ---- back-pressure: only the selected master sees the real waitrequest ----
  assign m0_waitrequest = (drive_en && sel == 1'b0) ? o_waitrequest : 1'b1;
  assign m1_waitrequest = (drive_en && sel == 1'b1) ? o_waitrequest : 1'b1;

  // ---- read responses routed to the active read owner ----
  assign m0_readdata       = o_readdata;
  assign m1_readdata       = o_readdata;
  assign m0_readdatavalid  = (active && is_read && owner == 1'b0) ? o_readdatavalid : 1'b0;
  assign m1_readdatavalid  = (active && is_read && owner == 1'b1) ? o_readdatavalid : 1'b0;

endmodule
