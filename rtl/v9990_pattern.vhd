--
-- V9990 (E-VDP-III) for the F18A project.
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


-- V9990 pattern modes P1 (layers A and B, 256 pixels, 4 bpp 8x8
-- patterns) and P2 (one layer, 512 pixels), without the sprites.  Like
-- openMSX V9990P1Converter / V9990P2Converter (see
-- sim/v9990_model.Pattern).
--
--   P1  names A 7C000h, B 7E000h, patterns A 00000h, B 40000h (physical:
--       layer A in bank 0, B in bank 1), image 512 x 512, scroll per layer;
--       R#27 puts B in front of A right of PRX / below PRY.
--   P2  names 7C000h (physical), patterns from 0 (bitmap layout), image
--       1024 x 512; even pattern bytes use palette A, odd ones palette B.
--
-- During each line the next one is fetched into one half of a pixel line
-- buffer (layer A: color and odd byte, layer B: color); the other half is
-- shown.  Pixel pipeline as in v9990_bitmap: pixel 0 starts at
-- hcnt = left - 3.  Output: palette index and whether a front layer
-- pixel is there (fg, for the sprite priority).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_pattern is
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
      frame        : in  std_logic;
      scay_wr      : in  std_logic;
      scby_wr      : in  std_logic;

      -- VRAM, reads.
      vram_req_o   : out std_logic;
      vram_addr_o  : out unsigned(17 downto 0);
      vram_ack_i   : in  std_logic;
      vram_rdata_i : in  std_logic_vector(15 downto 0);

      -- Pixel.
      pix_idx      : out unsigned(5 downto 0);
      pix_fg       : out std_logic
   );
end v9990_pattern;

architecture rtl of v9990_pattern is

   -- Pixel line buffers, 2 halves x 512: A color & odd byte, B color.
   type bufa_t is array (0 to 1023) of std_logic_vector(4 downto 0);
   type bufb_t is array (0 to 1023) of std_logic_vector(3 downto 0);
   signal buf_a      : bufa_t;
   signal buf_b      : bufb_t;
   signal wa_en, wb_en : std_logic := '0';
   signal w_addr     : unsigned(9 downto 0) := (others => '0');
   signal w_data     : std_logic_vector(4 downto 0) := (others => '0');
   signal r_addr     : unsigned(9 downto 0) := (others => '0');
   signal rd_a       : std_logic_vector(4 downto 0) := (others => '0');
   signal rd_b       : std_logic_vector(3 downto 0) := (others => '0');

   type line_t is record
      show   : std_logic;
      p2     : std_logic;
      npx    : unsigned(9 downto 0);
      pclk   : unsigned(3 downto 0);
      pal_a  : unsigned(5 downto 0);
      pal_b  : unsigned(5 downto 0);
      prio_x : unsigned(8 downto 0);       -- B in front from this pixel
   end record;
   constant NO_LINE : line_t := ('0', '0', (others => '0'), "1000", (others => '0'), (others => '0'), (others => '1'));
   signal nl, cl : line_t := NO_LINE;

   -- Fetch.
   type fstate_t is (F_IDLE, F_SETUP, F_LAYER, F_NAME0, F_NAME1, F_PADDR, F_PAT, F_WRITE, F_NEXTL);
   signal fs        : fstate_t := F_IDLE;
   signal freq      : std_logic := '0';
   signal faddr     : unsigned(17 downto 0) := (others => '0');
   signal fhi       : std_logic := '0';                 -- byte in bank 1 (P1 / names)
   signal half_w    : std_logic := '0';
   signal layer     : std_logic := '0';                 -- 0 A, 1 B
   signal p2        : std_logic := '0';
   signal lx        : unsigned(9 downto 0) := (others => '0');   -- image x of the tile
   signal ly        : unsigned(8 downto 0) := (others => '0');   -- image line
   signal kfirst    : unsigned(2 downto 0) := (others => '0');
   signal wpx       : unsigned(9 downto 0) := (others => '0');   -- next pixel to write
   signal name_lo   : std_logic_vector(7 downto 0) := (others => '0');
   signal pn        : unsigned(12 downto 0) := (others => '0');
   signal pbyte     : byte_array(0 to 3) := (others => (others => '0'));
   signal pk        : natural range 0 to 3 := 0;
   signal wk        : unsigned(2 downto 0) := (others => '0');
   signal offa, offb: unsigned(8 downto 0) := (others => '0');
   signal scay_hi   : std_logic_vector(7 downto 0) := (others => '0');
   signal scby_hi   : std_logic := '0';
   signal ya_n, yb_n: unsigned(8 downto 0) := (others => '0');
   signal dy_n      : unsigned(8 downto 0) := (others => '0');
   signal prio_y    : unsigned(8 downto 0) := (others => '1');

   -- Display.
   signal active    : std_logic := '0';
   signal half_r    : std_logic := '0';
   signal pc        : unsigned(3 downto 0) := (others => '0');
   signal ipx       : unsigned(9 downto 0) := (others => '0');
   signal a_valid, b_valid : std_logic := '0';
   signal a_i, b_i  : unsigned(9 downto 0) := (others => '0');
   signal o_idx     : unsigned(5 downto 0) := (others => '0');
   signal o_fg      : std_logic := '0';

