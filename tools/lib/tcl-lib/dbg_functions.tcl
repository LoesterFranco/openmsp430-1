#------------------------------------------------------------------------------
# Copyright (C) 2001 Authors
#
# This source file may be used and distributed without restriction provided
# that this copyright statement is not removed from the file and that any
# derivative work contains the original copyright notice and the associated
# disclaimer.
#
# This source file is free software; you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published
# by the Free Software Foundation; either version 2.1 of the License, or
# (at your option) any later version.
#
# This source is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
# License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this source; if not, write to the Free Software Foundation,
# Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
#
#------------------------------------------------------------------------------
# 
# File Name:   dbg_functions.tcl
#
# Description: Main utility functions for the openMSP430 serial debug
#             interface.
#
#       The following functions are implemented according to the SLAA149
#     application report from TI (Programming a Flash-Based MSP430 Using the
#     JTAG Interface):
#
#               - ExecutePOR      ()
#               - SetPC           (Addr)
#               - HaltCPU         ()
#               - ReleaseCPU      ()
#               - GetDevice       ()
#               - ReleaseDevice   (Addr)
#               - WriteMem        (Format,    Addr,     Data)
#               - WriteMemQuick   (StartAddr, DataArray)
#               - ReadMem         (Format,    Addr)
#               - ReadMemQuick    (StartAddr, Length)
#               - VerifyMem       (StartAddr, DataArray)
#
#
#       The following have been added:
#
#               - ExecutePOR_Halt ()
#               - GetCPU_ID       ()
#               - GetCPU_ID_SIZE  ()
#               - VerifyCPU_ID    (CPU_ID)
#               - WriteReg        (Addr,      Data)
#               - WriteRegAll     (DataArray)
#               - ReadReg         (Addr)
#               - ReadRegAll      ()
#               - WriteMemQuick8  (StartAddr, DataArray)
#               - ReadMemQuick8   (StartAddr, Length)
#               - StepCPU         ()
#               - EraseRAM        ()
#               - EraseROM        ()
#               - InitBreakUnits  ()
#               - SetHWBreak      (Type, Addr,      Rd,       Wr)
#               - ClearHWBreak    (Type, Addr)
#               - IsHalted        ()
#               - ClrStatus       ()
# 
#------------------------------------------------------------------------------

# GLOBAL VARIABLES
global hw_break

# SOURCE REQUIRED LIBRARIES
source [file dirname [info script]]/dbg_uart.tcl

#=============================================================================#
# ExecutePOR ()                                                               #
#-----------------------------------------------------------------------------#
# Description: Executes a power-up clear (PUC) command.                       #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ExecutePOR {} {
  
    set result 1

    # Set PUC
    set cpu_ctl_org [dbg_uart_rd CPU_CTL]
    set cpu_ctl_new [expr 0x40 | $cpu_ctl_org]
    dbg_uart_wr CPU_CTL $cpu_ctl_new

    # Remove PUC, clear break after reset
    set cpu_ctl_org [expr 0x5f & $cpu_ctl_org]
    dbg_uart_wr CPU_CTL $cpu_ctl_org

    # Check CPU ID
    if {![VerifyCPU_ID 0x4d5350]} {
	set result 0
    }

    # Check status: make sure a PUC occured
    set cpu_stat_val [dbg_uart_rd CPU_STAT]
    set puc_pnd      [expr 0x04 & $cpu_stat_val]
    if {![string eq $puc_pnd 4]} {
	set result 0
    }

    # Clear PUC pending flag
    dbg_uart_wr CPU_STAT 0x04

    return $result
}

#=============================================================================#
# SetPC (Addr)                                                                #
#-----------------------------------------------------------------------------#
# Description: Loads the target device CPU's program counter (PC) with the    #
#              desired 16-bit address.                                        #
# Arguments  : Addr - Desired 16-bit PC value (in hexadecimal).               #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc SetPC {Addr} {

    return [WriteReg 0 $Addr]
}

