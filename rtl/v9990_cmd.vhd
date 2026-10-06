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


-- V9990 command engine (blitter): STOP, LMMC, LMMV, LMCM, LMMM, CMMC,
-- CMMK, CMMM, BMXL, BMLX, BMLL, LINE, SRCH, POINT, PSET, ADVN with the
-- logical operations, transparency and write mask, in the six command
-- modes (P1, P2, 2 / 4 / 8 / 16 bpp).  Functionally like openMSX
-- V9990CmdEngine (see sim/v9990_cmd.py, the reference model the RTL is
-- tested against), without its timing: one VRAM access at a time, as fast
-- as the VRAM port allows.  Like openMSX, CMMK and ADVN do nothing and
-- PSET does not move DX / DY.
--
-- Transfers through P#2: TR is set once the engine is ready for the next
-- byte (openMSX sets it at once and does the work in no time).
--
-- VRAM: physical byte p is word p(17:0), byte lane p(18); 16 bpp pixels
-- are words (both lanes).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_cmd is
   port (
      clk          : in  std_logic;
      reset_n      : in  std_logic;
      regs         : in  byte_array(0 to 63);
      mode         : in  dmode_t;

      -- From the CPU interface.
      reg_we       : in  std_logic;              -- R#32-R#52 written
      reg_num      : in  unsigned(4 downto 0);   -- (register - 32)
      reg_val      : in  std_logic_vector(7 downto 0);
      clear        : in  std_logic;              -- SRS: registers 0, stop
      data_wr      : in  std_logic;              -- P#2 written
      data_in      : in  std_logic_vector(7 downto 0);
      data_rd      : in  std_logic;              -- P#2 read

      data_out     : out std_logic_vector(7 downto 0);   -- P#2 value
      status_o     : out std_logic_vector(7 downto 0);   -- TR (7), BD (4), CE (0)
      border_x_o   : out std_logic_vector(15 downto 0);
      irq_o        : out std_logic;              -- command end

      -- VRAM.
      vram_req_o   : out std_logic;
      vram_we_o    : out std_logic;
      vram_be_o    : out std_logic_vector(1 downto 0);
      vram_addr_o  : out unsigned(17 downto 0);
      vram_wdata_o : out std_logic_vector(15 downto 0);
      vram_ack_i   : in  std_logic;
      vram_rdata_i : in  std_logic_vector(15 downto 0)
   );
end v9990_cmd;

