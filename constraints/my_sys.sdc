# =============================================================================
# my_sys.sdc  —  Synopsys Design Constraints for Quartus Prime Lite
# Target: Altera Cyclone IV E, EP4CE115F29C7
# =============================================================================
#
# PURPOSE:
#   This file tells Quartus TimeQuest STA (Static Timing Analysis) engine:
#     1. What the two clocks are and what their frequencies/periods are.
#     2. That those two clocks are ASYNCHRONOUS (no phase relationship).
#   Without these constraints, the STA tool would try to analyse timing
#   across the clock-domain crossing in the FIFO — which is meaningless
#   and would produce bogus "failing" paths.
#
# HOW TO LOAD IN QUARTUS:
#   Assignments → Settings → TimeQuest Timing Analyzer → SDC Files → Add
#   Then: Processing → Start → Start TimeQuest Timing Analysis
#
# =============================================================================
# CLOCK DEFINITIONS
# =============================================================================

# fast_clk: 100 MHz = 10 ns period
# The port name must match the top-level port in my_sys.v exactly.
create_clock -name fast_clk -period 10.000 [get_ports fast_clk]

# slow_clk: 10 MHz = 100 ns period
create_clock -name slow_clk -period 100.000 [get_ports slow_clk]

# =============================================================================
# CLOCK GROUPS  —  the key CDC constraint
# =============================================================================
#
# WHY set_clock_groups instead of set_false_path?
#
#   set_false_path is per-path: you would need to enumerate every single
#   signal that crosses the domain boundary.  That is error-prone —
#   miss one and STA silently gives you false confidence.
#
#   set_clock_groups -asynchronous tells TimeQuest: "these two groups of
#   clocks have NO required phase relationship."  It automatically applies
#   false-path exceptions to EVERY path between the two groups, present
#   and future.  One constraint covers all CDC paths.
#
# WHY include gated_clk in the fast group?
#   gated_clk is derived from fast_clk via ALTCLKCTRL.  Quartus automatically
#   propagates the clock definition through ALTCLKCTRL and names the derived
#   clock "gated_clk" (or the IP may name it based on the outclk port).
#   The -group clause covers both the source and all derived clocks.
#   If Quartus names the gated clock differently, replace "gated_clk" with
#   the actual name from the TimeQuest clock report.
#
# NOTE: This constraint means TimeQuest will NOT check setup/hold timing
# between the two groups.  The FIFO's 2-FF synchroniser registers handle
# metastability; STA cannot verify that — it requires MTBF analysis instead.

set_clock_groups \
    -asynchronous \
    -group { fast_clk } \
    -group { slow_clk }
# NOTE: The ALTCLKCTRL output (the gated clock) is derived from fast_clk and is
# analysed by Quartus as part of the fast_clk domain, so there is no separate
# "gated_clk" clock to list here.  Keeping fast_clk vs slow_clk asynchronous
# still cuts every clock-domain-crossing path through the FIFO.

# Add realistic clock uncertainty (jitter + on-die variation) to both clocks so
# setup/hold is analysed rigorously rather than with zero uncertainty.
derive_clock_uncertainty

# =============================================================================
# OPTIONAL: Input / Output delays
# =============================================================================
# These are not strictly required for an internal flow (no I/O timing spec),
# but including them keeps the STA report clean (no "unconstrained" warnings).

# Inputs: assume they are registered off a fast_clk-domain source with
# a board trace + PCB propagation delay of up to 2 ns.
set_input_delay -clock fast_clk -max 2.0 [get_ports {data_in[*] in_valid}]
set_input_delay -clock fast_clk -min 0.5 [get_ports {data_in[*] in_valid}]

# Outputs: tx and tx_busy are slow-clock domain outputs; constrain to slow_clk.
set_output_delay -clock slow_clk -max 2.0 [get_ports {tx tx_busy}]
set_output_delay -clock slow_clk -min 0.5 [get_ports {tx tx_busy}]

# Reset is asynchronous and topology-driven; cut it from all timing paths
# to avoid false critical paths through reset networks.
set_false_path -from [get_ports rst_n]

# =============================================================================
# SYNCHRONISER REGISTERS — instruct STA to skip setup/hold on the 2-FF FFs
# =============================================================================
# The two FFs in each synchroniser (wptr_sync1_r, wptr_sync2_r, etc.) are
# intentionally metastable-tolerant.  Their setup/hold timing is irrelevant
# to STA — what matters is MTBF, not whether the setup time is met.
# Cutting timing on just the *_sync1 registers is enough (the *_sync2 FFs
# will have clean data because *_sync1 resolves within one clock period).
#
# NOTE: In a full sign-off flow you would also add ASYNC_REG attributes
# (or Quartus SYNCHRONIZER_IDENTIFICATION attributes) to these FFs so the
# tool reports synchroniser count and estimates MTBF.

set_false_path -to [get_registers {*afifo*wptr_sync1_r*}]
set_false_path -to [get_registers {*afifo*rptr_sync1_w*}]

# =============================================================================
# END OF SDC
# =============================================================================
