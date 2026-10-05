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


-- V9990 bitmap modes (B0-B4, B7): 2, 4, 8 bpp (64 color palette, 256
-- direct colors, YJK, YUV) and 16 bpp, image width 256-2048, scroll with
-- roll, even / odd pages and the two hardware cursors.  Like openMSX
-- V9990BitmapConverter / V9990SDLRasterizer::drawBxMode (see
-- sim/v9990_model.Bitmap).
--
-- During each line the next one is fetched from VRAM (cursors first, then
-- the pixels) into one half of a line buffer, 32 bits wide as two banks of
-- 16-bit words; the other half is shown.  Registers are taken when the
-- line is fetched: openMSX applies changes in the middle of a line, here
-- they apply from the next line.
--
-- Output, for the clock at raster position hcnt: a palette index
-- (pix_direct = '0') or a direct color (R G B, 5 bits each), and the
-- cursor on it (cur_hit; cur_xor: invert the color, else cur_color).
-- Pipeline: A (pixel step, buffer address), B (buffer data), C (color);
-- pixel 0 starts in A at hcnt = left - 3.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_bitmap is
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
      pal_t        : in  std_logic;
      last_line    : in  std_logic;
      frame        : in  std_logic;
      interlace    : in  std_logic;
      eo           : in  std_logic;
      scay_wr      : in  std_logic;

      -- Cursor colors: palette read port (data the second clock after).
      pal2_idx_o   : out unsigned(5 downto 0);
      pal2_i       : in  std_logic_vector(15 downto 0);

      -- VRAM, reads (see v9990_vram_bram).
      vram_req_o   : out std_logic;
      vram_addr_o  : out unsigned(17 downto 0);
      vram_ack_i   : in  std_logic;
      vram_rdata_i : in  std_logic_vector(15 downto 0);

      -- Pixel.
      pix_direct   : out std_logic;
      pix_idx      : out unsigned(5 downto 0);
      pix_rgb      : out std_logic_vector(14 downto 0);
      cur_hit      : out std_logic;
      cur_xor      : out std_logic;
      cur_color    : out std_logic_vector(14 downto 0)
   );
end v9990_bitmap;

