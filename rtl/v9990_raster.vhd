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


-- V9990 display timing (openMSX V9990, V9990DisplayTiming): one line is
-- 2736 clocks of 42.95 MHz in every mode, 262 (NTSC) or 313 (PAL, R#7 PAL)
-- lines per frame.
--
--   line:   blank 400, border 112, display 2048, border 112, rest
--           (overscan modes B0 / B2 / B4: blank 372, display 2304)
--   frame:  blank 15, border 14 / 41 (PAL), display 212, border
--           (overscan: no border, 240 / 290 lines)
--
-- R#16 moves the display area: left = blank + border + (adj - 8) * 8 and
-- top = blank + border + (adj - 8) with adj = nibble xor 7.  The display
-- mode follows R#6 / MCS at the start of each line, the vertical timing,
-- PAL, interlace and display enable (R#8 DISP) are taken at the start of
-- the frame.
--
-- High scan (R#7 HSCN, B5 / B6, not in openMSX): the line and the frame of
-- the V9990 Application Manual (see v9990_pkg), no border, no PAL /
-- interlace (R#7 PAL, EO, IL are invalid there) and the display area not
-- moved by R#16 (the right erase of B6 is 27 clocks).  The mode is taken
-- at the start of the frame and kept for all its lines.
--
-- Interrupts: VI at the first line after the display area; HI at line
-- R#10 + 256 * R#11 (from the top of the display area), every line with
-- R#11 bit 7, R#12 * 64 master clocks into the line.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_raster is
   port (
      clk         : in  std_logic;
      reset_n     : in  std_logic;
      regs        : in  byte_array(0 to 63);
      mcs         : in  std_logic;

      hcnt_o      : out unsigned(11 downto 0);    -- 0 .. 2735
      vcnt_o      : out unsigned(9 downto 0);     -- 0 .. 261 / 312 (B5 439, B6 524)
      mode_o      : out dmode_t;                  -- display mode of this line
      frame_o     : out std_logic;                -- first clock of a frame
      irq_v_o     : out std_logic;
      irq_h_o     : out std_logic;
      hr_o        : out std_logic;                -- status HR: outside the display columns
      vr_o        : out std_logic;                -- status VR: outside the display lines
      disp_o      : out std_logic;                -- display area and display enabled
      left_o      : out unsigned(11 downto 0);    -- first clock of the display area
      top_o       : out unsigned(9 downto 0);     -- first line of the display area
      bottom_o    : out unsigned(9 downto 0);     -- first line after it
      disp_en_o   : out std_logic;                -- R#8 DISP of this frame
      pal_o       : out std_logic;                -- PAL timing of this frame
      last_line_o : out std_logic;                -- the last line of the frame
      interlace_o : out std_logic;
      hblank_o    : out std_logic;
      vblank_o    : out std_logic;
      hsync_n_o   : out std_logic;
      vsync_n_o   : out std_logic
   );
end v9990_raster;

architecture rtl of v9990_raster is

   signal hcnt      : unsigned(11 downto 0) := (others => '0');
   signal vcnt      : unsigned(9 downto 0) := (others => '0');
   signal mode      : dmode_t := DM_P1;
   signal pal_f     : std_logic := '0';     -- frame settings
   signal il_f      : std_logic := '0';
   signal disp_en_f : std_logic := '0';
   signal os_f      : boolean := false;

   signal left, right : unsigned(11 downto 0);
   signal top, bottom : unsigned(9 downto 0);
   signal line_len    : unsigned(11 downto 0);
   signal sync_len    : unsigned(11 downto 0);
   signal last_line   : boolean;
   signal hr, vr      : std_logic;
   signal hl_line     : unsigned(10 downto 0);
   signal hl_x        : unsigned(11 downto 0);

begin

   -- Line and frame of the mode.
   line_len  <= to_unsigned(H_TOTAL_B5, 12) when mode = DM_B5 else
                to_unsigned(H_TOTAL_B6, 12) when mode = DM_B6 else
                to_unsigned(H_TOTAL, 12);
   sync_len  <= to_unsigned(H_SYNC_B5, 12) when mode = DM_B5 else
                to_unsigned(H_SYNC_B6, 12) when mode = DM_B6 else
                to_unsigned(200, 12);
   last_line <= vcnt = V_TOTAL_B5 - 1 when mode = DM_B5 else
                vcnt = V_TOTAL_B6 - 1 when mode = DM_B6 else
                vcnt = 312 when pal_f = '1' else
                vcnt = 261;

   -- Display area.
   process (mode, regs)
      variable adj : signed(4 downto 0);
      variable l   : integer;
   begin
      adj := signed('0' & (regs(R_DISPADJ)(3 downto 0) xor "0111")) - 8;
      if mode = DM_B5 then
         l := H_LEFT_B5;
         right <= to_unsigned(l + H_DISPLAY_B5, 12);
      elsif mode = DM_B6 then
         l := H_LEFT_B6;
         right <= to_unsigned(l + H_DISPLAY_B6, 12);
      elsif is_overscan(mode) then
         l := H_BLANK_OS + to_integer(adj) * 8;
         right <= to_unsigned(l + H_DISPLAY_OS, 12);
      else
         l := H_BLANK + H_BORDER + to_integer(adj) * 8;
         right <= to_unsigned(l + H_DISPLAY, 12);
      end if;
      left <= to_unsigned(l, 12);
   end process;

   process (mode, os_f, pal_f, regs)
      variable adj : signed(4 downto 0);
      variable t   : integer;
   begin
      adj := signed('0' & (regs(R_DISPADJ)(7 downto 4) xor "0111")) - 8;
      if mode = DM_B5 then
         t := V_TOP_B5;
         bottom <= to_unsigned(t + V_DISPLAY_B5, 10);
      elsif mode = DM_B6 then
         t := V_TOP_B6;
         bottom <= to_unsigned(t + V_DISPLAY_B6, 10);
      elsif os_f then
         t := V_BLANK + to_integer(adj);
         if pal_f = '1' then
            bottom <= to_unsigned(t + V_DISPLAY_OS_PAL, 10);
         else
            bottom <= to_unsigned(t + V_DISPLAY_OS_NTSC, 10);
         end if;
      else
         if pal_f = '1' then
            t := V_BLANK + V_BORDER_PAL + to_integer(adj);
         else
            t := V_BLANK + V_BORDER_NTSC + to_integer(adj);
         end if;
         bottom <= to_unsigned(t + V_DISPLAY, 10);
      end if;
      top <= to_unsigned(t, 10);
   end process;

   -- Line interrupt position: line and clock, the offset (up to 2880
   -- clocks) carried into the next line (B5 / B6: up to two lines).
   process (regs, mcs, top, line_len)
      variable off  : unsigned(11 downto 0);
      variable line : unsigned(10 downto 0);
   begin
      if mcs = '1' then
         off := resize(resize(unsigned(regs(R_INT3)(3 downto 0)), 12) * 192, 12);
      else
         off := resize(resize(unsigned(regs(R_INT3)(3 downto 0)), 12) * 128, 12);
      end if;
      line := unsigned(std_logic_vector'(regs(R_INT2)(1 downto 0) & regs(R_INT1))) + resize(top, 11);
      for k in 1 to 2 loop
         if off >= line_len then
            off  := off - line_len;
            line := line + 1;
         end if;
      end loop;
      hl_x    <= off;
      hl_line <= line;
   end process;

   hr <= '1' when hcnt < left or hcnt >= right else '0';
   vr <= '1' when vcnt < top or vcnt >= bottom else '0';

   process (clk)
      variable m : dmode_t;
   begin
      if rising_edge(clk) then
         frame_o <= '0';
         irq_v_o <= '0';
         irq_h_o <= '0';

         if hcnt = line_len - 1 then
            hcnt <= (others => '0');
            m := hs_mode_of(regs(R_SCRMODE0), regs(R_SCRMODE1), mcs);
            if last_line then
               vcnt      <= (others => '0');
               frame_o   <= '1';
               disp_en_f <= regs(R_CONTROL)(7);
               mode      <= m;
               if is_highscan(m) then
                  pal_f <= '0';
                  il_f  <= '0';
                  os_f  <= false;
               else
                  pal_f <= regs(R_SCRMODE1)(3);
                  il_f  <= regs(R_SCRMODE1)(1);
                  os_f  <= is_overscan(m);
               end if;
            else
               -- B5 / B6 for the whole frame, the other modes by line.
               if not is_highscan(mode) then
                  mode <= dmode_of(regs(R_SCRMODE0), mcs);
               end if;
               vcnt <= vcnt + 1;
               if vcnt + 1 = bottom then
                  irq_v_o <= '1';
               end if;
            end if;
         else
            hcnt <= hcnt + 1;
         end if;

         if hcnt = hl_x and (regs(R_INT2)(7) = '1' or resize(vcnt, 11) = hl_line) then
            irq_h_o <= '1';
         end if;

         if reset_n = '0' then
            hcnt      <= (others => '0');
            vcnt      <= (others => '0');
            pal_f     <= '0';
            il_f      <= '0';
            disp_en_f <= '0';
            os_f      <= false;
            mode      <= DM_P1;
         end if;
      end if;
   end process;

   hcnt_o      <= hcnt;
   vcnt_o      <= vcnt;
   mode_o      <= mode;
   hr_o        <= hr;
   vr_o        <= vr;
   disp_o      <= disp_en_f and not hr and not vr;
   left_o      <= left;
   top_o       <= top;
   bottom_o    <= bottom;
   disp_en_o   <= disp_en_f;
   pal_o       <= pal_f;
   last_line_o <= '1' when last_line else '0';
   interlace_o <= il_f;

   -- Video signals: the picture is the display area and the border; the
   -- overscan modes have no border, the picture is the display area
   -- (moved by R#16 like openMSX shows it); B5 / B6 have no border either.
   hblank_o  <= hr when is_overscan(mode) or is_highscan(mode) else
                '1' when hcnt < H_BLANK or hcnt >= H_BLANK + 2 * H_BORDER + H_DISPLAY else
                '0';
   vblank_o  <= vr when os_f or is_highscan(mode) else
                '1' when vcnt < V_BLANK
                      or (pal_f = '0' and vcnt >= V_BLANK + 2 * V_BORDER_NTSC + V_DISPLAY)
                      or (pal_f = '1' and vcnt >= V_BLANK + 2 * V_BORDER_PAL + V_DISPLAY) else
                '0';
   hsync_n_o <= '0' when hcnt < sync_len else '1';
   vsync_n_o <= '0' when (mode = DM_B5 and vcnt < V_SYNC_B5)
                      or (mode = DM_B6 and vcnt < V_SYNC_B6)
                      or (not is_highscan(mode) and vcnt < 3) else '1';

end rtl;