architecture rtl of v9990_cmd is

   subtype u16 is unsigned(15 downto 0);

   -- Command modes.
   type cm_t is (CM_P1, CM_P2, CM_BPP2, CM_BPP4, CM_BPP8, CM_BPP16);

   constant OP_STOP  : natural := 0;
   constant OP_LMMC  : natural := 1;
   constant OP_LMMV  : natural := 2;
   constant OP_LMCM  : natural := 3;
   constant OP_LMMM  : natural := 4;
   constant OP_CMMC  : natural := 5;
   constant OP_CMMK  : natural := 6;
   constant OP_CMMM  : natural := 7;
   constant OP_BMXL  : natural := 8;
   constant OP_BMLX  : natural := 9;
   constant OP_BMLL  : natural := 10;
   constant OP_LINE  : natural := 11;
   constant OP_SRCH  : natural := 12;
   constant OP_POINT : natural := 13;
   constant OP_PSET  : natural := 14;
   constant OP_ADVN  : natural := 15;

   -- Parameters (openMSX: 16-bit, written masked).
   signal SX, SY, DX, DY, NX, NY : u16 := (others => '0');
   signal ARG       : std_logic_vector(3 downto 0) := (others => '0');
   signal LOG       : std_logic_vector(4 downto 0) := (others => '0');
   signal WM, FG, BG : std_logic_vector(15 downto 0) := (others => '0');
   signal op        : natural range 0 to 15 := 0;

   -- Engine state.
   signal cm        : cm_t := CM_P1;
   signal wlog      : natural range 8 to 11 := 8;      -- log2 of the image width
   signal width     : unsigned(11 downto 0) := to_unsigned(256, 12);
   signal ASX, ADX, ANX, ANY : u16 := (others => '0');
   signal src_addr, dst_addr : unsigned(19 downto 0) := (others => '0');
   signal nb_bytes  : unsigned(19 downto 0) := (others => '0');
   signal data, partial : std_logic_vector(7 downto 0) := (others => '0');
   signal bits_left : unsigned(3 downto 0) := (others => '0');
   signal end_after_read : std_logic := '0';
   signal tr, bd, ce : std_logic := '0';
   signal border_x  : u16 := (others => '0');
   signal irq       : std_logic := '0';
   signal pi        : unsigned(2 downto 0) := (others => '0');   -- pixel in the byte
   signal acc       : std_logic_vector(15 downto 0) := (others => '0');  -- LMCM / BMLX byte
   signal srcv      : std_logic_vector(15 downto 0) := (others => '0');  -- source value
   signal lin_byte  : std_logic := '0';                          -- 16 bpp BMXL / BMLX: second byte
   signal second    : std_logic := '0';                          -- POINT 16 bpp: high byte to come

   type state_t is (S_IDLE, S_START, S_WAIT_DATA, S_WAIT_READ, S_LMCM, S_POINT,
                    S_PIX, S_SRC, S_DST, S_WRITE, S_STEP, S_LIN, S_LIN2, S_MEM);
   signal st, ret   : state_t := S_IDLE;

   -- VRAM access.
   signal mreq, mwe : std_logic := '0';
   signal mbe       : std_logic_vector(1 downto 0) := "11";
   signal maddr     : unsigned(17 downto 0) := (others => '0');
   signal mwdata    : std_logic_vector(15 downto 0) := (others => '0');
   signal mrdata    : std_logic_vector(15 downto 0) := (others => '0');
   -- Current pixel: physical byte (or 16 bpp word) and its x.
   signal paddr     : unsigned(18 downto 0) := (others => '0');
   signal px        : u16 := (others => '0');
   signal dstv      : std_logic_vector(15 downto 0) := (others => '0');

   function bpp_of(m : cm_t) return natural is
   begin
      case m is
         when CM_BPP2  => return 2;
         when CM_BPP8  => return 8;
         when CM_BPP16 => return 16;
         when others   => return 4;
      end case;
   end function;

   function ppb_of(m : cm_t) return natural is
   begin
      case m is
         when CM_BPP2  => return 4;
         when CM_BPP8  => return 1;
         when CM_BPP16 => return 0;
         when others   => return 2;
      end case;
   end function;

   function transform_bx(a : unsigned) return unsigned is
      variable r : unsigned(18 downto 0);
   begin
      r := a(0) & a(18 downto 1);
      return r;
   end function;

   -- Mode::addressOf: physical byte (16 bpp: word in bits 17-0).  The
   -- pitch is width / pixels per byte, a power of 2.
   function address_of(m : cm_t; x, y : u16; wl : natural) return unsigned is
      variable a : unsigned(27 downto 0);
      variable r : unsigned(18 downto 0);
      variable sh : natural;
   begin
      case m is
         when CM_BPP2 => sh := 2;
         when CM_BPP8 | CM_BPP16 => sh := 0;
         when others => sh := 1;
      end case;
      a := resize(shift_right(x, sh) and resize(shift_left(to_unsigned(1, 12), wl - sh) - 1, 16), 28)
           + shift_left(resize(y, 28), wl - sh);
      case m is
         when CM_P1 =>
            r := x(9) & a(17 downto 0);
         when CM_P2 =>
            if a < 16#78000# then
               r := transform_bx(a(18 downto 0));
            elsif a < 16#7C000# then
               r := resize(a - 16#3C000#, 19);
            else
               r := a(18 downto 0);
            end if;
         when CM_BPP16 =>
            r := "0" & a(17 downto 0);
         when others =>
            r := transform_bx(a(18 downto 0));
      end case;
      return r;
   end function;

   -- Mode::shift(value, fromX, toX).
   function shift_px(m : cm_t; v : std_logic_vector(7 downto 0); fromx, tox : unsigned) return std_logic_vector is
      variable s : integer;
   begin
      case m is
         when CM_BPP2 =>
            s := 2 * (to_integer(tox(1 downto 0)) - to_integer(fromx(1 downto 0)));
         when CM_BPP8 | CM_BPP16 =>
            return v;
         when others =>
            s := 4 * (to_integer(tox(0 downto 0)) - to_integer(fromx(0 downto 0)));
      end case;
      if s > 0 then
         return std_logic_vector(shift_right(unsigned(v), s));
      else
         return std_logic_vector(shift_left(unsigned(v), -s));
      end if;
   end function;

   -- Mode::shiftMask(x).
   function field_mask(m : cm_t; x : unsigned) return std_logic_vector is
   begin
      case m is
         when CM_BPP2 =>
            return std_logic_vector(shift_right(unsigned'(x"C0"), 2 * to_integer(x(1 downto 0))));
         when CM_BPP8 | CM_BPP16 =>
            return x"FF";
         when others =>
            if x(0) = '1' then
               return x"0F";
            else
               return x"F0";
            end if;
      end case;
   end function;

   -- Logical operation on a byte; TP: a source pixel of 0 keeps the
   -- destination pixel (fields of bpp bits).
   function log_op(lg : std_logic_vector(4 downto 0); s, d : std_logic_vector(7 downto 0); bpp : natural)
      return std_logic_vector is
      variable r : std_logic_vector(7 downto 0);
   begin
      for b in 0 to 7 loop
         if s(b) = '0' and d(b) = '0' then
            r(b) := lg(0);
         elsif s(b) = '0' then
            r(b) := lg(1);
         elsif d(b) = '0' then
            r(b) := lg(2);
         else
            r(b) := lg(3);
         end if;
      end loop;
      if lg(4) = '1' then
         case bpp is
            when 2 =>
               for f in 0 to 3 loop
                  if s(2 * f + 1 downto 2 * f) = "00" then
                     r(2 * f + 1 downto 2 * f) := d(2 * f + 1 downto 2 * f);
                  end if;
               end loop;
            when 4 =>
               for f in 0 to 1 loop
                  if s(4 * f + 3 downto 4 * f) = "0000" then
                     r(4 * f + 3 downto 4 * f) := d(4 * f + 3 downto 4 * f);
                  end if;
               end loop;
            when 8 =>
               if s = x"00" then
                  r := d;
               end if;
            when others =>
               null;
         end case;
      end if;
      return r;
   end function;

   function wnx(n : u16) return u16 is
   begin
      if n = 0 then return to_unsigned(2048, 16); else return n; end if;
   end function;

   function wny(n : u16) return u16 is
   begin
      if n = 0 then return to_unsigned(4096, 16); else return n; end if;
   end function;

begin

   process (clk)
      variable v     : std_logic_vector(7 downto 0);
      variable a     : unsigned(18 downto 0);
      variable s, d, nw, m1, m2 : std_logic_vector(7 downto 0);
      variable s16, d16, n16, r16 : std_logic_vector(15 downto 0);
      variable dxs, dys : u16;
      variable done  : boolean;
      variable hit   : boolean;
      variable msk, col : std_logic_vector(7 downto 0);
      variable bpp   : natural;

      -- Start a VRAM access; the FSM goes to S_MEM and back to r.
      procedure mem(addr : unsigned(17 downto 0); we : std_logic; be : std_logic_vector(1 downto 0);
                    wd : std_logic_vector(15 downto 0); r : state_t) is
      begin
         maddr  <= addr;
         mwe    <= we;
         mbe    <= be;
         mwdata <= wd;
         mreq   <= '1';
         ret    <= r;
         st     <= S_MEM;
      end procedure;

      procedure ready is
      begin
         op  <= OP_STOP;
         ce  <= '0';
         tr  <= '0';
         irq <= '1';
         st  <= S_IDLE;
      end procedure;

   begin
      if rising_edge(clk) then
         irq <= '0';
         bpp := bpp_of(cm);
         if ARG(2) = '1' then dxs := x"FFFF"; else dxs := x"0001"; end if;
         if ARG(3) = '1' then dys := x"FFFF"; else dys := x"0001"; end if;

         -- Parameter registers.
         if reg_we = '1' then
            v := reg_val;
            case to_integer(reg_num) is
               when 0  => SX(7 downto 0)  <= unsigned(v);
               when 1  => SX(15 downto 8) <= "00000" & unsigned(v(2 downto 0));
               when 2  => SY(7 downto 0)  <= unsigned(v);
               when 3  => SY(15 downto 8) <= "0000" & unsigned(v(3 downto 0));
               when 4  => DX(7 downto 0)  <= unsigned(v);
               when 5  => DX(15 downto 8) <= "00000" & unsigned(v(2 downto 0));
               when 6  => DY(7 downto 0)  <= unsigned(v);
               when 7  => DY(15 downto 8) <= "0000" & unsigned(v(3 downto 0));
               when 8  => NX(7 downto 0)  <= unsigned(v);
               when 9  => NX(15 downto 8) <= "0000" & unsigned(v(3 downto 0));
               when 10 => NY(7 downto 0)  <= unsigned(v);
               when 11 => NY(15 downto 8) <= "0000" & unsigned(v(3 downto 0));
               when 12 => ARG <= v(3 downto 0);
               when 13 => LOG <= v(4 downto 0);
               when 14 => WM(7 downto 0)  <= v;
               when 15 => WM(15 downto 8) <= v;
               when 16 => FG(7 downto 0)  <= v;
               when 17 => FG(15 downto 8) <= v;
               when 18 => BG(7 downto 0)  <= v;
               when 19 => BG(15 downto 8) <= v;
               when 20 =>
                  op <= to_integer(unsigned(v(7 downto 4)));
                  ce <= '1';
                  -- Command mode from the display mode and color depth.
                  case mode is
                     when DM_P1 => cm <= CM_P1; width <= to_unsigned(256, 12); wlog <= 8;
                     when DM_P2 => cm <= CM_P2; width <= to_unsigned(512, 12); wlog <= 9;
                     when others =>
                        case regs(R_SCRMODE0)(1 downto 0) is
                           when "00"   => cm <= CM_BPP2;
                           when "01"   => cm <= CM_BPP4;
                           when "10"   => cm <= CM_BPP8;
                           when others => cm <= CM_BPP16;
                        end case;
                        width <= shift_left(to_unsigned(256, 12), to_integer(unsigned(regs(R_SCRMODE0)(3 downto 2))));
                        wlog  <= 8 + to_integer(unsigned(regs(R_SCRMODE0)(3 downto 2)));
                  end case;
                  st <= S_START;
               when others => null;
            end case;
         end if;

         -- P#2.
         if data_wr = '1' then
            data <= data_in;
            tr   <= '0';
         end if;
         if data_rd = '1' and tr = '1' then
            tr <= '0';
            if end_after_read = '1' then
               end_after_read <= '0';
               op  <= OP_STOP;
               ce  <= '0';
               irq <= '1';
               st  <= S_IDLE;
            end if;
         end if;

         case st is

         when S_IDLE =>
            null;

         when S_START =>
            pi <= (others => '0');
            case op is
               when OP_STOP | OP_CMMK | OP_ADVN =>
                  ready;
               when OP_LMMC | OP_CMMC =>
                  ANX <= wnx(NX);
                  ANY <= wny(NY);
                  if op = OP_LMMC and cm = CM_BPP16 then
                     bits_left <= x"1";
                  end if;
                  tr <= '1';
                  st <= S_WAIT_DATA;
               when OP_LMMV | OP_LMMM =>
                  ANX <= wnx(NX);
                  ANY <= wny(NY);
                  st  <= S_PIX;
               when OP_LMCM =>
                  ANX <= wnx(NX);
                  ANY <= wny(NY);
                  tr  <= '0';
                  end_after_read <= '0';
                  bits_left <= x"0";
                  acc <= (others => '0');
                  st  <= S_LMCM;
               when OP_CMMM | OP_BMXL =>
                  src_addr  <= resize(SX(7 downto 0), 20) + shift_left(resize(SY(10 downto 0), 20), 8);
                  ANX <= wnx(NX);
                  ANY <= wny(NY);
                  bits_left <= x"0";
                  lin_byte  <= '0';
                  st  <= S_PIX;
               when OP_BMLX =>
                  dst_addr  <= resize(DX(7 downto 0), 20) + shift_left(resize(DY(10 downto 0), 20), 8);
                  ANX <= wnx(NX);
                  ANY <= wny(NY);
                  acc <= (others => '0');
                  st  <= S_PIX;
               when OP_BMLL =>
                  if cm = CM_BPP16 then
                     src_addr <= shift_right(resize(SX(7 downto 0), 20) + shift_left(resize(SY(10 downto 0), 20), 8), 1);
                     dst_addr <= shift_right(resize(DX(7 downto 0), 20) + shift_left(resize(DY(10 downto 0), 20), 8), 1);
                     if NX(7 downto 0) = 0 and NY(10 downto 0) = 0 then
                        nb_bytes <= x"40000";
                     else
                        nb_bytes <= shift_right(resize(NX(7 downto 0), 20) + shift_left(resize(NY(10 downto 0), 20), 8), 1);
                     end if;
                  else
                     src_addr <= resize(SX(7 downto 0), 20) + shift_left(resize(SY(10 downto 0), 20), 8);
                     dst_addr <= resize(DX(7 downto 0), 20) + shift_left(resize(DY(10 downto 0), 20), 8);
                     if NX(7 downto 0) = 0 and NY(10 downto 0) = 0 then
                        nb_bytes <= x"80000";
                     else
                        nb_bytes <= resize(NX(7 downto 0), 20) + shift_left(resize(NY(10 downto 0), 20), 8);
                     end if;
                  end if;
                  st <= S_PIX;
               when OP_LINE =>
                  if NX = 0 then
                     ASX <= (others => '0');
                  else
                     ASX <= shift_right(NX - 1, 1);
                  end if;
                  ADX <= DX;
                  ANX <= (others => '0');
                  st  <= S_PIX;
               when OP_SRCH =>
                  ASX <= SX;
                  st  <= S_PIX;
               when OP_POINT =>
                  a := address_of(cm, SX, SY, wlog);
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_POINT);
               when OP_PSET =>
                  st <= S_PIX;
               when others =>
                  ready;
            end case;

         when S_WAIT_DATA =>
            -- LMMC / CMMC: a byte from the CPU.
            if tr = '0' and data_wr = '0' then
               pi <= (others => '0');
               if op = OP_LMMC and cm = CM_BPP16 and bits_left /= 0 then
                  bits_left <= x"0";
                  partial   <= data;
                  tr        <= '1';
               else
                  if op = OP_LMMC and cm = CM_BPP16 then
                     bits_left <= x"1";
                  end if;
                  st <= S_PIX;
               end if;
            end if;

         when S_POINT =>
            -- POINT: the byte (16 bpp: low byte, then the high one).
            if cm = CM_BPP16 then
               data    <= mrdata(7 downto 0);
               partial <= mrdata(15 downto 8);
               second  <= '1';
               end_after_read <= '0';
            else
               if paddr(18) = '1' then data <= mrdata(15 downto 8); else data <= mrdata(7 downto 0); end if;
               second <= '0';
               end_after_read <= '1';
            end if;
            tr <= '1';
            st <= S_WAIT_READ;

         when S_WAIT_READ =>
            -- The CPU read the byte (an end after the read is handled above).
            if tr = '0' and data_rd = '0' then
               if op = OP_LMCM then
                  acc <= (others => '0');
                  pi  <= (others => '0');
                  st  <= S_LMCM;
               elsif op = OP_POINT and second = '1' then
                  second <= '0';
                  data   <= partial;
                  tr     <= '1';
                  end_after_read <= '1';
               end if;
            end if;

         when S_LMCM =>
            -- Read the pixels of the next byte (16 bpp: none, like openMSX).
            if tr = '0' and data_rd = '0' then
               if ppb_of(cm) = 0 or ANY = 0 or pi = ppb_of(cm) then
                  data <= acc(7 downto 0);
                  tr   <= '1';
                  st   <= S_WAIT_READ;
               else
                  a := address_of(cm, SX, SY, wlog);
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_STEP);
               end if;
            end if;

         when S_PIX =>
            -- One step of the command: compute the pixel and read.
            case op is
               when OP_LMMV | OP_CMMC | OP_CMMM | OP_PSET | OP_LINE =>
                  if op = OP_CMMM and bits_left = 0 then
                     a := transform_bx(src_addr(18 downto 0));
                     paddr <= a;
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_LIN);
                  else
                     if op = OP_LINE then
                        a := address_of(cm, ADX, DY, wlog);
                        px <= ADX;
                     else
                        a := address_of(cm, DX, DY, wlog);
                        px <= DX;
                     end if;
                     paddr <= a;
                     -- Source color.
                     if op = OP_CMMC or op = OP_CMMM then
                        if data(7) = '1' then srcv <= FG; else srcv <= BG; end if;
                     else
                        srcv <= FG;
                     end if;
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
                  end if;
               when OP_LMMC =>
                  a := address_of(cm, DX, DY, wlog);
                  px <= DX;
                  paddr <= a;
                  if cm = CM_BPP16 then
                     srcv <= data & partial;
                  else
                     srcv <= x"00" & shift_px(cm, data, resize(pi, 16), DX);
                  end if;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
               when OP_LMMM =>
                  a := address_of(cm, SX, SY, wlog);
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_SRC);
               when OP_BMXL =>
                  if cm = CM_BPP16 or bits_left = 0 then
                     -- Linear source byte (16 bpp: two).
                     a := transform_bx(src_addr(18 downto 0));
                     paddr <= a;
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_LIN);
                  else
                     a := address_of(cm, DX, DY, wlog);
                     px <= DX;
                     paddr <= a;
                     srcv <= x"00" & shift_px(cm, data, resize(pi, 16), DX);
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
                  end if;
               when OP_BMLX =>
                  a := address_of(cm, SX, SY, wlog);
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_SRC);
               when OP_BMLL =>
                  if cm = CM_BPP16 then
                     mem(src_addr(17 downto 0), '0', "11", (others => '0'), S_SRC);
                  else
                     a := transform_bx(src_addr(18 downto 0));
                     paddr <= a;
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_SRC);
                  end if;
               when OP_SRCH =>
                  a := address_of(cm, ASX, SY, wlog);
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_DST);
               when others =>
                  ready;
            end case;

         when S_SRC =>
            -- Source read done (LMMM, BMLX, BMLL).
            if paddr(18) = '1' then v := mrdata(15 downto 8); else v := mrdata(7 downto 0); end if;
            case op is
               when OP_LMMM =>
                  if cm = CM_BPP16 then
                     srcv <= mrdata;
                  else
                     srcv <= x"00" & shift_px(cm, v, SX, DX);
                  end if;
                  a := address_of(cm, DX, DY, wlog);
                  px <= DX;
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
               when OP_BMLX =>
                  if cm = CM_BPP16 then
                     acc <= mrdata;
                     lin_byte <= '0';
                     st <= S_LIN2;
                  else
                     acc(7 downto 0) <= acc(7 downto 0) or (shift_px(cm, v, SX, resize(pi, 16)) and field_mask(cm, resize(pi, 16)));
                     st <= S_STEP;
                  end if;
               when others =>                       -- BMLL
                  if cm = CM_BPP16 then
                     srcv <= mrdata;
                     mem(dst_addr(17 downto 0), '0', "11", (others => '0'), S_WRITE);
                  else
                     srcv <= x"00" & v;
                     a := transform_bx(dst_addr(18 downto 0));
                     paddr <= a;
                     mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
                  end if;
            end case;

         when S_DST =>
            -- SRCH: compare.
            if cm = CM_BPP16 then
               hit := mrdata = FG;
            else
               if paddr(18) = '1' then
                  v := mrdata(15 downto 8); col := FG(15 downto 8);
               else
                  v := mrdata(7 downto 0);  col := FG(7 downto 0);
               end if;
               case cm is
                  when CM_BPP2 =>
                     msk := shift_px(cm, x"03", to_unsigned(3, 16), ASX);
                  when CM_BPP8 =>
                     msk := x"FF";
                  when others =>
                     msk := shift_px(cm, x"0F", to_unsigned(3, 16), ASX);
               end case;
               hit := (v and msk) = (col and msk);
            end if;
            if hit xor (ARG(1) = '1') then
               bd <= '1';
               border_x <= ASX;
               ready;
            elsif ((ASX + dxs) and resize(width, 16)) /= 0 then
               bd <= '0';
               border_x <= ASX + dxs;
               ASX <= ASX + dxs;
               ready;
            else
               ASX <= ASX + dxs;
               st  <= S_PIX;
            end if;

         when S_WRITE =>
            -- Destination read done: logical operation, mask, write.
            if op = OP_BMLL and cm = CM_BPP16 then
               s16 := srcv;
               d16 := mrdata;
               if LOG(4) = '1' and s16 = x"0000" then
                  n16 := d16;
               else
                  n16 := log_op('0' & LOG(3 downto 0), s16(15 downto 8), d16(15 downto 8), 8)
                       & log_op('0' & LOG(3 downto 0), s16(7 downto 0), d16(7 downto 0), 8);
               end if;
               r16 := (d16 and not WM) or (n16 and WM);
               mem(dst_addr(17 downto 0), '1', "11", r16, S_STEP);
            elsif cm = CM_BPP16 then
               s16 := srcv;
               d16 := mrdata;
               if LOG(4) = '1' and s16 = x"0000" then
                  n16 := d16;
               else
                  n16 := log_op('0' & LOG(3 downto 0), s16(15 downto 8), d16(15 downto 8), 8)
                       & log_op('0' & LOG(3 downto 0), s16(7 downto 0), d16(7 downto 0), 8);
               end if;
               r16 := (d16 and not WM) or (n16 and WM);
               mem(paddr(17 downto 0), '1', "11", r16, S_STEP);
            else
               if paddr(18) = '1' then
                  d := mrdata(15 downto 8); m1 := WM(15 downto 8);
               else
                  d := mrdata(7 downto 0);  m1 := WM(7 downto 0);
               end if;
               -- Colors (psetColor) are taken whole for the lane; pixel
               -- sources (pset) are already shifted.
               if op = OP_LMMV or op = OP_CMMC or op = OP_CMMM or op = OP_PSET or op = OP_LINE then
                  if paddr(18) = '1' then s := srcv(15 downto 8); else s := srcv(7 downto 0); end if;
               else
                  s := srcv(7 downto 0);
               end if;
               nw := log_op(LOG, s, d, bpp);
               if op = OP_BMLL then
                  m2 := m1;
               else
                  m2 := m1 and field_mask(cm, px);
               end if;
               v := (d and not m2) or (nw and m2);
               if paddr(18) = '1' then
                  mem(paddr(17 downto 0), '1', "10", v & v, S_STEP);
               else
                  mem(paddr(17 downto 0), '1', "01", v & v, S_STEP);
               end if;
            end if;

         when S_LIN =>
            -- Linear byte read (CMMM, BMXL).
            if paddr(18) = '1' then v := mrdata(15 downto 8); else v := mrdata(7 downto 0); end if;
            src_addr <= src_addr + 1;
            if op = OP_BMXL and cm = CM_BPP16 then
               if lin_byte = '0' then
                  partial  <= v;
                  lin_byte <= '1';
                  st <= S_PIX;
               else
                  lin_byte <= '0';
                  srcv <= v & partial;
                  a := address_of(cm, DX, DY, wlog);
                  px <= DX;
                  paddr <= a;
                  mem(a(17 downto 0), '0', "11", (others => '0'), S_WRITE);
               end if;
            else
               data <= v;
               bits_left <= to_unsigned(8, 4);
               pi <= (others => '0');
               st <= S_PIX;
            end if;

         when S_LIN2 =>
            -- BMLX: linear byte write (16 bpp: two bytes of the pixel).
            if cm = CM_BPP16 then
               a := transform_bx(dst_addr(18 downto 0));
               dst_addr <= dst_addr + 1;
               if lin_byte = '0' then
                  v := acc(7 downto 0);
                  lin_byte <= '1';
                  if a(18) = '1' then
                     mem(a(17 downto 0), '1', "10", v & v, S_LIN2);
                  else
                     mem(a(17 downto 0), '1', "01", v & v, S_LIN2);
                  end if;
               else
                  v := acc(15 downto 8);
                  lin_byte <= '0';
                  if a(18) = '1' then
                     mem(a(17 downto 0), '1', "10", v & v, S_STEP);
                  else
                     mem(a(17 downto 0), '1', "01", v & v, S_STEP);
                  end if;
               end if;
            else
               a := transform_bx(dst_addr(18 downto 0));
               dst_addr <= dst_addr + 1;
               v := acc(7 downto 0);
               acc <= (others => '0');
               if a(18) = '1' then
                  mem(a(17 downto 0), '1', "10", v & v, ret);
               else
                  mem(a(17 downto 0), '1', "01", v & v, ret);
               end if;
            end if;

         when S_STEP =>
            -- Advance after a pixel.
            done := false;
            case op is
               when OP_LMMV | OP_LMMM | OP_LMMC | OP_CMMC | OP_CMMM | OP_BMXL =>
                  if op = OP_CMMC or op = OP_CMMM then
                     data <= data(6 downto 0) & '0';
                     if op = OP_CMMM then
                        bits_left <= bits_left - 1;
                     end if;
                  end if;
                  DX <= DX + dxs;
                  if op = OP_LMMM then
                     SX <= SX + dxs;
                  end if;
                  if ANX = 1 then
                     DX <= DX + dxs - resize(NX * dxs, 16);
                     DY <= DY + dys;
                     if op = OP_LMMM then
                        SX <= SX + dxs - resize(NX * dxs, 16);
                        SY <= SY + dys;
                     end if;
                     if ANY = 1 then
                        done := true;
                     elsif op = OP_LMMC and cm /= CM_BPP16 then
                        ANX <= NX;                 -- (openMSX: not wrapped here)
                     else
                        ANX <= wnx(NX);
                     end if;
                     ANY <= ANY - 1;
                  else
                     ANX <= ANX - 1;
                  end if;
                  if done then
                     ready;
                  else
                     pi <= pi + 1;
                     case op is
                        when OP_LMMC =>
                           if cm = CM_BPP16 or pi + 1 = ppb_of(cm) then
                              tr <= '1';
                              st <= S_WAIT_DATA;
                           else
                              st <= S_PIX;
                           end if;
                        when OP_CMMC =>
                           if pi = 7 then
                              tr <= '1';
                              st <= S_WAIT_DATA;
                           else
                              st <= S_PIX;
                           end if;
                        when OP_BMXL =>
                           if cm /= CM_BPP16 then
                              if pi + 1 = ppb_of(cm) then
                                 bits_left <= x"0";
                              else
                                 bits_left <= x"1";
                              end if;
                           end if;
                           st <= S_PIX;
                        when others =>
                           st <= S_PIX;
                     end case;
                  end if;
               when OP_LMCM | OP_BMLX =>
                  SX <= SX + dxs;
                  if ANX = 1 then
                     SX <= SX + dxs - resize(NX * dxs, 16);
                     SY <= SY + dys;
                     if ANY = 1 then
                        done := true;
                     else
                        ANX <= wnx(NX);
                     end if;
                     ANY <= ANY - 1;
                  else
                     ANX <= ANX - 1;
                  end if;
                  if op = OP_LMCM then
                     if paddr(18) = '1' then v := mrdata(15 downto 8); else v := mrdata(7 downto 0); end if;
                     acc(7 downto 0) <= acc(7 downto 0) or (shift_px(cm, v, SX, resize(pi, 16)) and field_mask(cm, resize(pi, 16)));
                     pi <= pi + 1;
                     if done then
                        end_after_read <= '1';
                     end if;
                     st <= S_LMCM;
                  else
                     -- BMLX: write the byte when full or at the end.
                     pi <= pi + 1;
                     if cm = CM_BPP16 then
                        if done then ready; else st <= S_PIX; end if;
                     elsif done then
                        st  <= S_LIN2;
                        ret <= S_IDLE;
                        ce  <= '0';
                        irq <= '1';
                        op  <= OP_STOP;
                     elsif pi + 1 = ppb_of(cm) then
                        pi  <= (others => '0');
                        st  <= S_LIN2;
                        ret <= S_PIX;
                     else
                        st <= S_PIX;
                     end if;
                  end if;
               when OP_BMLL =>
                  if cm = CM_BPP16 then
                     src_addr <= (src_addr + 1) and x"3FFFF";
                     dst_addr <= (dst_addr + 1) and x"3FFFF";
                  else
                     src_addr <= (src_addr + 1) and x"7FFFF";
                     dst_addr <= (dst_addr + 1) and x"7FFFF";
                  end if;
                  nb_bytes <= nb_bytes - 1;
                  if nb_bytes = 1 then
                     ready;
                  else
                     st <= S_PIX;
                  end if;
               when OP_LINE =>
                  if ARG(0) = '0' then
                     ADX <= ADX + dxs;
                     if ASX < NY then
                        ASX <= ASX + NX - NY;
                        DY  <= DY + dys;
                     else
                        ASX <= ASX - NY;
                     end if;
                  else
                     DY <= DY + dys;
                     if ASX < NY then
                        ASX <= ASX + NX - NY;
                        ADX <= ADX + dxs;
                     else
                        ASX <= ASX - NY;
                     end if;
                  end if;
                  ANX <= ANX + 1;
                  -- End: ANX was NX, or the new ADX is outside the image.
                  if ANX = NX then
                     ready;
                  elsif ARG(0) = '0' and ((ADX + dxs) and resize(width, 16)) /= 0 then
                     ready;
                  elsif ARG(0) = '1' and ASX < NY and ((ADX + dxs) and resize(width, 16)) /= 0 then
                     ready;
                  elsif ARG(0) = '1' and not (ASX < NY) and (ADX and resize(width, 16)) /= 0 then
                     ready;
                  else
                     st <= S_PIX;
                  end if;
               when OP_PSET =>
                  ready;
               when others =>
                  ready;
            end case;

         when S_MEM =>
            if vram_ack_i = '1' then
               mreq   <= '0';
               mrdata <= vram_rdata_i;
               st     <= ret;
            end if;
         end case;

         if clear = '1' then
            SX <= (others => '0'); SY <= (others => '0');
            DX <= (others => '0'); DY <= (others => '0');
            NX <= (others => '0'); NY <= (others => '0');
            ARG <= (others => '0'); LOG <= (others => '0');
            WM <= (others => '0'); FG <= (others => '0'); BG <= (others => '0');
            op <= OP_STOP; ce <= '0'; tr <= '0';
            irq <= '0';
            st <= S_IDLE;
            mreq <= '0';
         end if;
         if reset_n = '0' then
            op <= OP_STOP; ce <= '0'; tr <= '0'; bd <= '0';
            border_x <= (others => '0');
            end_after_read <= '0';
            st <= S_IDLE;
            mreq <= '0';
         end if;
      end if;
   end process;

   data_out   <= data when tr = '1' else x"FF";
   status_o   <= tr & "00" & bd & "000" & ce;
   border_x_o <= std_logic_vector(border_x);
   irq_o      <= irq;

   vram_req_o   <= mreq;
   vram_we_o    <= mwe;
   vram_be_o    <= mbe;
   vram_addr_o  <= maddr;
   vram_wdata_o <= mwdata;

end rtl;
