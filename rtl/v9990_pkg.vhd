--
-- V9990 (E-VDP-III) for FPGA retro computer cores.
--
-- Released under the 3-Clause BSD License:
--
-- Copyright 2026 Ramon Martinez
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
-- 1. Redistributions of source code must retain the above copyright notice,
-- this list of conditions and the following disclaimer.
--
-- 2. Redistributions in binary form must reproduce the above copyright
-- notice, this list of conditions and the following disclaimer in the
-- documentation and/or other materials provided with the distribution.
--
-- 3. Neither the name of the copyright holder nor the names of its
-- contributors may be used to endorse or promote products derived from this
-- software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
-- LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
-- CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
-- SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
-- INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
-- CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
-- ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
-- POSSIBILITY OF SUCH DAMAGE.

-- Common definitions of the V9990: register numbers, register access and
-- write masks (as found by openMSX on a real chip) and the VRAM address
-- mapping.
--
-- VRAM: 512 KB in two 8-bit banks side by side, seen here as 256K 16-bit
-- words (bank 0 = bits 7-0, bank 1 = bits 15-8).  A physical byte address
-- p has the bank in bit 18 and the word in bits 17-0.  The CPU and the
-- command engine use logical addresses, mapped per display mode:
--    P1  physical = logical (layer A in bank 0, layer B in bank 1)
--    Bx  the banks interleaved: even bytes in bank 0, odd in bank 1
--    P2  like Bx below 78000h, then two 16 KB tables moved (openMSX
--        V9990VRAM::transformP2)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package v9990_pkg is

   subtype byte_t is std_logic_vector(7 downto 0);
   type byte_array is array (natural range <>) of byte_t;

   -- Registers.
   constant R_VWA0      : natural := 0;    -- VRAM write address (3)
   constant R_VRA0      : natural := 3;    -- VRAM read address (3)
   constant R_SCRMODE0  : natural := 6;
   constant R_SCRMODE1  : natural := 7;
   constant R_CONTROL   : natural := 8;
   constant R_INT0      : natural := 9;    -- interrupt enable
   constant R_INT1      : natural := 10;   -- line interrupt
   constant R_INT2      : natural := 11;
   constant R_INT3      : natural := 12;
   constant R_PALCTRL   : natural := 13;
   constant R_PALPTR    : natural := 14;
   constant R_BACKDROP  : natural := 15;
   constant R_DISPADJ   : natural := 16;
   constant R_SCAY0     : natural := 17;   -- scroll A (4), B (4)
   constant R_SCBY0     : natural := 21;
   constant R_SPRTBL    : natural := 25;
   constant R_LCD       : natural := 26;
   constant R_PRIORITY  : natural := 27;
   constant R_SPRPAL    : natural := 28;
   constant R_CMD_FIRST : natural := 32;   -- command parameters
   constant R_CMD_OP    : natural := 52;
   constant R_BORDERX0  : natural := 53;   -- read only, from the command engine
   constant R_BORDERX1  : natural := 54;

   -- Ports (60h + n).
   constant P_VRAM      : natural := 0;
   constant P_PALETTE   : natural := 1;
   constant P_CMDDATA   : natural := 2;
   constant P_REGDATA   : natural := 3;
   constant P_REGSEL    : natural := 4;
   constant P_STATUS    : natural := 5;
   constant P_INTFLAG   : natural := 6;
   constant P_SYSCTRL   : natural := 7;

   -- Interrupt flags (P#6) and enables (R#9).
   constant IRQ_V       : natural := 0;
   constant IRQ_H       : natural := 1;
   constant IRQ_CE      : natural := 2;

   function reg_readable(r : natural) return boolean;
   function reg_writable(r : natural) return boolean;
   function reg_mask(r : natural) return byte_t;

   -- Display modes (openMSX V9990DisplayMode): R#6 DSPM / DCKM and P#7 MCS.
   -- B0, B2, B4 are the overscan modes (MCS = 1: no border, 240 lines).
   type dmode_t is (DM_P1, DM_P2, DM_B0, DM_B1, DM_B2, DM_B3, DM_B4, DM_B7);
   function dmode_of(scrmode0 : byte_t; mcs : std_logic) return dmode_t;
   function is_overscan(m : dmode_t) return boolean;
   function is_bitmap(m : dmode_t) return boolean;
   function pixel_clocks(m : dmode_t) return natural;   -- clocks per pixel
   function pixels(m : dmode_t) return natural;         -- pixels per line

   -- Display timing, in 42.95 MHz clocks (horizontal) and lines.
   constant H_TOTAL       : natural := 2736;
   constant H_BLANK       : natural := 400;    -- normal modes
   constant H_BORDER      : natural := 112;
   constant H_DISPLAY     : natural := 2048;
   constant H_BLANK_OS    : natural := 372;    -- overscan modes, no border
   constant H_DISPLAY_OS  : natural := 2304;
   constant V_BLANK       : natural := 15;
   constant V_BORDER_NTSC : natural := 14;
   constant V_BORDER_PAL  : natural := 41;
   constant V_DISPLAY     : natural := 212;
   constant V_DISPLAY_OS_NTSC : natural := 240;
   constant V_DISPLAY_OS_PAL  : natural := 290;

   type vmap_t is (MAP_P1, MAP_P2, MAP_BX);
   function vmap_of(scrmode0 : byte_t) return vmap_t;
   function vram_phys(a : unsigned(18 downto 0); m : vmap_t) return unsigned;

end package;

package body v9990_pkg is

   function reg_readable(r : natural) return boolean is
   begin
      case r is
         when 6 to 12 | 15 to 27 | 53 | 54 => return true;
         when others => return false;
      end case;
   end function;

   function reg_writable(r : natural) return boolean is
   begin
      case r is
         when 0 to 28 | 32 to 52 => return true;
         when others => return false;
      end case;
   end function;

   function reg_mask(r : natural) return byte_t is
   begin
      case r is
         when 9  => return x"87";
         when 11 => return x"83";
         when 12 => return x"0F";
         when 18 => return x"DF";
         when 19 => return x"07";
         when 22 => return x"C1";
         when 23 => return x"07";
         when 24 => return x"3F";
         when 25 => return x"CF";
         when others => return x"FF";
      end case;
   end function;

   function dmode_of(scrmode0 : byte_t; mcs : std_logic) return dmode_t is
   begin
      case scrmode0(7 downto 6) is
         when "01" => return DM_P2;
         when "10" =>
            if mcs = '1' then
               case scrmode0(5 downto 4) is
                  when "00"   => return DM_B0;
                  when "01"   => return DM_B2;
                  when "10"   => return DM_B4;
                  when others => return DM_P1;   -- invalid: P1 like openMSX
               end case;
            else
               case scrmode0(5 downto 4) is
                  when "00"   => return DM_B1;
                  when "01"   => return DM_B3;
                  when "10"   => return DM_B7;
                  when others => return DM_P1;
               end case;
            end if;
         when others => return DM_P1;
      end case;
   end function;

   function is_overscan(m : dmode_t) return boolean is
   begin
      return m = DM_B0 or m = DM_B2 or m = DM_B4;
   end function;

   function is_bitmap(m : dmode_t) return boolean is
   begin
      return m /= DM_P1 and m /= DM_P2;
   end function;

   function pixel_clocks(m : dmode_t) return natural is
   begin
      case m is
         when DM_B0 => return 12;
         when DM_B1 | DM_P1 => return 8;
         when DM_B2 => return 6;
         when DM_B3 | DM_P2 => return 4;
         when DM_B4 => return 3;
         when DM_B7 => return 2;
      end case;
   end function;

   -- (A table: written as a division Quartus builds a divider.)
   function pixels(m : dmode_t) return natural is
   begin
      case m is
         when DM_B0 => return 192;       -- 2304 / 12
         when DM_B1 | DM_P1 => return 256;
         when DM_B2 => return 384;       -- 2304 / 6
         when DM_B3 | DM_P2 => return 512;
         when DM_B4 => return 768;       -- 2304 / 3
         when DM_B7 => return 1024;
      end case;
   end function;

   -- R#6 DSPM: 00 P1, 01 P2, 10 bitmap, 11 invalid (P1 in openMSX).
   function vmap_of(scrmode0 : byte_t) return vmap_t is
   begin
      case scrmode0(7 downto 6) is
         when "01"   => return MAP_P2;
         when "10"   => return MAP_BX;
         when others => return MAP_P1;
      end case;
   end function;

   function vram_phys(a : unsigned(18 downto 0); m : vmap_t) return unsigned is
      variable bx : unsigned(18 downto 0);
   begin
      bx := a(0) & a(18 downto 1);
      case m is
         when MAP_P1 => return a;
         when MAP_BX => return bx;
         when MAP_P2 =>
            if a < 16#78000# then
               return bx;
            elsif a < 16#7C000# then
               return a - to_unsigned(16#3C000#, 19);
            else
               return a;
            end if;
      end case;
   end function;

end package body;