#=============================================================================#
# HaltCPU ()                                                                  #
#-----------------------------------------------------------------------------#
# Description: Sends the target CPU into a controlled, stopped state.         #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc HaltCPU {} {
  
    set result 1

    # Stop CPU
    set cpu_ctl_org [dbg_uart_rd CPU_CTL]
    set cpu_ctl_new [expr 0x01 | $cpu_ctl_org]
    dbg_uart_wr CPU_CTL $cpu_ctl_new

    # Check status: make sure the CPU halted
    set cpu_stat_val [dbg_uart_rd CPU_STAT]
    set halted       [expr 0x01 & $cpu_stat_val]
    if {![string eq $halted 1]} {
	set result 0
    }

    return $result
}

#=============================================================================#
# ReleaseCPU ()                                                               #
#-----------------------------------------------------------------------------#
# Description: Releases the target device's CPU from the controlled, stopped  #
#              state. (Does not release the target device from debug control.)#
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ReleaseCPU {} {
  
    set result 1

    # Start CPU
    set cpu_ctl_org [dbg_uart_rd CPU_CTL]
    set cpu_ctl_new [expr 0x02 | $cpu_ctl_org]
    dbg_uart_wr CPU_CTL $cpu_ctl_new

    # Check status: make sure the CPU runs
    set cpu_stat_val [dbg_uart_rd CPU_STAT]
    set halted       [expr 0x01 & $cpu_stat_val]
    if {![string eq $halted 0]} {
	set result 0
    }

    return $result
}

#=============================================================================#
# GetDevice ()                                                                #
#-----------------------------------------------------------------------------#
# Description: Takes the target MSP430 device under JTAG control.             #
#              Enable the auto-freeze feature of timers when in the CPU is    #
#              stopped. This prevents an automatic watchdog reset condition.  #
#              Enables software breakpoints.                                  #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc GetDevice {} {
    
    global hw_break

    # Set UART global variables
    if {![info exists ::serial_baudrate]} {
	set ::serial_baudrate 9600
    }
    if {![info exists ::serial_device]} {
	set ::serial_device   /dev/ttyUSB0
    }

    # Open connection
    if {![dbg_uart_connect $::serial_device $::serial_baudrate]} {
	return 0
    }

    # Enable auto-freeze & software breakpoints
    dbg_uart_wr CPU_CTL 0x0018

    # Get number of hardware breakpoints
    set hw_break(num) [InitBreakUnits]

    # Check CPU ID
    if {[VerifyCPU_ID 0x4d5350]} {
	return 1
    } else {
	return 0
    }
}

#=============================================================================#
# ReleaseDevice (Addr)                                                        #
#-----------------------------------------------------------------------------#
# Description: Releases the target device from JTAG control; CPU starts       #
#              execution at the specified PC address.                         #
# Arguments  : Addr - (0xfffe: perform reset; address at reset vector loaded  #
#                 into PC; otherwise address specified by Addr loaded into PC #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ReleaseDevice {Addr} {

    if {[expr $Addr]==[expr 0xfffe]} {
	set result 1
	set result [expr $result+[ExecutePOR]]
	set result [expr $result+[ReleaseCPU]]
    } else {
	set result 0
	set result [expr $result+[HaltCPU]]
	set result [expr $result+[SetPC $Addr]]
	set result [expr $result+[ReleaseCPU]]
    }

    if {$result==3} {
	return 1
    } else {
	return 0
    }
}

#=============================================================================#
# WriteMem (Format, Addr, Data)                                               #
#-----------------------------------------------------------------------------#
# Description: Write a single byte or word to a given address (RAM, ROM &     #
#              Peripherals.                                                   #
# Arguments  : Format - 0 to write a word, 1 to write a byte.                 #
#              Addr   - Destination address for data to be written.           #
#              Data   - Data value to be written.                             #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc WriteMem {Format Addr Data} {

    dbg_uart_wr MEM_CNT  0x0000
    dbg_uart_wr MEM_ADDR $Addr
    dbg_uart_wr MEM_DATA $Data

    if {$Format==0} {
	dbg_uart_wr MEM_CTL  0x0003
    } else {
	dbg_uart_wr MEM_CTL  0x000b
    }

    return 1
}

