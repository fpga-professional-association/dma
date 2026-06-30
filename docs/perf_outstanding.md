# Outstanding-burst depth, burst sizing, and a path to latency hiding

This note documents the engine's current outstanding-transaction behaviour, the
throughput cost of that behaviour on a deep-latency link, what this change set
*does* deliver (larger and per-bus-correct bursts, clean parameterisation), and a
concrete, staged plan for adding more than one outstanding burst per direction.

Tracking issue: #8.

---

## 1. Current behaviour: single-outstanding per direction

The datapath is single-outstanding **by construction** on every bus. Three
independent mechanisms each enforce it:

1. **HOST arbiter** (`rtl/core/dma_arbiter.sv`). A grant is held for the entire
   burst — the arbiter counts beats itself (read-data-valid beats for reads,
   accepted write beats for writes) so that two transactions are never
   outstanding at once and read responses route unambiguously to their owner.

2. **Data-mover read engine** (`rtl/core/dma_data_mover.sv`). The read FSM only
   returns to `R_IDLE` on the *last* beat of the burst (`r_dcnt == 1`), and
   `r_can_issue` is gated on `rstate == R_IDLE`. A new read burst therefore
   cannot be launched until the previous burst has fully drained its data into
   the FIFO. The write engine is structured the same way (`W_IDLE`/`W_BURST`).

3. **AXI4 adapter** (`rtl/adapters/gmm_to_axi4.sv`). The write path parks in
   `AX_WB` and back-pressures the GMM master (`gmm_waitrequest` defaults high)
   until the `B` response lands, so the next write command cannot be accepted
   until the prior write has fully committed. Reads use a single AR held until
   `ARREADY`, one burst at a time. `AWID/ARID` are tied to 0.

