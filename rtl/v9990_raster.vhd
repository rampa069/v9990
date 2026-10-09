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
      vcnt_o      : out unsigned(8 downto 0);     -- 0 .. 261 / 312
      mode_o      : out dmode_t;                  -- display mode of this line
      frame_o     : out std_logic;                -- first clock of a frame
      irq_v_o     : out std_logic;
      irq_h_o     : out std_logic;
      hr_o        : out std_logic;                -- status HR: outside the display columns
      vr_o        : out std_logic;                -- status VR: outside the display lines
      disp_o      : out std_logic;                -- display area and display enabled
      left_o      : out unsigned(11 downto 0);    -- first clock of the display area
      top_o       : out unsigned(8 downto 0);     -- first line of the display area
      bottom_o    : out unsigned(8 downto 0);     -- first line after it
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
   signal vcnt      : unsigned(8 downto 0) := (others => '0');
   signal mode      : dmode_t := DM_P1;
   signal pal_f     : std_logic := '0';     -- frame settings
   signal il_f      : std_logic := '0';
   signal disp_en_f : std_logic := '0';
   signal os_f      : boolean := false;

   signal left, right : unsigned(11 downto 0);
   signal top, bottom : unsigned(8 downto 0);
   signal hr, vr      : std_logic;
   signal hl_line     : unsigned(10 downto 0);
   signal hl_x        : unsigned(11 downto 0);

begin

   -- Display area.
   process (mode, regs)
      variable adj : signed(4 downto 0);
      variable l   : integer;
   begin
      adj := signed('0' & (regs(R_DISPADJ)(3 downto 0) xor "0111")) - 8;
      if is_overscan(mode) then
         l := H_BLANK_OS + to_integer(adj) * 8;
         right <= to_unsigned(l + H_DISPLAY_OS, 12);
      else
         l := H_BLANK + H_BORDER + to_integer(adj) * 8;
         right <= to_unsigned(l + H_DISPLAY, 12);
      end if;
      left <= to_unsigned(l, 12);
   end process;

   process (os_f, pal_f, regs)
      variable adj : signed(4 downto 0);
      variable t   : integer;
   begin
      adj := signed('0' & (regs(R_DISPADJ)(7 downto 4) xor "0111")) - 8;
      if os_f then
         t := V_BLANK + to_integer(adj);
         if pal_f = '1' then
            bottom <= to_unsigned(t + V_DISPLAY_OS_PAL, 9);
         else
            bottom <= to_unsigned(t + V_DISPLAY_OS_NTSC, 9);
         end if;
      else
         if pal_f = '1' then
            t := V_BLANK + V_BORDER_PAL + to_integer(adj);
         else
            t := V_BLANK + V_BORDER_NTSC + to_integer(adj);
         end if;
         bottom <= to_unsigned(t + V_DISPLAY, 9);
      end if;
      top <= to_unsigned(t, 9);
   end process;

   -- Line interrupt position: line and clock, the offset (up to 2880
   -- clocks) carried into the next line.
   process (regs, mcs, top)
      variable off  : unsigned(11 downto 0);
      variable line : unsigned(10 downto 0);
   begin
      if mcs = '1' then
         off := resize(resize(unsigned(regs(R_INT3)(3 downto 0)), 12) * 192, 12);
      else
         off := resize(resize(unsigned(regs(R_INT3)(3 downto 0)), 12) * 128, 12);
      end if;
      line := unsigned(std_logic_vector'(regs(R_INT2)(1 downto 0) & regs(R_INT1))) + resize(top, 11);
      if off >= H_TOTAL then
         off  := off - H_TOTAL;
         line := line + 1;
      end if;
      hl_x    <= off;
      hl_line <= line;
   end process;

   hr <= '1' when hcnt < left or hcnt >= right else '0';
   vr <= '1' when vcnt < top or vcnt >= bottom else '0';

   process (clk) begin if rising_edge(clk) then
      frame_o <= '0';
      irq_v_o <= '0';
      irq_h_o <= '0';

      if hcnt = H_TOTAL - 1 then
         hcnt <= (others => '0');
         mode <= dmode_of(regs(R_SCRMODE0), mcs);
         if (pal_f = '1' and vcnt = 312) or (pal_f = '0' and vcnt = 261) then
            vcnt      <= (others => '0');
            frame_o   <= '1';
            pal_f     <= regs(R_SCRMODE1)(3);
            il_f      <= regs(R_SCRMODE1)(1);
            disp_en_f <= regs(R_CONTROL)(7);
            os_f      <= is_overscan(dmode_of(regs(R_SCRMODE0), mcs));
         else
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
   end if; end process;

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
   last_line_o <= '1' when (pal_f = '1' and vcnt = 312) or (pal_f = '0' and vcnt = 261) else '0';
   interlace_o <= il_f;

   -- Video signals: the picture is the display area and the border; the
   -- overscan modes have no border, the picture is the display area
   -- (moved by R#16 like openMSX shows it).
   hblank_o  <= hr when is_overscan(mode) else
                '1' when hcnt < H_BLANK or hcnt >= H_BLANK + 2 * H_BORDER + H_DISPLAY else
                '0';
   vblank_o  <= vr when os_f else
                '1' when vcnt < V_BLANK
                      or (pal_f = '0' and vcnt >= V_BLANK + 2 * V_BORDER_NTSC + V_DISPLAY)
                      or (pal_f = '1' and vcnt >= V_BLANK + 2 * V_BORDER_PAL + V_DISPLAY) else
                '0';
   hsync_n_o <= '0' when hcnt < 200 else '1';
   vsync_n_o <= '0' when vcnt < 3 else '1';

end rtl;