#=============================================================================#
# WriteMemQuick (StartAddr, DataArray)                                        #
#-----------------------------------------------------------------------------#
# Description: Writes an array of words into the target device memory (RAM,   #
#              ROM & Peripherals.                                             #
# Arguments  : StartAddr - Start address of destination memory.               #
#              DataArray - List of data to be written (in hexadecimal).       #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc WriteMemQuick {StartAddr DataArray} {

    if {[llength $DataArray]==1} {
	WriteMem 0 $StartAddr $DataArray
    } else {

	dbg_uart_wr MEM_CNT  [expr [llength $DataArray]-1]
	dbg_uart_wr MEM_ADDR $StartAddr
	dbg_uart_wr MEM_CTL  0x0003

	foreach data [split $DataArray] {

	    # Format data
	    set data [format %04x $data]
	    regexp {(..)(..)} $data match data_msb data_lsb

	    # Send data
	    dbg_uart_tx "0x$data_lsb 0x$data_msb"
	}
    }
    return 1
}

#=============================================================================#
# ReadMem (Format, Addr)                                                      #
#-----------------------------------------------------------------------------#
# Description: Read one byte or word from a specified target memory address.  #
# Arguments  : Format - 0 to read a word, 1 to read a byte.                   #
#              Addr   - Target address for data to be read.                   #
# Result     : Data value stored in the target address memory location.       #
#=============================================================================#
proc ReadMem {Format Addr} {

    dbg_uart_wr MEM_CNT  0x0000
    dbg_uart_wr MEM_ADDR $Addr

    if {$Format==0} {
	dbg_uart_wr MEM_CTL  0x0001
	set mem_val [dbg_uart_rd MEM_DATA]
    } else {
	dbg_uart_wr MEM_CTL  0x0009
	set mem_val [dbg_uart_rd MEM_DATA]
	set mem_val [format "0x%02x" $mem_val]
    }

    return $mem_val
}

#=============================================================================#
# ReadMemQuick (StartAddr, Length)                                            #
#-----------------------------------------------------------------------------#
# Description: Reads an array of words from target memory.                    #
# Arguments  : StartAddr - Start address of target memory to be read.         #
#              Length    - Number of word to be read.                         #
# Result     : List of data values stored in the target memory.               #
#=============================================================================#
proc ReadMemQuick {StartAddr Length} {

    if {$Length==1} {
	set mem_val [ReadMem 0 $StartAddr]
    } else {

	dbg_uart_wr MEM_CNT  [expr $Length-1]
	dbg_uart_wr MEM_ADDR $StartAddr
	dbg_uart_wr MEM_CTL  0x0001

	set mem_val [dbg_uart_rx 0 [expr $Length*2]]
    }
    return $mem_val
}

#=============================================================================#
# VerifyMem (StartAddr, DataArray)                                            #
#-----------------------------------------------------------------------------#
# Description: Performs a program verification over the given memory range.   #
# Arguments  : StartAddr - Start address of the memory to be verified.        #
#              DataArray - List of reference data (in hexadecimal).           #
# Result     : 0 if error, 1 if verification was successful.                  #
#=============================================================================#
proc VerifyMem {StartAddr DataArray} {

    dbg_uart_wr MEM_CNT  [expr [llength $DataArray]-1]
    dbg_uart_wr MEM_ADDR $StartAddr
    dbg_uart_wr MEM_CTL  0x0001

    set mem_val [dbg_uart_rx 0 [expr [llength $DataArray]*2]]

    return [string equal $DataArray $mem_val]
}

#=============================================================================#
# ExecutePOR_Halt ()                                                          #
#-----------------------------------------------------------------------------#
# Description: Same as ExecutePOR with the difference that the CPU            #
#              automatically goes in Halt mode after reset.                   #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ExecutePOR_Halt {} {
  
    set result 1

    # Perform PUC
    set cpu_ctl_org [dbg_uart_rd CPU_CTL]
    set cpu_ctl_new [expr 0x60 | $cpu_ctl_org]
    dbg_uart_wr CPU_CTL $cpu_ctl_new
    dbg_uart_wr CPU_CTL $cpu_ctl_org

    # Check CPU ID
    if {![VerifyCPU_ID 0x4d5350]} {
	set result 0
    }

    # Check status: make sure a PUC occured and that the CPU is halted
    set cpu_stat_val [dbg_uart_rd CPU_STAT]
    set puc_pnd      [expr 0x05 & $cpu_stat_val]
    if {![string eq $puc_pnd 5]} {
	set result 0
    }

    # Clear PUC pending flag
    dbg_uart_wr CPU_STAT 0x04

    return $result
}