architecture rtl of v9990_bitmap is

   type cmode_t is (C_BP2, C_BP4, C_BP6, C_BD8, C_YJK, C_YUV, C_BD16);

   -- Line buffer: 2 halves x 1024 dwords, as even / odd 16-bit words.
   type buf_t is array (0 to 2047) of std_logic_vector(15 downto 0);
   signal buf_e, buf_o : buf_t;
   signal buf_we       : std_logic := '0';
   signal buf_odd      : std_logic := '0';
   signal buf_waddr    : unsigned(10 downto 0) := (others => '0');
   signal buf_wdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal buf_raddr    : unsigned(10 downto 0) := (others => '0');
   signal rd_e, rd_o   : std_logic_vector(15 downto 0) := (others => '0');

   type cursor_t is record
      vis    : std_logic;
      x      : unsigned(9 downto 0);
      pat    : std_logic_vector(31 downto 0);
      xorm   : std_logic;
      color  : std_logic_vector(14 downto 0);
   end record;
   constant NO_CURSOR : cursor_t := ('0', (others => '0'), (others => '0'), '0', (others => '0'));
   type cursors_t is array (0 to 1) of cursor_t;

   -- Line parameters: fetched for the next line (nl), shown (cl).
   type line_t is record
      show   : std_logic;
      cmode  : cmode_t;
      bpp    : unsigned(1 downto 0);       -- 0: 2, 1: 4, 2: 8, 3: 16 bits
      hires  : std_logic;
      paloff : unsigned(3 downto 0);
      bitoff : unsigned(4 downto 0);
      xodd   : std_logic;                  -- scroll x odd
      npx    : unsigned(10 downto 0);
      pclk   : unsigned(3 downto 0);
      cur    : cursors_t;
   end record;
   constant NO_LINE : line_t := ('0', C_BP4, "00", '0', "0000", "00000", '0',
                                 (others => '0'), "1000", (NO_CURSOR, NO_CURSOR));
   signal nl, cl : line_t := NO_LINE;

   -- Fetch.
   type fstate_t is (F_IDLE, F_SETUP, F_SETUP2, F_SETUP3, F_ATTR, F_CHECK, F_PAT, F_COLA, F_COLB, F_COLC, F_NEXT, F_PIX);
   signal fs        : fstate_t := F_IDLE;
   signal freq      : std_logic := '0';
   signal faddr     : unsigned(17 downto 0) := (others => '0');
   signal fcnt      : unsigned(10 downto 0) := (others => '0');   -- words left
   signal fword     : unsigned(10 downto 0) := (others => '0');   -- word in the line
   signal pix_addr  : unsigned(17 downto 0) := (others => '0');
   signal fcur      : natural range 0 to 1 := 0;
   signal fk        : natural range 0 to 3 := 0;
   signal attr      : byte_array(0 to 3) := (others => (others => '0'));
   signal pat_hi    : std_logic_vector(15 downto 0) := (others => '0');
   signal dy_n      : unsigned(9 downto 0) := (others => '0');    -- display y of the next line
   signal half_w    : std_logic := '0';
   signal offa      : unsigned(8 downto 0) := (others => '0');    -- line of layer A line 0
   signal scay_hi   : unsigned(4 downto 0) := (others => '0');    -- R#18 of this frame
   signal pal2_idx  : unsigned(5 downto 0) := (others => '0');
   -- Setup pipeline.
   signal s_y       : unsigned(12 downto 0) := (others => '0');
   signal s_sx      : unsigned(10 downto 0) := (others => '0');
   signal s_b       : natural range 0 to 3 := 0;
   signal s_ximm    : natural range 0 to 3 := 0;
   signal s_npxb    : unsigned(15 downto 0) := (others => '0');   -- bits of the pixels of a line
   signal s_p       : unsigned(23 downto 0) := (others => '0');

   -- Display.
   signal active    : std_logic := '0';
   signal half_r    : std_logic := '0';
   signal pc        : unsigned(3 downto 0) := (others => '0');
   signal pos       : unsigned(14 downto 0) := (others => '0');   -- bit in the line buffer
   signal ipx       : unsigned(10 downto 0) := (others => '0');
   signal a_valid, b_valid : std_logic := '0';
   signal a_bit, b_bit     : unsigned(4 downto 0) := (others => '0');
   signal a_i, b_i         : unsigned(10 downto 0) := (others => '0');

   signal o_direct  : std_logic := '0';
   signal o_idx     : unsigned(5 downto 0) := (others => '0');
   signal o_rgb     : std_logic_vector(14 downto 0) := (others => '0');
   signal o_hit     : std_logic := '0';
   signal o_xor     : std_logic := '0';
   signal o_color   : std_logic_vector(14 downto 0) := (others => '0');

   function clamp5(v : integer) return unsigned is
   begin
      if v < 0 then
         return to_unsigned(0, 5);
      elsif v > 31 then
         return to_unsigned(31, 5);
      else
         return to_unsigned(v, 5);
      end if;
   end function;

   -- BD8 levels (openMSX palette256: GGGRRRBB).
   function map_rg(c : unsigned(2 downto 0)) return unsigned is
      type t is array (0 to 7) of natural;
      constant M : t := (0, 4, 9, 13, 18, 22, 27, 31);
   begin
      return to_unsigned(M(to_integer(c)), 5);
   end function;

   function map_b(c : unsigned(1 downto 0)) return unsigned is
      type t is array (0 to 3) of natural;
      constant M : t := (0, 11, 21, 31);
   begin
      return to_unsigned(M(to_integer(c)), 5);
   end function;

