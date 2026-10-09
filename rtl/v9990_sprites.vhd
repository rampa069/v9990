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


-- V9990 sprites of the pattern modes P1 / P2 (openMSX renderSprites, see
-- sim/v9990_model.Pattern._sprites): 125 sprites of 16 x 16, 4 bpp,
-- attributes at 3FE00h (physical), at most 16 per line (each disabled
-- sprite on the line lowers the limit), the lower number in front.  Front
-- sprites (attribute bit 5 = 0) cover the layers, back sprites only the
-- background (no front layer pixel).
--
-- During each line the sprites of the next one are found (scan of the
-- 125 Y), then fetched and drawn from the last to the first into a pixel
-- line buffer (so the lower numbers overwrite the higher ones); the buffer
-- of the shown line is cleared as it is read.  Pixel pipeline as in
-- v9990_pattern.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_sprites is
   port (
      clk          : in  std_logic;
      reset_n      : in  std_logic;
      regs         : in  byte_array(0 to 63);

      -- Raster.
      hcnt         : in  unsigned(11 downto 0);
      vcnt         : in  unsigned(8 downto 0);
      mode         : in  dmode_t;
      left         : in  unsigned(11 downto 0);
      top          : in  unsigned(8 downto 0);
      bottom       : in  unsigned(8 downto 0);
      disp_en      : in  std_logic;
      last_line    : in  std_logic;

      -- VRAM, reads.
      vram_req_o   : out std_logic;
      vram_addr_o  : out unsigned(17 downto 0);
      vram_ack_i   : in  std_logic;
      vram_rdata_i : in  std_logic_vector(15 downto 0);

      -- Pixel.
      spr_hit      : out std_logic;
      spr_front    : out std_logic;
      spr_idx      : out unsigned(5 downto 0)
   );
end v9990_sprites;