#=============================================================================#
# GetCPU_ID ()                                                                #
#-----------------------------------------------------------------------------#
# Description: This function reads the CPU_ID from the target device.         #
# Arguments  : None.                                                          #
# Result     : Return CPU_ID.                                                 #
#=============================================================================#
proc GetCPU_ID { } {

    regsub {0x} [dbg_uart_rd CPU_ID_LO] {} cpu_id_lo
    regsub {0x} [dbg_uart_rd CPU_ID_HI] {} cpu_id_hi

    return "0x$cpu_id_hi$cpu_id_lo"
}

#=============================================================================#
# GetCPU_ID_SIZE ()                                                           #
#-----------------------------------------------------------------------------#
# Description: Returns the ROM and RAM sizes of the connected device.         #
# Arguments  : None.                                                          #
# Result     : Return "ROM_SIZE RAM_SIZE" in byte.                            #
#=============================================================================#
proc GetCPU_ID_SIZE { } {

    set cpu_id_full [GetCPU_ID]
    regexp {(.)(.)$} $cpu_id_full match rom_width ram_width

    set rom_size [expr (1<<0x$rom_width)*2]
    set ram_size [expr (1<<0x$ram_width)*2]

    return "$rom_size $ram_size"
}

#=============================================================================#
# VerifyCPU_ID (uint32 CPU_ID)                                                #
#-----------------------------------------------------------------------------#
# Description: Read and check the CPU_ID from the target device.              #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc VerifyCPU_ID {cpu_id} {

    set cpu_id_full [GetCPU_ID]
    regsub {..$} $cpu_id_full {} cpu_id_hi

    if {[string eq $cpu_id $cpu_id_hi]} {
	set result 1
    } else {
	set result 0
    }
    return $result
}

#=============================================================================#
# WriteReg (Addr,  Data)                                                      #
#-----------------------------------------------------------------------------#
# Description: Write a word to the the selected CPU register.                 #
# Arguments  : Addr - Target CPU Register number.                             #
#              Data - Data value to be written.                               #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc WriteReg {Addr Data} {

    dbg_uart_wr MEM_CNT  0x0000

    dbg_uart_wr MEM_ADDR $Addr
    dbg_uart_wr MEM_DATA $Data
    dbg_uart_wr MEM_CTL  0x0007

    return 1
}

#=============================================================================#
# WriteRegAll (DataArray)                                                     #
#-----------------------------------------------------------------------------#
# Description: Write all CPU registers.                                       #
# Arguments  : DataArray - Data values to be written.                         #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc WriteRegAll {DataArray} {

    dbg_uart_wr MEM_CNT  [expr [llength $DataArray]-1]
    dbg_uart_wr MEM_ADDR 0x0000
    dbg_uart_wr MEM_CTL  0x0007

    foreach data [split $DataArray] {

	# Format data
	set data [format %04x $data]
	regexp {(..)(..)} $data match data_msb data_lsb

	# Send data
	dbg_uart_tx "0x$data_lsb 0x$data_msb"
    }

    return 1
}

#=============================================================================#
# ReadReg (Addr)                                                              #
#-----------------------------------------------------------------------------#
# Description: Read the value from the selected CPU register.                 #
# Arguments  : Addr - Target CPU Register number.                             #
# Result     : Data value stored in the selected CPU register.                #
#=============================================================================#
proc ReadReg {Addr} {

    dbg_uart_wr MEM_CNT  0x0000

    dbg_uart_wr MEM_ADDR $Addr
    dbg_uart_wr MEM_CTL  0x0005
    set reg_val [dbg_uart_rd MEM_DATA]

    return $reg_val
}

#=============================================================================#
# ReadRegAll ()                                                               #
#-----------------------------------------------------------------------------#
# Description: Read all CPU registers.                                        #
# Arguments  : None.                                                          #
# Result     : Current values of all CPU registers.                           #
#=============================================================================#
proc ReadRegAll {} {

    dbg_uart_wr MEM_CNT  0x000f
    dbg_uart_wr MEM_ADDR 0x0000
    dbg_uart_wr MEM_CTL  0x0005

    set reg_val [dbg_uart_rx 0 32]

    return $reg_val
}