begin

   -- Line buffer.
   process (clk) begin if rising_edge(clk) then
      if buf_we = '1' and buf_odd = '0' then
         buf_e(to_integer(buf_waddr)) <= buf_wdata;
      end if;
      rd_e <= buf_e(to_integer(buf_raddr));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if buf_we = '1' and buf_odd = '1' then
         buf_o(to_integer(buf_waddr)) <= buf_wdata;
      end if;
      rd_o <= buf_o(to_integer(buf_raddr));
   end if; end process;

   ---------------------------------------------------------------------------
   -- Fetch of the next line.
   ---------------------------------------------------------------------------
   process (clk)
      variable n      : unsigned(8 downto 0);
      variable ya     : unsigned(9 downto 0);
      variable dy     : unsigned(9 downto 0);
      variable sy     : unsigned(12 downto 0);
      variable roll   : unsigned(12 downto 0);
      variable y      : unsigned(12 downto 0);
      variable sx     : unsigned(10 downto 0);
      variable b      : natural range 0 to 3;
      variable p      : unsigned(23 downto 0);
      variable dw     : unsigned(16 downto 0);
      variable bits   : unsigned(15 downto 0);
      variable ndw    : unsigned(15 downto 0);
      variable cy     : unsigned(9 downto 0);
      variable ay     : unsigned(9 downto 0);
      variable cline  : unsigned(8 downto 0);
      variable m      : cmode_t;
      variable base   : unsigned(18 downto 0);
      variable col    : std_logic_vector(14 downto 0);
   begin
      if rising_edge(clk) then
         buf_we <= '0';

         if frame = '1' then
            offa    <= top;
            scay_hi <= unsigned(regs(R_SCAY0 + 1)(4 downto 0));
         elsif scay_wr = '1' and disp_en = '1' and vcnt >= top and vcnt < bottom then
            offa <= vcnt;
         end if;

         case fs is

         when F_IDLE =>
            if hcnt = 0 then
               fs <= F_SETUP;
            end if;

         when F_SETUP =>
            n := vcnt + 1;
            nl.show <= '0';
            nl.cur  <= (NO_CURSOR, NO_CURSOR);
            half_w  <= n(0);
            fs      <= F_IDLE;
            if last_line = '0' and disp_en = '1' and n >= top and n < bottom and is_bitmap(mode) then
               nl.show <= '1';
               -- Display line (cursors) and layer A line, even / odd pages.
               dy := resize(n - top, 10);
               ya := resize(n - offa, 10);
               if regs(R_SCRMODE1)(2) = '1' then
                  ya := ya(8 downto 0) & eo;
                  dy := dy + ("000000000" & eo);
               end if;
               dy_n <= dy;
               sy   := unsigned(std_logic_vector'(std_logic_vector(scay_hi) & regs(R_SCAY0)));
               case regs(R_SCAY0 + 1)(7 downto 6) is
                  when "01" | "11" => roll := to_unsigned(16#00FF#, 13);
                  when "10"        => roll := to_unsigned(16#01FF#, 13);
                  when others      => roll := (others => '1');
               end case;
               y  := (sy and not roll) + ((resize(ya, 13) + sy) and roll);
               sx := unsigned(std_logic_vector'(regs(R_SCAY0 + 3) & regs(R_SCAY0 + 2)(2 downto 0)));
               -- Color mode.
               b := to_integer(unsigned(regs(R_SCRMODE0)(1 downto 0)));
               case b is
                  when 0 => m := C_BP2;
                  when 1 => m := C_BP4;
                  when 3 => m := C_BD16;
                  when others =>
                     case regs(R_PALCTRL)(7 downto 6) is
                        when "00"   => m := C_BP6;
                        when "01"   => m := C_BD8;
                        when "10"   => m := C_YJK;
                        when others => m := C_YUV;
                     end case;
               end case;
               nl.cmode  <= m;
               nl.bpp    <= to_unsigned(b, 2);
               nl.paloff <= unsigned(regs(R_PALCTRL)(3 downto 0));
               if mode = DM_B4 or mode = DM_B7 then
                  nl.hires <= '1';
               else
                  nl.hires <= '0';
               end if;
               nl.npx  <= to_unsigned(pixels(mode), 11);
               nl.pclk <= to_unsigned(pixel_clocks(mode), 4);
               nl.xodd <= sx(0);
               s_y    <= y;
               s_sx   <= sx;
               s_b    <= b;
               s_ximm <= to_integer(unsigned(regs(R_SCRMODE0)(3 downto 2)));
               s_npxb <= shift_left(to_unsigned(pixels(mode), 16), b + 1);
               fs     <= F_SETUP2;
            end if;

         when F_SETUP2 =>
            -- Pixel number of the first pixel: x + y * width.
            s_p <= resize(s_sx, 24) + shift_left(resize(s_y, 24), 8 + s_ximm);
            fs  <= F_SETUP3;

         when F_SETUP3 =>
            -- First dword and bit of the line, dwords to fetch.
            dw   := resize(shift_right(s_p, 4 - s_b), 17);
            bits := shift_left(resize(s_p(15 downto 0), 16), s_b + 1);
            nl.bitoff <= bits(4 downto 0);
            ndw  := shift_right(resize(bits(4 downto 0), 16) + s_npxb + 31, 5);
            pix_addr <= dw & '0';
            fcnt  <= ndw(9 downto 0) & '0';
            fword <= (others => '0');
            fcur  <= 0;
            fk    <= 0;
            freq  <= '1';
            if regs(R_CONTROL)(6) = '0' then
               faddr <= to_unsigned(16#3FF00#, 18);        -- cursor 0 attributes, 7FE00h
               fs    <= F_ATTR;
            else
               faddr <= dw & '0';
               fs    <= F_PIX;
            end if;

         when F_ATTR =>
            -- Attribute bytes 0, 2, 4, 6: even bytes, bank 0 of 4 words.
            if vram_ack_i = '1' then
               attr(fk) <= vram_rdata_i(7 downto 0);
               faddr    <= faddr + 1;
               if fk = 3 then
                  freq <= '0';
                  fs   <= F_CHECK;
               else
                  fk <= fk + 1;
               end if;
            end if;

         when F_CHECK =>
            -- On this line?  (openMSX: 1 or 2 lines below the Y in the
            -- attributes, Y in display lines, without the overscan border.)
            ay := resize(unsigned(attr(1)(0 downto 0)) & unsigned(attr(0)), 10);
            if interlace = '1' then
               ay := ay + 2;
            else
               ay := ay + 1;
            end if;
            cy := dy_n;
            if is_overscan(mode) then
               if pal_t = '1' then
                  cy := cy - V_BORDER_PAL;
               else
                  cy := cy - V_BORDER_NTSC;
               end if;
            end if;
            cline := resize(cy - ay, 9);
            if cline < 32 and attr(3)(4) = '0' and attr(3)(7 downto 5) /= "000" then
               nl.cur(fcur).vis <= '1';
               nl.cur(fcur).x   <= unsigned(attr(3)(1 downto 0)) & unsigned(attr(2));
               if attr(3)(7 downto 5) = "001" then
                  nl.cur(fcur).xorm <= '1';
               else
                  nl.cur(fcur).xorm <= '0';
               end if;
               -- Pattern: 7FF00h / 7FF80h + 4 * line (two words).
               if fcur = 0 then
                  base := to_unsigned(16#7FF00#, 19);
               else
                  base := to_unsigned(16#7FF80#, 19);
               end if;
               base  := base + shift_left(resize(cline(4 downto 0), 19), 2);
               faddr <= base(18 downto 1);
               fk    <= 0;
               freq  <= '1';
               fs    <= F_PAT;
            else
               nl.cur(fcur).vis <= '0';
               fs <= F_NEXT;
            end if;

         when F_PAT =>
            -- Bytes in VRAM order: byte 0 is the leftmost 8 pixels.
            if vram_ack_i = '1' then
               faddr <= faddr + 1;
               if fk = 0 then
                  pat_hi <= vram_rdata_i(7 downto 0) & vram_rdata_i(15 downto 8);
                  fk     <= 1;
               else
                  nl.cur(fcur).pat <= pat_hi & vram_rdata_i(7 downto 0) & vram_rdata_i(15 downto 8);
                  freq <= '0';
                  fs   <= F_COLA;
               end if;
            end if;

         when F_COLA =>
            pal2_idx <= resize(shift_left(unsigned(regs(R_SPRPAL)(5 downto 0)), 2), 6) + unsigned(attr(3)(7 downto 6));
            fs <= F_COLB;

         when F_COLB =>
            fs <= F_COLC;

         when F_COLC =>
            col := pal2_i(14 downto 0);
            if attr(3)(5) = '1' then
               col := not col;
            end if;
            nl.cur(fcur).color <= col;
            fs <= F_NEXT;

         when F_NEXT =>
            if fcur = 0 then
               fcur  <= 1;
               fk    <= 0;
               faddr <= to_unsigned(16#3FF04#, 18);        -- cursor 1 attributes, 7FE08h
               freq  <= '1';
               fs    <= F_ATTR;
            else
               faddr <= pix_addr;
               freq  <= '1';
               fs    <= F_PIX;
            end if;

         when F_PIX =>
            if vram_ack_i = '1' then
               buf_we    <= '1';
               buf_odd   <= fword(0);
               buf_waddr <= half_w & fword(10 downto 1);
               buf_wdata <= vram_rdata_i;
               fword     <= fword + 1;
               fcnt      <= fcnt - 1;
               faddr     <= faddr + 1;
               if fcnt = 1 then
                  freq <= '0';
                  fs   <= F_IDLE;
               end if;
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
   pal2_idx_o  <= pal2_idx;

   ---------------------------------------------------------------------------
   -- Display of the current line.
   ---------------------------------------------------------------------------

   -- Stage A: a new pixel every pclk clocks; buffer address.
   process (clk)
      variable np : unsigned(14 downto 0);
   begin
      if rising_edge(clk) then
         a_valid <= '0';
         if hcnt = 0 then
            cl     <= nl;
            half_r <= vcnt(0);
            active <= '0';
         elsif hcnt = left - 3 and cl.show = '1' then
            active    <= '1';
            pc        <= cl.pclk - 1;
            pos       <= resize(cl.bitoff, 15);
            ipx       <= (others => '0');
            buf_raddr <= half_r & "0000000000";
            a_valid   <= '1';
            a_bit     <= cl.bitoff;
            a_i       <= (others => '0');
         elsif active = '1' then
            if pc /= 0 then
               pc <= pc - 1;
            elsif ipx = cl.npx - 1 then
               active <= '0';
            else
               case cl.bpp is
                  when "00"   => np := pos + 2;
                  when "01"   => np := pos + 4;
                  when "10"   => np := pos + 8;
                  when others => np := pos + 16;
               end case;
               pos       <= np;
               pc        <= cl.pclk - 1;
               ipx       <= ipx + 1;
               buf_raddr <= half_r & np(14 downto 5);
               a_valid   <= '1';
               a_bit     <= np(4 downto 0);
               a_i       <= ipx + 1;
            end if;
         end if;
      end if;
   end process;

   -- Stage B: the buffer read (rd_e / rd_o) and the pixel info.
   process (clk) begin if rising_edge(clk) then
      b_valid <= a_valid;
      b_bit   <= a_bit;
      b_i     <= a_i;
   end if; end process;

   -- Stage C: color and cursors.
   process (clk)
      variable bytes : byte_array(0 to 3);
      variable k     : natural range 0 to 3;
      variable bt    : unsigned(7 downto 0);
      variable v     : unsigned(5 downto 0);
      variable w16   : std_logic_vector(15 downto 0);
      variable yy, u, vv, t, kk : integer;
      variable xo    : std_logic;
      variable base  : unsigned(5 downto 0);
      variable hit   : boolean;
   begin
      if rising_edge(clk) then
         if b_valid = '1' then
            bytes := (rd_e(7 downto 0), rd_e(15 downto 8), rd_o(7 downto 0), rd_o(15 downto 8));
            k  := to_integer(b_bit(4 downto 3));
            bt := unsigned(bytes(k));
            xo := cl.xodd xor b_i(0);
            o_direct <= '0';
            case cl.cmode is
               when C_BP2 =>
                  v := resize(shift_right(bt, 6 - to_integer(b_bit(2 downto 0))) and "00000011", 6);
                  if cl.hires = '1' then
                     base := "0" & cl.paloff(2 downto 0) & "00";
                  else
                     base := cl.paloff & "00";
                  end if;
                  if cl.hires = '1' and xo = '1' then
                     o_idx <= base + v + 32;
                  else
                     o_idx <= base + v;
                  end if;
               when C_BP4 =>
                  if b_bit(2) = '0' then
                     v := resize(bt(7 downto 4), 6);
                  else
                     v := resize(bt(3 downto 0), 6);
                  end if;
                  if cl.hires = '1' then
                     base := "0" & cl.paloff(2) & "0000";
                  else
                     base := cl.paloff(3 downto 2) & "0000";
                  end if;
                  if cl.hires = '1' and xo = '1' then
                     o_idx <= base + v + 32;
                  else
                     o_idx <= base + v;
                  end if;
               when C_BP6 =>
                  o_idx <= bt(5 downto 0);
               when C_BD8 =>
                  o_direct <= '1';
                  o_rgb <= std_logic_vector(map_rg(bt(4 downto 2)) & map_rg(bt(7 downto 5)) & map_b(bt(1 downto 0)));
               when C_BD16 =>
                  o_direct <= '1';
                  w16 := bytes(k + 1) & bytes(k);
                  -- G (14-10) R (9-5) B (4-0) to R G B.
                  o_rgb <= w16(9 downto 5) & w16(14 downto 10) & w16(4 downto 0);
               when C_YJK | C_YUV =>
                  o_direct <= '1';
                  yy := to_integer(bt(7 downto 3));
                  u  := to_integer(unsigned(bytes(2)(2 downto 0))) + 8 * to_integer(unsigned(bytes(3)(1 downto 0)))
                        - 32 * to_integer(unsigned(bytes(3)(2 downto 2)));
                  vv := to_integer(unsigned(bytes(0)(2 downto 0))) + 8 * to_integer(unsigned(bytes(1)(1 downto 0)))
                        - 32 * to_integer(unsigned(bytes(1)(2 downto 2)));
                  t  := 5 * yy - 2 * u - vv;
                  if t < 0 then
                     t := -1;                  -- clamped to 0
                  else
                     t := t / 4;
                  end if;
                  if cl.cmode = C_YJK then
                     o_rgb <= std_logic_vector(clamp5(yy + u) & clamp5(yy + vv) & clamp5(t));
                  else
                     o_rgb <= std_logic_vector(clamp5(yy + u) & clamp5(t) & clamp5(yy + vv));
                  end if;
            end case;

            -- Cursors, cursor 0 in front.
            hit := false;
            o_hit <= '0';
            for c in 0 to 1 loop
               kk := to_integer(b_i) - to_integer(cl.cur(c).x);
               if not hit and cl.cur(c).vis = '1' and kk >= 0 and kk < 32 then
                  if cl.cur(c).pat(31 - kk) = '1' then
                     hit := true;
                     o_hit   <= '1';
                     o_xor   <= cl.cur(c).xorm;
                     o_color <= cl.cur(c).color;
                  end if;
               end if;
            end loop;
         end if;
      end if;
   end process;

   pix_direct <= o_direct;
   pix_idx    <= o_idx;
   pix_rgb    <= o_rgb;
   cur_hit    <= o_hit;
   cur_xor    <= o_xor;
   cur_color  <= o_color;

end rtl;
