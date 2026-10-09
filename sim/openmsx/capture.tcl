# openMSX script: capture a V9990 trace of a game (see sim/v9990_trace.py).
#
#   openmsx -machine C-BIOS_MSX2+ -ext gfx9000 -carta game.rom -script capture.tcl
#
# Environment: TRACE_OUT (output directory, default /work), TRACE_T0 (start,
# seconds of emulated time), TRACE_LEN (length, seconds), TRACE_KEYS (Tcl list
# of {time row mask hold} key presses on the MSX keyboard matrix).
#
# At the first command started (write of R#52) after TRACE_T0 the state is
# saved as t0_*: VRAM, registers, palette and the selected register (the
# watchpoint runs before the write).  openMSX keeps no copy of R#32-R#63, so
# the registers come from a shadow of every register write since power-on.
# Then every access to ports 60h-6Fh (writes, and the reads of 60h, 61h and
# 63h) goes to accesses.log, up to the first command started TRACE_LEN later,
# where the state is saved as t1_*.

set throttle off
set D "Sunrise GFX9000"
set out [expr {[info exists ::env(TRACE_OUT)] ? $::env(TRACE_OUT) : "/work"}]
set t0 $::env(TRACE_T0)
set len $::env(TRACE_LEN)
set sel 0
set phase 0
set t1_after 0
set log ""
for {set r 0} {$r < 64} {incr r} { set shadow($r) 0 }

proc save {name data} {
  global out
  set f [open $out/$name wb]; fconfigure $f -translation binary
  puts -nonewline $f $data; close $f
}

proc dump {tag} {
  global D sel shadow
  save ${tag}_vram.bin [debug read_block "$D VRAM" 0 524288]
  save ${tag}_palette.bin [debug read_block "$D palette" 0 256]
  set regs [debug read_block "$D regs" 0 32]
  for {set r 32} {$r < 64} {incr r} { append regs [binary format c $shadow($r)] }
  save ${tag}_regs.bin $regs
  save ${tag}_regsel.txt "$sel\n"
}

proc wio {} {
  global sel phase t1_after log shadow len out
  set p [expr {$::wp_last_address & 0xff}]
  set v $::wp_last_value
  if {$p == 0x63} {
    set r [expr {$sel & 0x3f}]
    if {$r == 52 && $phase == 1} {
      dump t0
      set log [open $out/accesses.log w]
      set phase 2
      set t1_after [expr {[machine_info time] + $len}]
      set ::rw [debug set_watchpoint read_io {0x60 0x61} {} rio]
    } elseif {$r == 52 && $phase == 2 && [machine_info time] > $t1_after} {
      dump t1
      close $log
      set phase 3
      debug remove_watchpoint $::rw
      after time 0.1 exit
    }
    set shadow($r) $v
  }
  if {$phase == 2} { puts $log "[format %02x $p] [format %02x $v]" }
  if {$p == 0x64} {
    set sel $v
  } elseif {$p == 0x63 && !($sel & 0x80)} {
    set sel [expr {($sel & 0xc0) | (($sel + 1) & 0x3f)}]
  }
}

proc rio {} {
  global sel phase log
  set p [expr {$::wp_last_address & 0xff}]
  if {$phase == 2} { puts $log "[format %02x $p] r" }
  if {$p == 0x63 && !($sel & 0x40)} { set sel [expr {(($sel + 1) & 0x3f) & ~0x40}] }
}

debug set_watchpoint write_io {0x60 0x6f} {} wio
debug set_watchpoint read_io 0x63 {} rio

if {[info exists ::env(TRACE_KEYS)]} {
  foreach k $::env(TRACE_KEYS) {
    lassign $k t row mask hold
    after time $t "keymatrixdown $row $mask"
    after time [expr {$t + $hold}] "keymatrixup $row $mask"
  }
}
after time $t0 { set phase 1 }
after time [expr {$t0 + $len + 30}] exit