In addition, the descriptor walk is strictly sequential: `dma_engine_core`
launches the next fetch only after the current move's `m_done` (`E_FETCH →
E_FETCH_WAIT → E_RUN → E_FETCH`), with no descriptor prefetch, and `busy`
asserts across disjoint fetch/run phases.

### Latency cost

Let `R` be the bus round-trip latency (command-accept → first response beat) and
`B` the beats per burst. With one outstanding burst the steady-state cost of a
burst is roughly `R + B` cycles for `B` beats, so sustained throughput is

```
beats/cycle ≈ B / (B + R)
```

On a deep-latency link (`R` of tens to >100 cycles for PCIe/AXI) and a small
burst, the `R` term dominates and throughput collapses well below 1 beat/cycle.
Two levers improve this **without** changing outstanding depth, and both are
applied here:

* **Larger `B`** (raise `MAX_BURST_BEATS`) drives `B/(B+R)` toward 1 by
  amortising the single round-trip over more beats.
* **Correct per-bus boundary** lets `B` actually reach the cap on Avalon/AXI
  instead of being clipped by the AHB-tightest 1 KiB rule.

The remaining, larger win — overlapping multiple `R`'s by having several bursts
in flight so the pipeline never idles waiting on a response — requires the RTL in
§3 and is **not** implemented here.

---

## 2. What this change delivers

### 2a. Larger, cleanly-parameterised burst cap

`MAX_BURST_BEATS` is raised `16 → 64` (128 B → 512 B/burst at `DATA_W=64`) and
documented as freely parameterisable. The only hard ceiling is `BCW ≤ 8`
(`MAX_BURST_BEATS ≤ 128`), because the AXI4 adapter encodes `AxLEN =
burstcount-1` in the architectural 8-bit `AxLEN` field and zero-extends `BCW`
bits into it. Everything downstream derives from the package:

* `BCW = $clog2(MAX_BURST_BEATS)+1` sizes every `burstcount`/`*len` field and the
  arbiter/adapter beat counters automatically.
* `FIFO_DEPTH` (256 beats, power-of-two, parameterised in `dma_pkg`) only needs
  `FIFO_DEPTH ≥ MAX_BURST_BEATS` so the read engine can always reserve a full
  burst; 256 ≫ 64 leaves ample slack and room to grow the cap.

To go beyond 128 beats one would widen the AXI `AxLEN` handling (it already has
spare width up to the architectural 256-beat / `AxLEN=255` limit) — captured as
follow-up below.

### 2b. Per-bus burst boundary

`beats_to_boundary()` was hardwired to 1 KiB and applied to every config. It is
now parameterised by `log2(bytes)` and selected **per transfer direction** in the
data mover:

* host/PCIe side → `LOG2_BND_PCIE` = 4 KiB (read source on H2C, write dest on C2H);
* system side    → `LOG2_SYS_BOUNDARY`, set by `pcie_dma_top` from `SYS_IF`:
  4 KiB for Avalon/AXI (`LOG2_BND_AVALON`/`LOG2_BND_AXI4`), 1 KiB for AHB
  (`LOG2_BND_AHB`).

This removes the documented wart of applying the AHB 1 KiB limit to Avalon/AXI.
At the current 512 B cap the clamp rarely binds (512 B < 1 KiB), so the change is
behaviour-preserving for today's traffic while making the boundary correct for a
future larger cap.

### 2c. Verification

All four flows stay green at `MAX_BURST_BEATS = 64` for every `SYS_IF`:
`scripts/lint.sh`, `scripts/run_sim.sh` (6 configs, H2C/C2H, abort, error
injection, with/without back-pressure), `scripts/run_formal.sh` (FIFO, arbiter,
AXI4, AHB protocol proofs), `scripts/run_synth.sh`. The existing AXI4/AHB formal
harnesses already bound the burst encoding (`AWLEN/ARLEN ≤ MAX_BURST_BEATS-1`,
`ARLEN == burstcount-1`) and now re-prove that bound at the larger cap.

---

## 3. A concrete path to N>1 outstanding bursts

This is a coordinated change across the arbiter, the AXI4 adapter, the data
mover, and the formal harnesses. Staged so each step is independently verifiable:

1. **Data mover — split issue from response.** Give the read engine separate
   *command-issue* and *response* state so it can launch burst `k+1` while burst
   `k` is still draining: a small issue queue of `{burst_len}` (depth `N`),
   FIFO-space reservation counted at *issue* time (reserve `Σ len` not just the
   current burst), and a response counter that retires bursts in order. Apply the
   same split to the write engine to drop the per-burst `B`-wait. Keep bursts
   in-order so no reorder buffer is needed.

2. **Arbiter — tag/credit instead of one-grant-per-burst.** Replace the
   "hold grant for the whole burst" rule with an outstanding-count credit (depth
   `N`) per master, and route read responses by a small owner FIFO (the order
   bursts were issued) rather than the single `owner` register. Reads remain
   in-order per master, so a FIFO of owners suffices; no per-beat ID matching is
   required while `N` is small.

3. **AXI4 adapter — decouple AR/R and AW/W/B.** Allow a new `AR` (or `AW`+`W`)
   to issue before the prior `R` (or `B`) completes, bounded by an
   outstanding-count credit; either use distinct `AxID`s or keep a single ID with
   in-order responses (AXI guarantees same-ID ordering). Remove the `AX_WB`-until-
   `B` stall on the write path so `B` retirement is decoupled from command issue.
   The Avalon and AHB adapters need matching pipelining (Avalon-MM read pipelining
   is native; AHB-Lite is inherently one-data-phase, so AHB stays effectively
   single-outstanding and acts as the conservative floor).

4. **Descriptor prefetch (optional).** Fetch descriptor `idx+1` during the
   current move to hide descriptor-fetch latency, overlapping the otherwise
   disjoint `E_FETCH`/`E_RUN` phases.

5. **Formal + sim.**
   * Extend the mem models with a configurable response delay and an
     outstanding-depth counter; assert in the TB that `>1` command is in flight
     on the read path and measure beats/cycle vs the single-outstanding baseline.
   * Extend the arbiter proof to cover `N` outstanding with correct response
     routing/ordering; extend the AXI4 proof for multiple in-flight `AxID`s /
     outstanding credits and the no-`AX_WB`-stall property.

### Verification-tooling caveat

The data mover uses `import dma_pkg::*`, which the open-source yosys front-end
cannot elaborate without Verific, so a yosys-SAT harness **cannot** instantiate
the mover directly (this is why `run_formal.sh` proves the adapters, which
reference the package by explicit scope). A mover-level boundary/outstanding
proof therefore needs SymbiYosys + an SMT solver (z3/boolector) — neither is
installed in this environment — or a Verific-enabled flow. Until then the mover's
boundary and outstanding guarantees are argued by construction and exercised in
simulation, and the multi-outstanding proofs in step 5 are tracked as follow-up
rather than wired into the existing (green) CI jobs.
