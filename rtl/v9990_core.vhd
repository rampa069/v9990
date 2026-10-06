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


-- V9990 core: CPU interface, display timing, (to come) layers, sprites and
-- command engine, sharing one VRAM port.
--
-- Clock: 42.95 MHz (12 x 3.58 MHz), the common multiple of the two V9990
-- master clocks (XTAL1 21.48 MHz, MCLK 14.32 MHz): one line is 2736
-- clocks, like the openMSX unified clock.
--
-- Video: 15 kHz RGB, 5 bits per color from the palette (Ys in bit 15 of
-- the palette entry), expanded to 8 bits.  vid_x_o / vid_y_o are the
-- raster position of the pixel on the RGB outputs (for the testbench).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.v9990_pkg.all;

entity v9990_core is
   port (
      clk            : in  std_logic;
      reset_n        : in  std_logic;

      -- Host bus (see v9990_cpu).
      req_i          : in  std_logic;
      wrt_i          : in  std_logic;
      adr_i          : in  std_logic_vector(3 downto 0);
      dbo_i          : in  std_logic_vector(7 downto 0);
      ack_o          : out std_logic;
      dbi_o          : out std_logic_vector(7 downto 0);
      int_n_o        : out std_logic;

      -- VRAM (see v9990_vram_bram).
      vram_req_o     : out std_logic;
      vram_we_o      : out std_logic;
      vram_be_o      : out std_logic_vector(1 downto 0);
      vram_addr_o    : out unsigned(17 downto 0);
      vram_wdata_o   : out std_logic_vector(15 downto 0);
      vram_ack_i     : in  std_logic;
      vram_rdata_i   : in  std_logic_vector(15 downto 0);

      -- Video.
      red_o          : out std_logic_vector(7 downto 0);
      grn_o          : out std_logic_vector(7 downto 0);
      blu_o          : out std_logic_vector(7 downto 0);
      hsync_n_o      : out std_logic;
      vsync_n_o      : out std_logic;
      hblank_o       : out std_logic;
      vblank_o       : out std_logic;
      interlace_o    : out std_logic;
      vid_x_o        : out unsigned(11 downto 0);
      vid_y_o        : out unsigned(8 downto 0)
   );
end v9990_core;

architecture rtl of v9990_core is

   signal regs       : byte_array(0 to 63);
   signal mcs, srs   : std_logic;
   signal pal, pal2  : std_logic_vector(15 downto 0);
   signal pal2_idx   : unsigned(5 downto 0);
   signal eo, scay_wr, scby_wr : std_logic;

   -- VRAM clients: 0 CPU, 1 bitmap fetch, 2 pattern fetch, 3 sprites,
   -- 4 command engine.
   signal c0_req, c0_we : std_logic;
   signal c0_be      : std_logic_vector(1 downto 0);
   signal c0_addr    : unsigned(17 downto 0);
   signal c0_wdata   : std_logic_vector(15 downto 0);
   signal c1_req, c2_req, c3_req, c4_req, c4_we : std_logic;
   signal c1_addr, c2_addr, c3_addr, c4_addr : unsigned(17 downto 0);
   signal c4_be      : std_logic_vector(1 downto 0);
   signal c4_wdata   : std_logic_vector(15 downto 0);
   signal gnt        : natural range 0 to 4 := 0;
   signal ack0, ack1, ack2, ack3, ack4 : std_logic;
   -- Command engine.
   signal cmd_wr, cmd_rd, cmd_we, cmd_clear, cmd_irq : std_logic;
   signal cmd_dbo, cmd_val, cmd_data : std_logic_vector(7 downto 0);
   signal cmd_reg    : unsigned(4 downto 0);
   signal cmd_status : std_logic_vector(7 downto 0);
   signal border_x   : std_logic_vector(15 downto 0);
   signal spr_hit, spr_front : std_logic;
   signal spr_idx    : unsigned(5 downto 0);
   signal pat_idx    : unsigned(5 downto 0);
   signal pat_fg     : std_logic;

   signal left       : unsigned(11 downto 0);
   signal top, bottom: unsigned(8 downto 0);
   signal disp_en, pal_t, last_line, interlace : std_logic;

   signal pix_direct, cur_hit, cur_xor : std_logic;
   signal pix_idx    : unsigned(5 downto 0);
   signal pix_rgb, cur_color : std_logic_vector(14 downto 0);

   signal hcnt       : unsigned(11 downto 0);
   signal vcnt       : unsigned(8 downto 0);
   signal mode       : dmode_t;
   signal frame, irq_v, irq_h, hr, vr, disp : std_logic;
   signal hblank, vblank, hsync_n, vsync_n : std_logic;

   -- Output pipeline: 1 color index, 2 palette, 3 RGB.
   type pipe_t is record
      x      : unsigned(11 downto 0);
      y      : unsigned(8 downto 0);
      black  : std_logic;
      direct : std_logic;                       -- rgb instead of the palette
      rgb    : std_logic_vector(14 downto 0);
      hit, xorm : std_logic;                    -- cursor
      ccolor : std_logic_vector(14 downto 0);
      hblank, vblank, hsync_n, vsync_n : std_logic;
   end record;
   signal p1, p2     : pipe_t;
   signal idx1       : unsigned(5 downto 0) := (others => '0');
   signal red_r, grn_r, blu_r : std_logic_vector(7 downto 0) := (others => '0');
   signal p3         : pipe_t;

   function c8(c : std_logic_vector(4 downto 0)) return std_logic_vector is
   begin
      return c & c(4 downto 2);
   end function;