#=============================================================================#
# WriteMemQuick8 (StartAddr, DataArray)                                       #
#-----------------------------------------------------------------------------#
# Description: Writes an array of bytes into the target device memory (RAM,   #
#              ROM & Peripherals.                                             #
# Arguments  : StartAddr - Start address of destination memory.               #
#              DataArray - List of data to be written (in hexadecimal).       #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc WriteMemQuick8 {StartAddr DataArray} {

    if {[llength $DataArray]==1} {
	WriteMem 1 $StartAddr $DataArray
    } else {

	dbg_uart_wr MEM_CNT  [expr [llength $DataArray]-1]
	dbg_uart_wr MEM_ADDR $StartAddr
	dbg_uart_wr MEM_CTL  0x000b

	foreach data [split $DataArray] {

	    # Format data
	    set data [format %02x $data]

	    # Send data
	    dbg_uart_tx "0x$data"
	}
    }
    return 1
}

#=============================================================================#
# ReadMemQuick8 (StartAddr, Length)                                           #
#-----------------------------------------------------------------------------#
# Description: Reads an array of bytes from target memory.                    #
# Arguments  : StartAddr - Start address of target memory to be read.         #
#              Length    - Number of bytes to be read.                        #
# Result     : List of data values stored in the target memory.               #
#=============================================================================#
proc ReadMemQuick8 {StartAddr Length} {

    if {$Length==1} {
	set mem_val [ReadMem 1 $StartAddr]
    } else {
	dbg_uart_wr MEM_CNT  [expr $Length-1]
	dbg_uart_wr MEM_ADDR $StartAddr
	dbg_uart_wr MEM_CTL  0x0009

	set mem_val [dbg_uart_rx 1 [expr $Length]]
    }

    return $mem_val
}

#=============================================================================#
# StepCPU ()                                                                  #
#-----------------------------------------------------------------------------#
# Description: Performs a CPU incremental step.                               #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc StepCPU {} {

    # Check if the device is halted. If not, stop it.
    set cpu_ctl_val [dbg_uart_rd CPU_CTL]
    set cpu_ctl_new [expr 0x04 | $cpu_ctl_val]
    dbg_uart_wr CPU_CTL $cpu_ctl_new

    return 1
}

#=============================================================================#
# EraseRAM ()                                                                 #
#-----------------------------------------------------------------------------#
# Description: Erase RAM.                                                     #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc EraseRAM {} {

    set ram_size [lindex [GetCPU_ID_SIZE] 1]

    set DataArray ""
    for {set i 0} {$i<$ram_size} {incr i} {
	lappend DataArray 0x00
    }

    WriteMemQuick8 $0x0200 $DataArray

    return 1
}

#=============================================================================#
# EraseROM ()                                                                 #
#-----------------------------------------------------------------------------#
# Description: Erase ROM.                                                     #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc EraseROM {} {

    set rom_size  [lindex [GetCPU_ID_SIZE] 0]
    set rom_start [expr 0x10000-$rom_size]

    set DataArray ""
    for {set i 0} {$i<$rom_size} {incr i} {
	lappend DataArray 0x00
    }

    WriteMemQuick8 $rom_start $DataArray

    return 1
}

#=============================================================================#
# InitBreakUnits()                                                            #
#-----------------------------------------------------------------------------#
# Description: Initialize the hardware breakpoint units.                      #
# Arguments  : None.                                                          #
# Result     : Number of hardware breakpoint units.                           #
#=============================================================================#
proc InitBreakUnits {} {

    set num_brk_units 0
    for {set i 0} {$i<4} {incr i} {

	dbg_uart_wr "BRK$i\_ADDR0" 0x1234
	set new_val [dbg_uart_rd "BRK$i\_ADDR0"]
	if {$new_val=="0x1234"} {
	    incr num_brk_units
	    dbg_uart_wr "BRK$i\_CTL"   0x00
	    dbg_uart_wr "BRK$i\_STAT"  0xff
	    dbg_uart_wr "BRK$i\_ADDR0" 0x0000
	    dbg_uart_wr "BRK$i\_ADDR1" 0x0000
	}
    }
    return $num_brk_units
}