architecture rtl of v9990_sprites is

   -- Pixel line buffers, one per half: 512 x (on, front, color).
   type buf_t is array (0 to 511) of std_logic_vector(7 downto 0);
   signal buf0, buf1 : buf_t := (others => (others => '0'));
   signal we0, we1   : std_logic := '0';
   signal wa0, wa1   : unsigned(8 downto 0) := (others => '0');
   signal wd0, wd1   : std_logic_vector(7 downto 0) := (others => '0');
   signal r_addr     : unsigned(8 downto 0) := (others => '0');
   signal rd0, rd1   : std_logic_vector(7 downto 0) := (others => '0');

   -- Render (fetch half) and clear (shown half) writes.
   signal rn_we      : std_logic := '0';
   signal rn_addr    : unsigned(8 downto 0) := (others => '0');
   signal rn_data    : std_logic_vector(7 downto 0) := (others => '0');
   signal cl_we      : std_logic := '0';
   signal cl_addr    : unsigned(8 downto 0) := (others => '0');

   -- Sprites of the next line.
   type list_t is array (0 to 15) of std_logic_vector(18 downto 0);  -- number (7), line (4), attribute (8)
   signal list       : list_t := (others => (others => '0'));
   signal cnt        : unsigned(4 downto 0) := (others => '0');
   signal imax       : unsigned(4 downto 0) := (others => '0');

   type fstate_t is (F_IDLE, F_SETUP, F_SCANY, F_SCANA, F_NEXT, F_NO, F_X, F_PAT, F_DRAW);
   signal fs         : fstate_t := F_IDLE;
   signal freq       : std_logic := '0';
   signal faddr      : unsigned(17 downto 0) := (others => '0');
   signal half_w     : std_logic := '0';
   signal p2         : std_logic := '0';
   signal dy         : unsigned(7 downto 0) := (others => '0');
   signal sp         : unsigned(6 downto 0) := (others => '0');
   signal ytmp       : unsigned(3 downto 0) := (others => '0');
   signal k          : unsigned(4 downto 0) := (others => '0');   -- list entry being drawn
   signal sno        : unsigned(7 downto 0) := (others => '0');
   signal sx         : signed(10 downto 0) := (others => '0');
   signal pat        : std_logic_vector(63 downto 0) := (others => '0');
   signal pk         : unsigned(2 downto 0) := (others => '0');
   signal dx         : unsigned(3 downto 0) := (others => '0');
   signal width      : unsigned(9 downto 0) := (others => '0');

   -- Display.
   signal show_n, show_c : std_logic := '0';
   signal npx_c      : unsigned(9 downto 0) := (others => '0');
   signal pclk_n, pclk_c : unsigned(3 downto 0) := "1000";
   signal half_r     : std_logic := '0';
   signal active     : std_logic := '0';
   signal pc         : unsigned(3 downto 0) := (others => '0');
   signal ipx        : unsigned(9 downto 0) := (others => '0');
   signal a_valid, b_valid : std_logic := '0';
   signal b_i        : unsigned(8 downto 0) := (others => '0');
   signal a_i        : unsigned(8 downto 0) := (others => '0');
   signal o_hit, o_front : std_logic := '0';
   signal o_idx      : unsigned(5 downto 0) := (others => '0');

   constant TABLE : unsigned(17 downto 0) := to_unsigned(16#3FE00#, 18);

begin

   -- Buffers: the half being written takes the render writes, the shown
   -- half the clears.
   we0 <= rn_we when half_w = '0' else cl_we;
   wa0 <= rn_addr when half_w = '0' else cl_addr;
   wd0 <= rn_data when half_w = '0' else (others => '0');
   we1 <= rn_we when half_w = '1' else cl_we;
   wa1 <= rn_addr when half_w = '1' else cl_addr;
   wd1 <= rn_data when half_w = '1' else (others => '0');

   process (clk) begin if rising_edge(clk) then
      if we0 = '1' then
         buf0(to_integer(wa0)) <= wd0;
      end if;
      rd0 <= buf0(to_integer(r_addr));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if we1 = '1' then
         buf1(to_integer(wa1)) <= wd1;
      end if;
      rd1 <= buf1(to_integer(r_addr));
   end if; end process;

   ---------------------------------------------------------------------------
   -- Sprites of the next line.
   ---------------------------------------------------------------------------
   process (clk)
      variable n    : unsigned(8 downto 0);
      variable y1   : unsigned(7 downto 0);
      variable line : unsigned(7 downto 0);
      variable e    : std_logic_vector(18 downto 0);
      variable pa   : unsigned(18 downto 0);
      variable xx   : signed(10 downto 0);
      variable nib  : std_logic_vector(3 downto 0);
      variable attr : std_logic_vector(7 downto 0);
      variable byte : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk) then
         rn_we <= '0';

         case fs is

         when F_IDLE =>
            if hcnt = 0 then
               fs <= F_SETUP;
            end if;

         when F_SETUP =>
            n := vcnt + 1;
            show_n <= '0';
            half_w <= n(0);
            fs     <= F_IDLE;
            if last_line = '0' and disp_en = '1' and n >= top and n < bottom
                  and (mode = DM_P1 or mode = DM_P2) and regs(R_CONTROL)(6) = '0' then
               show_n <= '1';
               dy     <= resize(n - top, 8);
               if mode = DM_P2 then
                  p2 <= '1';
                  width  <= to_unsigned(512, 10);
                  pclk_n <= to_unsigned(4, 4);
               else
                  p2 <= '0';
                  width  <= to_unsigned(256, 10);
                  pclk_n <= to_unsigned(8, 4);
               end if;
               sp    <= (others => '0');
               cnt   <= (others => '0');
               imax  <= to_unsigned(16, 5);
               faddr <= TABLE;
               freq  <= '1';
               fs    <= F_SCANY;
            end if;

         when F_SCANY =>
            -- Y of sprite sp: on the line if (dy - (Y + 1)) mod 256 < 16.
            if vram_ack_i = '1' then
               y1   := unsigned(vram_rdata_i(7 downto 0)) + 1;
               line := dy - y1;
               freq <= '0';
               if line < 16 then
                  ytmp  <= line(3 downto 0);
                  faddr <= TABLE + resize(sp & "11", 18);
                  freq  <= '1';
                  fs    <= F_SCANA;
               else
                  fs <= F_NEXT;
               end if;
            end if;

         when F_SCANA =>
            if vram_ack_i = '1' then
               freq <= '0';
               attr := vram_rdata_i(7 downto 0);
               if attr(4) = '1' then
                  imax <= imax - 1;
                  if cnt = imax - 1 then
                     fs <= F_NO;         -- full
                  else
                     fs <= F_NEXT;
                  end if;
               else
                  list(to_integer(cnt(3 downto 0))) <= std_logic_vector(sp) & std_logic_vector(ytmp) & attr;
                  cnt <= cnt + 1;
                  if cnt + 1 = imax then
                     fs <= F_NO;
                  else
                     fs <= F_NEXT;
                  end if;
               end if;
               k <= cnt;                  -- (fixed below when the scan ends)
            end if;

         when F_NEXT =>
            if sp = 124 then
               fs <= F_NO;
            else
               sp    <= sp + 1;
               faddr <= TABLE + resize((sp + 1) & "00", 18);
               freq  <= '1';
               fs    <= F_SCANY;
            end if;

         when F_NO =>
            -- Draw the list from the last entry: its number, then X.
            if freq = '0' then
               if cnt = 0 then
                  fs <= F_IDLE;
               else
                  k     <= cnt - 1;
                  e     := list(to_integer(cnt(3 downto 0) - 1));
                  faddr <= TABLE + resize(unsigned(e(18 downto 12)) & "01", 18);
                  freq  <= '1';
               end if;
            elsif vram_ack_i = '1' then
               sno   <= unsigned(vram_rdata_i(7 downto 0));
               faddr <= faddr + 1;
               fs    <= F_X;
            end if;

         when F_X =>
            if vram_ack_i = '1' then
               e    := list(to_integer(k(3 downto 0)));
               attr := e(7 downto 0);
               xx   := signed(std_logic_vector'("0" & attr(1 downto 0) & vram_rdata_i(7 downto 0)));
               if xx > 1008 then
                  xx := xx - 1024;
               end if;
               sx <= xx;
               -- Pattern line: P1 base + 128 * ((no & F0h) + line) + 8 * (no & 0Fh),
               -- P2 base + 256 * (((no & E0h) >> 1) + line) + 8 * (no & 1Fh).
               line := resize(unsigned(e(11 downto 8)), 8);
               if p2 = '1' then
                  pa := shift_left(resize(unsigned(regs(R_SPRTBL)(3 downto 0)), 19), 15)
                        + shift_left(resize(sno(7 downto 5) & "0000", 19) + resize(line, 19), 8)
                        + shift_left(resize(sno(4 downto 0), 19), 3);
                  faddr <= pa(18 downto 1);           -- bitmap layout: 4 words
               else
                  pa := shift_left(resize(unsigned(regs(R_SPRTBL)(3 downto 1)), 19), 15)
                        + shift_left(resize(sno(7 downto 4) & "0000", 19) + resize(line, 19), 7)
                        + shift_left(resize(sno(3 downto 0), 19), 3);
                  faddr <= pa(17 downto 0);           -- physical, bank 0: 8 words
               end if;
               pk <= (others => '0');
               fs <= F_PAT;
            end if;

         when F_PAT =>
            if vram_ack_i = '1' then
               faddr <= faddr + 1;
               if p2 = '1' then
                  pat <= pat(47 downto 0) & vram_rdata_i(7 downto 0) & vram_rdata_i(15 downto 8);
                  if pk = 3 then
                     freq <= '0';
                     dx   <= (others => '0');
                     fs   <= F_DRAW;
                  end if;
               else
                  pat <= pat(55 downto 0) & vram_rdata_i(7 downto 0);
                  if pk = 7 then
                     freq <= '0';
                     dx   <= (others => '0');
                     fs   <= F_DRAW;
                  end if;
               end if;
               pk <= pk + 1;
            end if;

         when F_DRAW =>
            -- 16 pixels, one per clock, the transparent ones skipped.
            e    := list(to_integer(k(3 downto 0)));
            attr := e(7 downto 0);
            nib  := pat(63 - 4 * to_integer(dx) downto 60 - 4 * to_integer(dx));
            xx   := sx + signed(resize(dx, 11));
            if nib /= "0000" and xx >= 0 and xx < signed(resize(width, 11)) then
               rn_we   <= '1';
               rn_addr <= unsigned(xx(8 downto 0));
               rn_data <= std_logic_vector'('1' & not attr(5)) & std_logic_vector(unsigned(std_logic_vector'(attr(7 downto 6) & "0000")) + unsigned(nib));
            end if;
            if dx = 15 then
               if k = 0 then
                  fs <= F_IDLE;
               else
                  k     <= k - 1;
                  e     := list(to_integer(k(3 downto 0) - 1));
                  faddr <= TABLE + resize(unsigned(e(18 downto 12)) & "01", 18);
                  freq  <= '1';
                  fs    <= F_NO;
               end if;
            end if;
            dx <= dx + 1;
         end case;

         if reset_n = '0' then
            fs   <= F_IDLE;
            freq <= '0';
         end if;
      end if;
   end process;

   vram_req_o  <= freq;
   vram_addr_o <= faddr;

   ---------------------------------------------------------------------------
   -- Display of the current line.
   ---------------------------------------------------------------------------

   -- Stage A: a new pixel every pclk clocks; buffer address.  Clears: the
   -- pixels past the line (P1) while the line starts, every pixel once
   -- read, the whole buffer when the line is not shown.
   process (clk) begin if rising_edge(clk) then
      a_valid <= '0';
      cl_we   <= '0';
      if hcnt = 0 then
         show_c <= show_n;
         pclk_c <= pclk_n;
         npx_c  <= width;
         half_r <= vcnt(0);
         active <= '0';
      else
         if show_c = '0' and hcnt <= 512 then
            cl_we   <= '1';
            cl_addr <= resize(hcnt - 1, 9);
         elsif show_c = '1' and npx_c = 256 and hcnt <= 256 then
            cl_we   <= '1';
            cl_addr <= '1' & resize(hcnt - 1, 8);
         elsif b_valid = '1' then
            cl_we   <= '1';
            cl_addr <= b_i;
         end if;
         if hcnt = left - 3 and show_c = '1' then
            active  <= '1';
            pc      <= pclk_c - 1;
            ipx     <= (others => '0');
            r_addr  <= (others => '0');
            a_valid <= '1';
            a_i     <= (others => '0');
         elsif active = '1' then
            if pc /= 0 then
               pc <= pc - 1;
            elsif ipx = npx_c - 1 then
               active <= '0';
            else
               pc      <= pclk_c - 1;
               ipx     <= ipx + 1;
               r_addr  <= ipx(8 downto 0) + 1;
               a_valid <= '1';
               a_i     <= ipx(8 downto 0) + 1;
            end if;
         end if;
      end if;
   end if; end process;

   -- Stage B: buffer data; stage C: the sprite pixel.
   process (clk)
      variable d : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk) then
         b_valid <= a_valid;
         b_i     <= a_i;
         if b_valid = '1' then
            if half_r = '0' then
               d := rd0;
            else
               d := rd1;
            end if;
            o_hit   <= d(7);
            o_front <= d(6);
            o_idx   <= unsigned(d(5 downto 0));
         end if;
      end if;
   end process;

   spr_hit   <= o_hit and show_c;
   spr_front <= o_front;
   spr_idx   <= o_idx;

end rtl;