begin

   inst_cpu : entity work.v9990_cpu
   port map (
      clk            => clk,
      reset_n        => reset_n,
      req_i          => req_i,
      wrt_i          => wrt_i,
      adr_i          => adr_i,
      dbo_i          => dbo_i,
      ack_o          => ack_o,
      dbi_o          => dbi_o,
      int_n_o        => int_n_o,
      regs_o         => regs,
      mcs_o          => mcs,
      srs_o          => srs,
      mode_i         => mode,
      pal_idx_i      => idx1,
      pal_o          => pal,
      pal2_idx_i     => pal2_idx,
      pal2_o         => pal2,
      eo_o           => eo,
      scay_wr_o      => scay_wr,
      scby_wr_o      => scby_wr,
      vr_i           => vr,
      hr_i           => hr,
      frame_i        => frame,
      irq_v_i        => irq_v,
      irq_h_i        => irq_h,
      irq_ce_i       => cmd_irq,
      cmd_status_i   => cmd_status,
      cmd_data_i     => cmd_data,
      border_x_i     => border_x,
      cmd_wr_o       => cmd_wr,
      cmd_rd_o       => cmd_rd,
      cmd_dbo_o      => cmd_dbo,
      cmd_start_o    => open,
      cmd_we_o       => cmd_we,
      cmd_reg_o      => cmd_reg,
      cmd_val_o      => cmd_val,
      cmd_clear_o    => cmd_clear,
      vram_req_o     => c0_req,
      vram_we_o      => c0_we,
      vram_be_o      => c0_be,
      vram_addr_o    => c0_addr,
      vram_wdata_o   => c0_wdata,
      vram_ack_i     => ack0,
      vram_rdata_i   => vram_rdata_i
   );

   -- VRAM arbiter: the grant moves, round robin, when the client being
   -- served is done (ack) or idle, so a transfer in progress is never cut.
   process (clk)
      variable reqs : std_logic_vector(0 to 4);
      variable cur  : std_logic;
   begin
      if rising_edge(clk) then
         reqs := c0_req & c1_req & c2_req & c3_req & c4_req;
         cur  := reqs(gnt);
         if vram_ack_i = '1' or cur = '0' then
            for k in 1 to 4 loop
               if reqs((gnt + k) mod 5) = '1' then
                  gnt <= (gnt + k) mod 5;
                  exit;
               end if;
            end loop;
         end if;
         if reset_n = '0' then
            gnt <= 0;
         end if;
      end if;
   end process;

   vram_req_o   <= c0_req when gnt = 0 else c1_req when gnt = 1 else c2_req when gnt = 2 else
                   c3_req when gnt = 3 else c4_req;
   vram_we_o    <= c0_we when gnt = 0 else c4_we when gnt = 4 else '0';
   vram_be_o    <= c0_be when gnt = 0 else c4_be when gnt = 4 else "11";
   vram_addr_o  <= c0_addr when gnt = 0 else c1_addr when gnt = 1 else c2_addr when gnt = 2 else
                   c3_addr when gnt = 3 else c4_addr;
   vram_wdata_o <= c4_wdata when gnt = 4 else c0_wdata;
   ack0         <= vram_ack_i when gnt = 0 else '0';
   ack1         <= vram_ack_i when gnt = 1 else '0';
   ack2         <= vram_ack_i when gnt = 2 else '0';
   ack3         <= vram_ack_i when gnt = 3 else '0';
   ack4         <= vram_ack_i when gnt = 4 else '0';

   inst_cmd : entity work.v9990_cmd
   port map (
      clk            => clk,
      reset_n        => reset_n,
      regs           => regs,
      mode           => mode,
      reg_we         => cmd_we,
      reg_num        => cmd_reg,
      reg_val        => cmd_val,
      clear          => cmd_clear,
      data_wr        => cmd_wr,
      data_in        => cmd_dbo,
      data_rd        => cmd_rd,
      data_out       => cmd_data,
      status_o       => cmd_status,
      border_x_o     => border_x,
      irq_o          => cmd_irq,
      vram_req_o     => c4_req,
      vram_we_o      => c4_we,
      vram_be_o      => c4_be,
      vram_addr_o    => c4_addr,
      vram_wdata_o   => c4_wdata,
      vram_ack_i     => ack4,
      vram_rdata_i   => vram_rdata_i
   );

   inst_raster : entity work.v9990_raster
   port map (
      clk            => clk,
      reset_n        => reset_n,
      regs           => regs,
      mcs            => mcs,
      hcnt_o         => hcnt,
      vcnt_o         => vcnt,
      mode_o         => mode,
      frame_o        => frame,
      irq_v_o        => irq_v,
      irq_h_o        => irq_h,
      hr_o           => hr,
      vr_o           => vr,
      disp_o         => disp,
      left_o         => left,
      top_o          => top,
      bottom_o       => bottom,
      disp_en_o      => disp_en,
      pal_o          => pal_t,
      last_line_o    => last_line,
      interlace_o    => interlace,
      hblank_o       => hblank,
      vblank_o       => vblank,
      hsync_n_o      => hsync_n,
      vsync_n_o      => vsync_n
   );

   interlace_o <= interlace;

   inst_bitmap : entity work.v9990_bitmap
   port map (
      clk            => clk,
      reset_n        => reset_n,
      regs           => regs,
      hcnt           => hcnt,
      vcnt           => vcnt,
      mode           => mode,
      left           => left,
      top            => top,
      bottom         => bottom,
      disp_en        => disp_en,
      pal_t          => pal_t,
      last_line      => last_line,
      frame          => frame,
      interlace      => interlace,
      eo             => eo,
      scay_wr        => scay_wr,
      pal2_idx_o     => pal2_idx,
      pal2_i         => pal2,
      vram_req_o     => c1_req,
      vram_addr_o    => c1_addr,
      vram_ack_i     => ack1,
      vram_rdata_i   => vram_rdata_i,
      pix_direct     => pix_direct,
      pix_idx        => pix_idx,
      pix_rgb        => pix_rgb,
      cur_hit        => cur_hit,
      cur_xor        => cur_xor,
      cur_color      => cur_color
   );

   inst_pattern : entity work.v9990_pattern
   port map (
      clk            => clk,
      reset_n        => reset_n,
      regs           => regs,
      hcnt           => hcnt,
      vcnt           => vcnt,
      mode           => mode,
      left           => left,
      top            => top,
      bottom         => bottom,
      disp_en        => disp_en,
      last_line      => last_line,
      frame          => frame,
      scay_wr        => scay_wr,
      scby_wr        => scby_wr,
      vram_req_o     => c2_req,
      vram_addr_o    => c2_addr,
      vram_ack_i     => ack2,
      vram_rdata_i   => vram_rdata_i,
      pix_idx        => pat_idx,
      pix_fg         => pat_fg
   );

   inst_sprites : entity work.v9990_sprites
   port map (
      clk            => clk,
      reset_n        => reset_n,
      regs           => regs,
      hcnt           => hcnt,
      vcnt           => vcnt,
      mode           => mode,
      left           => left,
      top            => top,
      bottom         => bottom,
      disp_en        => disp_en,
      last_line      => last_line,
      vram_req_o     => c3_req,
      vram_addr_o    => c3_addr,
      vram_ack_i     => ack3,
      vram_rdata_i   => vram_rdata_i,
      spr_hit        => spr_hit,
      spr_front      => spr_front,
      spr_idx        => spr_idx
   );

   -- 1: color index or direct color.  Border: the backdrop color, black in
   -- the overscan modes; display area: the bitmap or the pattern layers.
   process (clk) begin if rising_edge(clk) then
      idx1      <= unsigned(regs(R_BACKDROP)(5 downto 0));
      p1.direct <= '0';
      p1.hit    <= '0';
      p1.rgb    <= pix_rgb;
      p1.xorm   <= cur_xor;
      p1.ccolor <= cur_color;
      if disp = '1' and is_bitmap(mode) then
         idx1      <= pix_idx;
         p1.direct <= pix_direct;
         p1.hit    <= cur_hit;
      elsif disp = '1' then
         -- Front sprites over the layers, back ones over the background.
         if spr_hit = '1' and (spr_front = '1' or pat_fg = '0') then
            idx1 <= spr_idx;
         else
            idx1 <= pat_idx;
         end if;
      end if;
      if is_overscan(mode) and disp = '0' then
         p1.black <= '1';
      else
         p1.black <= '0';
      end if;
      p1.x       <= hcnt;
      p1.y       <= vcnt;
      p1.hblank  <= hblank;
      p1.vblank  <= vblank;
      p1.hsync_n <= hsync_n;
      p1.vsync_n <= vsync_n;
   end if; end process;

   -- 2: palette (read in v9990_cpu, ready the clock after idx1).
   process (clk) begin if rising_edge(clk) then
      p2 <= p1;
   end if; end process;

   -- 3: RGB, with the cursor.
   process (clk)
      variable c : std_logic_vector(14 downto 0);
   begin
      if rising_edge(clk) then
         p3 <= p2;
         if p2.direct = '1' then
            c := p2.rgb;
         else
            c := pal(14 downto 0);
         end if;
         if p2.hit = '1' then
            if p2.xorm = '1' then
               c := not c;
            else
               c := p2.ccolor;
            end if;
         end if;
         if p2.black = '1' or p2.hblank = '1' or p2.vblank = '1' then
            c := (others => '0');
         end if;
         red_r <= c8(c(14 downto 10));
         grn_r <= c8(c(9 downto 5));
         blu_r <= c8(c(4 downto 0));
      end if;
   end process;

   red_o     <= red_r;
   grn_o     <= grn_r;
   blu_o     <= blu_r;
   hsync_n_o <= p3.hsync_n;
   vsync_n_o <= p3.vsync_n;
   hblank_o  <= p3.hblank;
   vblank_o  <= p3.vblank;
   vid_x_o   <= p3.x;
   vid_y_o   <= p3.y;

end rtl;
