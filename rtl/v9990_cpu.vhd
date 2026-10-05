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


-- V9990 CPU interface: the ports P#0-P#15 (60h-6Fh), the registers, the
-- palette, the VRAM read buffer and pointers, the interrupt flags and the
-- system control (MCS, SRS).  Behaves like openMSX V9990::readIO /
-- writeIO / writeRegister (see sim/v9990_model.py).
--
-- Host bus (core clock): the host holds req with wrt / adr / dbo until ack
-- (one clock); dbi is valid with ack.  A request is taken only when the
-- previous VRAM access is done, so the host may wait a few clocks.
--
-- VRAM: logical addresses mapped per display mode (v9990_pkg.vram_phys);
-- the port protocol is that of v9990_vram_bram.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_cpu is
   port (
      clk            : in  std_logic;
      reset_n        : in  std_logic;

      -- Host bus.
      req_i          : in  std_logic;
      wrt_i          : in  std_logic;
      adr_i          : in  std_logic_vector(3 downto 0);
      dbo_i          : in  std_logic_vector(7 downto 0);
      ack_o          : out std_logic;
      dbi_o          : out std_logic_vector(7 downto 0);
      int_n_o        : out std_logic;

      -- Registers and state for the rest of the chip.
      regs_o         : out byte_array(0 to 63);
      mcs_o          : out std_logic;         -- P#7 MCS: 14 MHz master clock
      srs_o          : out std_logic;         -- P#7 SRS: system reset state
      mode_i         : in  dmode_t;           -- display mode (VRAM address mapping)

      -- Palette for the display: Ys & R & G & B (5 bits each), the clock
      -- after pal_idx_i.
      pal_idx_i      : in  unsigned(5 downto 0);
      pal_o          : out std_logic_vector(15 downto 0);
      pal2_idx_i     : in  unsigned(5 downto 0);  -- second read port (cursor colors)
      pal2_o         : out std_logic_vector(15 downto 0);
      eo_o           : out std_logic;         -- status EO
      scay_wr_o      : out std_logic;         -- R#17 written (vertical scroll A low)
      scby_wr_o      : out std_logic;         -- R#21 written (vertical scroll B low)

      -- Raster and interrupt events.
      vr_i           : in  std_logic;         -- vertical border / blank
      hr_i           : in  std_logic;         -- horizontal border / blank
      frame_i        : in  std_logic;         -- frame start: EO flips
      irq_v_i        : in  std_logic;         -- pulses
      irq_h_i        : in  std_logic;
      irq_ce_i       : in  std_logic;

      -- Command engine.
      cmd_status_i   : in  std_logic_vector(7 downto 0);  -- TR (7), BD (4), CE (0)
      cmd_data_i     : in  std_logic_vector(7 downto 0);  -- P#2 read value
      border_x_i     : in  std_logic_vector(15 downto 0);
      cmd_wr_o       : out std_logic;         -- P#2 written (data on cmd_dbo_o)
      cmd_rd_o       : out std_logic;         -- P#2 read
      cmd_dbo_o      : out std_logic_vector(7 downto 0);
      cmd_start_o    : out std_logic;         -- R#52 written

      -- VRAM.
      vram_req_o     : out std_logic;
      vram_we_o      : out std_logic;
      vram_be_o      : out std_logic_vector(1 downto 0);
      vram_addr_o    : out unsigned(17 downto 0);
      vram_wdata_o   : out std_logic_vector(15 downto 0);
      vram_ack_i     : in  std_logic;
      vram_rdata_i   : in  std_logic_vector(15 downto 0)
   );
end v9990_cpu;