begin

   process (clk) begin if rising_edge(clk) then
      if wa_en = '1' then
         buf_a(to_integer(half_w & w_addr(8 downto 0))) <= w_data;
      end if;
      rd_a <= buf_a(to_integer(r_addr));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if wb_en = '1' then
         buf_b(to_integer(half_w & w_addr(8 downto 0))) <= w_data(3 downto 0);
      end if;
      rd_b <= buf_b(to_integer(r_addr));
   end if; end process;

   ---------------------------------------------------------------------------
   -- Fetch of the next line.
   ---------------------------------------------------------------------------
   process (clk)
      variable n     : unsigned(8 downto 0);
      variable roll  : unsigned(8 downto 0);
      variable say   : unsigned(8 downto 0);
      variable x     : unsigned(9 downto 0);
      variable na    : unsigned(18 downto 0);
      variable pa    : unsigned(18 downto 0);
      variable nib   : std_logic_vector(3 downto 0);
      variable px    : unsigned(9 downto 0);
      variable byte  : std_logic_vector(7 downto 0);
   begin
      if rising_edge(clk) then
         wa_en <= '0';
         wb_en <= '0';

         if frame = '1' then
            offa    <= top;
            offb    <= top;
            scay_hi <= regs(R_SCAY0 + 1);
            scby_hi <= regs(R_SCBY0 + 1)(0);
         else
            if scay_wr = '1' and disp_en = '1' and vcnt >= top and vcnt < bottom then
               offa <= vcnt;
            end if;
            if scby_wr = '1' and disp_en = '1' and vcnt >= top and vcnt < bottom then
               offb <= vcnt;
            end if;
         end if;

         case fs is

         when F_IDLE =>
            if hcnt = 0 then
               fs <= F_SETUP;
            end if;

         when F_SETUP =>
            n := vcnt + 1;
            nl.show <= '0';
            half_w  <= n(0);
            fs      <= F_IDLE;
            if last_line = '0' and disp_en = '1' and n >= top and n < bottom and (mode = DM_P1 or mode = DM_P2) then
               nl.show <= '1';
               if mode = DM_P2 then
                  p2 <= '1';
                  nl.p2   <= '1';
                  nl.npx  <= to_unsigned(512, 10);
                  nl.pclk <= to_unsigned(4, 4);
               else
                  p2 <= '0';
                  nl.p2   <= '0';
                  nl.npx  <= to_unsigned(256, 10);
                  nl.pclk <= to_unsigned(8, 4);
               end if;
               nl.pal_a <= unsigned(regs(R_PALCTRL)(1 downto 0)) & "0000";
               nl.pal_b <= unsigned(regs(R_PALCTRL)(3 downto 2)) & "0000";
               -- R#27: PRX / PRY, 0 = 256.
               case regs(R_PRIORITY)(3 downto 2) is
                  when "00"   => prio_y <= to_unsigned(256, 9);
                  when others => prio_y <= "0" & unsigned(regs(R_PRIORITY)(3 downto 2)) & "000000";   -- x 64
               end case;
               if regs(R_PRIORITY)(1 downto 0) = "00" then
                  nl.prio_x <= to_unsigned(256, 9);
               else
                  nl.prio_x <= "0" & unsigned(regs(R_PRIORITY)(1 downto 0)) & "000000";
               end if;
               dy_n <= n - top;
               ya_n <= n - offa;
               yb_n <= n - offb;
               layer <= '0';
               fs    <= F_LAYER;
            end if;

         when F_LAYER =>
            -- Layer start: image x and line, first tile.
            if dy_n >= prio_y then
               nl.prio_x <= (others => '0');
            end if;
            if layer = '0' then
               case regs(R_SCAY0 + 1)(7 downto 6) is
                  when "01" | "11" => roll := to_unsigned(16#0FF#, 9);
                  when others      => roll := (others => '1');
               end case;
               say := unsigned(std_logic_vector'(scay_hi(0) & regs(R_SCAY0)));
               ly  <= (say and not roll) + ((ya_n + say) and roll);
               x   := unsigned(std_logic_vector'(regs(R_SCAY0 + 3)(6 downto 0) & regs(R_SCAY0 + 2)(2 downto 0)));
               if p2 = '0' then
                  x(9) := '0';
               end if;
            else
               ly  <= yb_n + unsigned(std_logic_vector'(scby_hi & regs(R_SCBY0)));
               x   := unsigned(std_logic_vector'('0' & regs(R_SCBY0 + 3)(5 downto 0) & regs(R_SCBY0 + 2)(2 downto 0)));
               x(9) := '0';
            end if;
            lx     <= x;
            kfirst <= x(2 downto 0);
            wpx    <= (others => '0');
            fs     <= F_NAME0;
            freq   <= '0';

         when F_NAME0 | F_NAME1 =>
            -- Name entry (2 bytes, physical, bank 1): 7C000h (A, P2) or
            -- 7E000h (B) + (line / 8 * chars + x / 8) * 2.
            if freq = '0' then
               if p2 = '1' then
                  na := to_unsigned(16#7C000#, 19) + shift_left(resize(ly(8 downto 3), 19), 8) + shift_left(resize(lx(9 downto 3), 19), 1);
               elsif layer = '0' then
                  na := to_unsigned(16#7C000#, 19) + shift_left(resize(ly(8 downto 3), 19), 7) + shift_left(resize(lx(8 downto 3), 19), 1);
               else
                  na := to_unsigned(16#7E000#, 19) + shift_left(resize(ly(8 downto 3), 19), 7) + shift_left(resize(lx(8 downto 3), 19), 1);
               end if;
               if fs = F_NAME1 then
                  na := na + 1;
               end if;
               faddr <= na(17 downto 0);
               fhi   <= na(18);
               freq  <= '1';
            elsif vram_ack_i = '1' then
               freq <= '0';
               if fhi = '1' then
                  byte := vram_rdata_i(15 downto 8);
               else
                  byte := vram_rdata_i(7 downto 0);
               end if;
               if fs = F_NAME0 then
                  name_lo <= byte;
                  fs <= F_NAME1;
               else
                  pn <= unsigned(byte(4 downto 0)) & unsigned(name_lo);
                  fs <= F_PADDR;
               end if;
            end if;

         when F_PADDR =>
            -- Pattern row: base + pn / chars * pitch + (line & 7) * row + pn % chars * 4.
            if p2 = '1' then
               pa := shift_left(resize(pn(12 downto 6), 19), 11) + shift_left(resize(ly(2 downto 0), 19), 8)
                     + shift_left(resize(pn(5 downto 0), 19), 2);
               -- Bitmap layout: bytes a .. a + 3 are words a / 2, a / 2 + 1.
               faddr <= pa(18 downto 1);
            else
               pa := shift_left(resize(pn(12 downto 5), 19), 10) + shift_left(resize(ly(2 downto 0), 19), 7)
                     + shift_left(resize(pn(4 downto 0), 19), 2);
               if layer = '1' then
                  pa(18) := '1';
               end if;
               faddr <= pa(17 downto 0);
               fhi   <= pa(18);
            end if;
            pk   <= 0;
            freq <= '1';
            fs   <= F_PAT;

         when F_PAT =>
            if vram_ack_i = '1' then
               faddr <= faddr + 1;
               if p2 = '1' then
                  pbyte(pk)     <= vram_rdata_i(7 downto 0);
                  pbyte(pk + 1) <= vram_rdata_i(15 downto 8);
                  if pk = 2 then
                     freq <= '0';
                     wk   <= kfirst;
                     fs   <= F_WRITE;
                  else
                     pk <= pk + 2;
                  end if;
               else
                  if fhi = '1' then
                     pbyte(pk) <= vram_rdata_i(15 downto 8);
                  else
                     pbyte(pk) <= vram_rdata_i(7 downto 0);
                  end if;
                  if pk = 3 then
                     freq <= '0';
                     wk   <= kfirst;
                     fs   <= F_WRITE;
                  else
                     pk <= pk + 1;
                  end if;
               end if;
            end if;

         when F_WRITE =>
            -- Pixels wk .. 7 of the tile to the line buffer.
            byte := pbyte(to_integer(wk(2 downto 1)));
            if wk(0) = '0' then
               nib := byte(7 downto 4);
            else
               nib := byte(3 downto 0);
            end if;
            w_addr <= wpx;
            w_data <= wk(1) & nib;           -- odd byte of the 4: palette B (P2)
            if layer = '0' then
               wa_en <= '1';
            else
               wb_en <= '1';
            end if;
            px := wpx + 1;
            wpx <= px;
            if (p2 = '1' and px = 512) or (p2 = '0' and px = 256) then
               fs <= F_NEXTL;
            elsif wk = 7 then
               kfirst <= (others => '0');
               if p2 = '1' then
                  lx <= lx(9 downto 3) + 1 & "000";
               else
                  lx <= '0' & (lx(8 downto 3) + 1) & "000";
               end if;
               fs <= F_NAME0;
            else
               wk <= wk + 1;
            end if;

         when F_NEXTL =>
            if layer = '0' and p2 = '0' then
               layer <= '1';
               fs    <= F_LAYER;
            else
               fs <= F_IDLE;
            end if;
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

   -- Stage A: a new pixel every pclk clocks; buffer address.
   process (clk) begin if rising_edge(clk) then
      a_valid <= '0';
      if hcnt = 0 then
         cl     <= nl;
         half_r <= vcnt(0);
         active <= '0';
      elsif hcnt = left - 3 and cl.show = '1' then
         active  <= '1';
         pc      <= cl.pclk - 1;
         ipx     <= (others => '0');
         r_addr  <= half_r & "000000000";
         a_valid <= '1';
         a_i     <= (others => '0');
      elsif active = '1' then
         if pc /= 0 then
            pc <= pc - 1;
         elsif ipx = cl.npx - 1 then
            active <= '0';
         else
            pc      <= cl.pclk - 1;
            ipx     <= ipx + 1;
            r_addr  <= half_r & (ipx(8 downto 0) + 1);
            a_valid <= '1';
            a_i     <= ipx + 1;
         end if;
      end if;
   end if; end process;

   -- Stage B: buffer data.
   process (clk) begin if rising_edge(clk) then
      b_valid <= a_valid;
      b_i     <= a_i;
   end if; end process;

   -- Stage C: layers and priority.
   process (clk)
      variable ca, cb      : unsigned(3 downto 0);
      variable back, front : unsigned(3 downto 0);
      variable pback, pfront : unsigned(5 downto 0);
      variable backdrop    : unsigned(5 downto 0);
   begin
      if rising_edge(clk) then
         if b_valid = '1' then
            backdrop := unsigned(regs(R_BACKDROP)(5 downto 0));
            ca := unsigned(rd_a(3 downto 0));
            cb := unsigned(rd_b);
            if cl.p2 = '1' then
               o_fg <= '0';
               if ca = 0 then
                  o_idx <= backdrop;
               else
                  o_fg <= '1';
                  if rd_a(4) = '1' then
                     o_idx <= cl.pal_b + ca;
                  else
                     o_idx <= cl.pal_a + ca;
                  end if;
               end if;
            else
               if resize(b_i, 9) < cl.prio_x then
                  back := cb; pback := cl.pal_b; front := ca; pfront := cl.pal_a;
               else
                  back := ca; pback := cl.pal_a; front := cb; pfront := cl.pal_b;
               end if;
               if front /= 0 then
                  o_idx <= pfront + front;
                  o_fg  <= '1';
               elsif back /= 0 then
                  o_idx <= pback + back;
                  o_fg  <= '0';
               else
                  o_idx <= backdrop;
                  o_fg  <= '0';
               end if;
            end if;
         end if;
      end if;
   end process;

   pix_idx <= o_idx;
   pix_fg  <= o_fg;

end rtl;