#=============================================================================#
# SetHWBreak(Type, Addr, Rd, Wr)                                              #
#-----------------------------------------------------------------------------#
# Description: Set data/instruction breakpoint on a given memory address.     #
# Arguments  : Type - 1 for instruction break, 0 for data break.              #
#              Addr - Memory address of the data breakpoint.                  #
#              Rd   - Breakpoint on read access.                              #
#              Wr   - Breakpoint on write access.                             #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc SetHWBreak {Type Addr Rd Wr} {
    global hw_break

    # Compute the BRKx_CTL corresponding value
    set brk_ctl_ref [format "0x02%x" [expr 8*$Type+4+2*$Wr+$Rd]]

    # First look for utilized units with correct BRKx_CTL attributes
    for {set i 0} {$i<$hw_break(num)} {incr i} {
	if {[string eq [dbg_uart_rd "BRK$i\_CTL"] $brk_ctl_ref]} {
	    # Look if there is an address free
	    set brk_addr0 [dbg_uart_rd "BRK$i\_ADDR0"]
	    set brk_addr1 [dbg_uart_rd "BRK$i\_ADDR1"]
	    if {[string eq $brk_addr0 $brk_addr1]} {
		dbg_uart_wr "BRK$i\_ADDR1" $Addr
		return 1
	    }
	}
    }

    # Then look for a free unit
    for {set i 0} {$i<$hw_break(num)} {incr i} {
	if {[string eq [dbg_uart_rd "BRK$i\_CTL"] 0x00]} {
	    dbg_uart_wr "BRK$i\_ADDR0" $Addr
	    dbg_uart_wr "BRK$i\_ADDR1" $Addr
	    dbg_uart_wr "BRK$i\_CTL"   $brk_ctl_ref
	    return 1
	}
    }

    return 0
}

#=============================================================================#
# ClearHWBreak(Type, Addr)                                                    #
#-----------------------------------------------------------------------------#
# Description: Clear the data/instruction breakpoint set on the provided      #
#              memory address.                                                #
# Arguments  : Type - 1 for instruction break, 0 for data break.              #
#              Addr - Data address of the breakpoint to be cleared.           #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ClearHWBreak {Type Addr} {
    global hw_break

    for {set i 0} {$i<$hw_break(num)} {incr i} {
	# Check if the unit works on Data or Instructions)
	set brk_ctl [dbg_uart_rd "BRK$i\_CTL"]
	if {[expr $brk_ctl & 0x08]==[expr 8*$Type]} {

	    # Look for the matching address
	    set brk_addr0 [dbg_uart_rd "BRK$i\_ADDR0"]
	    set brk_addr1 [dbg_uart_rd "BRK$i\_ADDR1"]

	    if {[string eq $brk_addr0 $brk_addr1] && [string eq $brk_addr0 $Addr]} {
		dbg_uart_wr "BRK$i\_CTL"   0x00
		dbg_uart_wr "BRK$i\_STAT"  0xff
		dbg_uart_wr "BRK$i\_ADDR0" 0x0000
		dbg_uart_wr "BRK$i\_ADDR1" 0x0000
		return 1
	    }
	    if {[string eq $brk_addr0 $Addr]} {
		dbg_uart_wr "BRK$i\_ADDR0" $brk_addr1
		return 1
	    }
	    if {[string eq $brk_addr1 $Addr]} {
		dbg_uart_wr "BRK$i\_ADDR1" $brk_addr0
		return 1
	    }
	}
    }
    return 1
}

#=============================================================================#
# IsHalted ()                                                                 #
#-----------------------------------------------------------------------------#
# Description: Check if the CPU is currently stopped or not.                  #
# Arguments  : None.                                                          #
# Result     : 0 if CPU is running, 1 if stopped.                             #
#=============================================================================#
proc IsHalted {} {

    # Check current target status
    set cpu_stat_val [dbg_uart_rd CPU_STAT]
    set halted       [expr 0x01 & $cpu_stat_val]

    return $halted
}

#=============================================================================#
# ClrStatus ()                                                                #
#-----------------------------------------------------------------------------#
# Description: Clear the status bit of the CPU_STAT register.                 #
# Arguments  : None.                                                          #
# Result     : 0 if error, 1 otherwise.                                       #
#=============================================================================#
proc ClrStatus {} {

    # Clear status
    dbg_uart_wr CPU_STAT  0xff
    dbg_uart_wr BRK0_STAT 0xff
    dbg_uart_wr BRK1_STAT 0xff
    dbg_uart_wr BRK2_STAT 0xff
    dbg_uart_wr BRK3_STAT 0xff

    return 1
}