architecture rtl of v9990_cpu is

   signal regs       : byte_array(0 to 63) := (others => (others => '0'));
   signal regsel     : byte_t := x"FF";
   signal pending    : std_logic_vector(2 downto 0) := (others => '0');
   signal mcs, eo    : std_logic := '0';
   signal srs        : std_logic := '0';
   signal rbuf       : byte_t := (others => '0');
   signal dbi_r      : byte_t := (others => '1');
   signal ack_r      : std_logic := '0';
   signal req_seen   : std_logic := '0';
   signal prefetch   : std_logic := '0';

   type state_t is (S_IDLE, S_WRITE, S_READ);
   signal state      : state_t := S_IDLE;
   signal vreq       : std_logic := '0';
   signal vwe        : std_logic := '0';
   signal vbank      : std_logic := '0';
   signal vaddr      : unsigned(17 downto 0) := (others => '0');
   signal vwdata     : std_logic_vector(15 downto 0) := (others => '0');

   signal cmd_wr, cmd_rd, cmd_start : std_logic := '0';
   signal cmd_dbo    : byte_t := (others => '0');

   -- Palette: three 64 x 8 RAMs (R with Ys in bit 7, G, B), written by the
   -- CPU, read by the CPU (at R#14) and by the display.
   type pal_t is array (0 to 63) of byte_t;
   signal pal_r      : pal_t := (others => x"9F");
   signal pal_g      : pal_t := (others => x"1F");
   signal pal_b      : pal_t := (others => x"1F");
   signal pal_we     : std_logic := '0';
   signal pal_widx   : unsigned(5 downto 0) := (others => '0');
   signal pal_wcomp  : unsigned(1 downto 0) := (others => '0');
   signal pal_wdata  : byte_t := (others => '0');
   signal cpu_r, cpu_g, cpu_b : byte_t := (others => '0');
   signal dsp_r, dsp_g, dsp_b : byte_t := (others => '0');
   signal cur_r, cur_g, cur_b : byte_t := (others => '0');
   signal scay_wr    : std_logic := '0';
   signal scby_wr    : std_logic := '0';

   signal waddr, raddr : unsigned(18 downto 0);
   signal vmap       : vmap_t;

begin

   waddr <= unsigned(std_logic_vector'(regs(R_VWA0 + 2)(2 downto 0) & regs(R_VWA0 + 1) & regs(R_VWA0)));
   raddr <= unsigned(std_logic_vector'(regs(R_VRA0 + 2)(2 downto 0) & regs(R_VRA0 + 1) & regs(R_VRA0)));
   -- The address mapping follows the display mode of the current line.
   vmap  <= MAP_P1 when mode_i = DM_P1 else
            MAP_P2 when mode_i = DM_P2 else
            MAP_BX;

   -- Palette RAMs.
   process (clk) begin if rising_edge(clk) then
      if pal_we = '1' and pal_wcomp = 0 then
         pal_r(to_integer(pal_widx)) <= pal_wdata and x"9F";
      end if;
      cpu_r <= pal_r(to_integer(unsigned(regs(R_PALPTR)(7 downto 2))));
      dsp_r <= pal_r(to_integer(pal_idx_i));
      cur_r <= pal_r(to_integer(pal2_idx_i));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if pal_we = '1' and pal_wcomp = 1 then
         pal_g(to_integer(pal_widx)) <= pal_wdata and x"1F";
      end if;
      cpu_g <= pal_g(to_integer(unsigned(regs(R_PALPTR)(7 downto 2))));
      dsp_g <= pal_g(to_integer(pal_idx_i));
      cur_g <= pal_g(to_integer(pal2_idx_i));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if pal_we = '1' and pal_wcomp = 2 then
         pal_b(to_integer(pal_widx)) <= pal_wdata and x"1F";
      end if;
      cpu_b <= pal_b(to_integer(unsigned(regs(R_PALPTR)(7 downto 2))));
      dsp_b <= pal_b(to_integer(pal_idx_i));
      cur_b <= pal_b(to_integer(pal2_idx_i));
   end if; end process;

   pal_o  <= std_logic_vector'(dsp_r(7) & dsp_r(4 downto 0) & dsp_g(4 downto 0) & dsp_b(4 downto 0));
   pal2_o <= std_logic_vector'(cur_r(7) & cur_r(4 downto 0) & cur_g(4 downto 0) & cur_b(4 downto 0));

   process (clk)
      variable p      : natural range 0 to 15;
      variable v      : byte_t;
      variable r      : natural range 0 to 63;
      variable a      : unsigned(18 downto 0);
      variable ph     : unsigned(18 downto 0);
      variable ptr    : unsigned(7 downto 0);

      -- openMSX setVRAMAddr: bits 6-3 of the high register cleared, bit 7 kept.
      procedure set_addr(base : natural; n : unsigned(18 downto 0)) is
      begin
         regs(base)     <= std_logic_vector(n(7 downto 0));
         regs(base + 1) <= std_logic_vector(n(15 downto 8));
         regs(base + 2) <= regs(base + 2)(7) & "0000" & std_logic_vector(n(18 downto 16));
      end procedure;

      procedure write_reg(n : natural; val : byte_t) is
      begin
         if n <= 28 and reg_writable(n) then
            regs(n) <= val and reg_mask(n);
         elsif n >= R_CMD_FIRST and n <= R_CMD_OP then
            regs(n) <= val;
            if n = R_CMD_OP then
               cmd_start <= '1';
            end if;
         end if;
         if n = R_VRA0 + 2 then
            prefetch <= '1';
         end if;
         if n = R_SCAY0 then
            scay_wr <= '1';
         end if;
         if n = R_SCBY0 then
            scby_wr <= '1';
         end if;
      end procedure;

      impure function read_reg(n : natural) return byte_t is
      begin
         if srs = '1' then
            return x"FF";
         elsif n = R_BORDERX0 then
            return border_x_i(7 downto 0);
         elsif n = R_BORDERX1 then
            return border_x_i(15 downto 8);
         elsif reg_readable(n) then
            return regs(n);
         else
            return x"FF";
         end if;
      end function;

      -- Palette pointer step (checked by openMSX on a real V9990).
      function pal_step(q : unsigned(7 downto 0)) return unsigned is
      begin
         case q(1 downto 0) is
            when "00" | "01" => return q + 1;
            when "10"        => return q + 2;
            when others      => return q - 3;
         end case;
      end function;

   begin
      if rising_edge(clk) then
         ack_r     <= '0';
         cmd_wr    <= '0';
         cmd_rd    <= '0';
         cmd_start <= '0';
         pal_we    <= '0';
         scay_wr   <= '0';
         scby_wr   <= '0';

         if req_i = '0' then
            req_seen <= '0';
         end if;

         if irq_v_i = '1' then pending(IRQ_V) <= '1'; end if;
         if irq_h_i = '1' then pending(IRQ_H) <= '1'; end if;
         if irq_ce_i = '1' then pending(IRQ_CE) <= '1'; end if;
         if frame_i = '1' then eo <= not eo; end if;

         case state is

         when S_IDLE =>
            if prefetch = '1' then
               -- Read buffer refill after R#5 or a P#0 read.
               prefetch <= '0';
               ph    := vram_phys(raddr, vmap);
               vbank <= ph(18);
               vaddr <= ph(17 downto 0);
               vwe   <= '0';
               vreq  <= '1';
               state <= S_READ;

            elsif req_i = '1' and req_seen = '0' then
               req_seen <= '1';
               ack_r    <= '1';
               p := to_integer(unsigned(adr_i));
               v := dbo_i;
               ptr := unsigned(regs(R_PALPTR));

               if wrt_i = '1' then
                  case p is
                  when P_VRAM =>
                     if srs = '0' then
                        ph     := vram_phys(waddr, vmap);
                        vbank  <= ph(18);
                        vaddr  <= ph(17 downto 0);
                        vwdata <= v & v;
                        vwe    <= '1';
                        vreq   <= '1';
                        state  <= S_WRITE;
                        if regs(R_VWA0 + 2)(7) = '0' then
                           set_addr(R_VWA0, waddr + 1);
                        end if;
                     end if;

                  when P_PALETTE =>
                     pal_we <= '1';
                     if srs = '1' then
                        -- Like writing 0 with the pointer kept at 0.
                        pal_widx  <= (others => '0');
                        pal_wcomp <= "00";
                        pal_wdata <= (others => '0');
                     else
                        pal_widx  <= ptr(7 downto 2);
                        pal_wcomp <= ptr(1 downto 0);
                        pal_wdata <= v;
                        regs(R_PALPTR) <= std_logic_vector(pal_step(ptr));
                     end if;

                  when P_CMDDATA =>
                     cmd_wr  <= '1';
                     cmd_dbo <= v;

                  when P_REGDATA =>
                     if srs = '1' then
                        v := (others => '0');
                     end if;
                     write_reg(to_integer(unsigned(regsel(5 downto 0))), v);
                     if regsel(7) = '0' then
                        regsel(5 downto 0) <= std_logic_vector(unsigned(regsel(5 downto 0)) + 1);
                     end if;

                  when P_REGSEL =>
                     if srs = '1' then
                        regsel <= (others => '0');
                     else
                        regsel <= v;
                     end if;

                  when P_INTFLAG =>
                     pending <= pending and not v(2 downto 0);

                  when P_SYSCTRL =>
                     mcs <= v(0);
                     if v(1) = '1' and srs = '0' then
                        -- Entering the system reset state: every register
                        -- written with 0 (VRAM and palette kept), flags cleared.
                        for n in 0 to R_CMD_OP loop
                           if reg_writable(n) then
                              regs(n) <= (others => '0');
                           end if;
                        end loop;
                        cmd_start <= '1';
                        prefetch  <= '1';      -- R#5 written
                        pending   <= (others => '0');
                     end if;
                     srs <= v(1);

                  when others =>
                     null;
                  end case;

               else
                  case p is
                  when P_VRAM =>
                     dbi_r <= rbuf;
                     if srs = '0' and regs(R_VRA0 + 2)(7) = '0' then
                        set_addr(R_VRA0, raddr + 1);
                        prefetch <= '1';
                     end if;

                  when P_PALETTE =>
                     case ptr(1 downto 0) is
                        when "00"   => dbi_r <= cpu_r;
                        when "01"   => dbi_r <= cpu_g;
                        when "10"   => dbi_r <= cpu_b;
                        when others => dbi_r <= x"00";
                     end case;
                     if srs = '0' and regs(R_PALCTRL)(4) = '0' then
                        regs(R_PALPTR) <= std_logic_vector(pal_step(ptr));
                     end if;

                  when P_CMDDATA =>
                     dbi_r  <= cmd_data_i;
                     cmd_rd <= '1';

                  when P_REGDATA =>
                     dbi_r <= read_reg(to_integer(unsigned(regsel(5 downto 0))));
                     if srs = '0' and regsel(6) = '0' then
                        regsel <= std_logic_vector(unsigned(regsel) + 1) and x"BF";
                     end if;

                  when P_STATUS =>
                     dbi_r <= (cmd_status_i and x"91") or
                              ('0' & vr_i & hr_i & "00" & mcs & eo & '0');

                  when P_INTFLAG =>
                     dbi_r <= "00000" & pending;

                  when others =>
                     dbi_r <= x"FF";
                  end case;
               end if;
            end if;

         when S_WRITE | S_READ =>
            if vram_ack_i = '1' then
               vreq <= '0';
               if state = S_READ then
                  if vbank = '0' then
                     rbuf <= vram_rdata_i(7 downto 0);
                  else
                     rbuf <= vram_rdata_i(15 downto 8);
                  end if;
               end if;
               state <= S_IDLE;
            end if;
         end case;

         if reset_n = '0' then
            regs     <= (others => (others => '0'));
            regsel   <= x"FF";
            pending  <= (others => '0');
            mcs      <= '0';
            eo       <= '0';
            srs      <= '0';
            rbuf     <= (others => '0');
            prefetch <= '0';
            req_seen <= '0';
            ack_r    <= '0';
            vreq     <= '0';
            state    <= S_IDLE;
         end if;
      end if;
   end process;

   ack_o        <= ack_r;
   dbi_o        <= dbi_r;
   int_n_o      <= '0' when (pending and regs(R_INT0)(2 downto 0)) /= "000" else '1';
   regs_o       <= regs;
   mcs_o        <= mcs;
   srs_o        <= srs;
   eo_o         <= eo;
   scay_wr_o    <= scay_wr;
   scby_wr_o    <= scby_wr;
   cmd_wr_o     <= cmd_wr;
   cmd_rd_o     <= cmd_rd;
   cmd_dbo_o    <= cmd_dbo;
   cmd_start_o  <= cmd_start;

   vram_req_o   <= vreq;
   vram_we_o    <= vwe;
   vram_be_o    <= "10" when vbank = '1' else "01";
   vram_addr_o  <= vaddr;
   vram_wdata_o <= vwdata;

end rtl;
