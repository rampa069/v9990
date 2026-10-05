-- Simulation wrapper for the V9990 core (v9990/), driven by
-- sim/tests/test_v9990_*.py: the core with its VRAM in block RAM and the
-- 42.95 MHz clock.
--
-- VRAM load: a rising edge of load_i writes CAPTURE_DIR/vram.hex (one
-- 16-bit word per line, hex, 256K lines) into the block RAM through its
-- port, the core held off the port; loading_o is high meanwhile.
--
-- Frame capture: a rising edge of capture_en_i arms one capture; the next
-- whole frame is written to CAPTURE_DIR/v9990_<n>.ppm (n = frames_o when
-- it starts) with one sample every cap_step_i clocks of each line (from
-- clock 0), all the lines; frames_o counts the frames written.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity v9990_tb is
   generic (
      CAPTURE_DIR    : string := "."
   );
   port (
      clk_o          : out std_logic;
      reset_n_i      : in  std_logic;
      req_i          : in  std_logic;
      wrt_i          : in  std_logic;
      adr_i          : in  std_logic_vector(3 downto 0);
      dbo_i          : in  std_logic_vector(7 downto 0);
      ack_o          : out std_logic;
      dbi_o          : out std_logic_vector(7 downto 0);
      int_n_o        : out std_logic;

      red_o          : out std_logic_vector(7 downto 0);
      grn_o          : out std_logic_vector(7 downto 0);
      blu_o          : out std_logic_vector(7 downto 0);
      hsync_n_o      : out std_logic;
      vsync_n_o      : out std_logic;
      hblank_o       : out std_logic;
      vblank_o       : out std_logic;
      vid_x_o        : out unsigned(11 downto 0);
      vid_y_o        : out unsigned(8 downto 0);

      load_i         : in  std_logic;
      loading_o      : out std_logic;
      capture_en_i   : in  std_logic;
      cap_step_i     : in  integer;
      frames_o       : out integer
   );
end v9990_tb;

architecture sim of v9990_tb is

   -- 42.954545 MHz: 23.28 ns.
   constant T_HALF : time := 11640 ps;

   signal clk        : std_logic := '0';
   signal vreq, vwe  : std_logic;
   signal vbe        : std_logic_vector(1 downto 0);
   signal vaddr      : unsigned(17 downto 0);
   signal vwdata     : std_logic_vector(15 downto 0);
   signal vack       : std_logic;
   -- The block RAM port: the core's or the loader's.
   signal loading    : std_logic := '0';
   signal l_req      : std_logic := '0';
   signal l_addr     : unsigned(17 downto 0) := (others => '0');
   signal l_data     : std_logic_vector(15 downto 0) := (others => '0');
   signal m_req, m_we: std_logic;
   signal m_be       : std_logic_vector(1 downto 0);
   signal m_addr     : unsigned(17 downto 0);
   signal m_wdata    : std_logic_vector(15 downto 0);
   signal m_ack, c_ack : std_logic;
   signal vrdata     : std_logic_vector(15 downto 0);

   signal r, g, b    : std_logic_vector(7 downto 0);
   signal x          : unsigned(11 downto 0);
   signal y          : unsigned(8 downto 0);
   signal frames     : integer := 0;

begin

   clk   <= not clk after T_HALF;
   clk_o <= clk;

   inst_core : entity work.v9990_core
   port map (
      clk            => clk,
      reset_n        => reset_n_i,
      req_i          => req_i,
      wrt_i          => wrt_i,
      adr_i          => adr_i,
      dbo_i          => dbo_i,
      ack_o          => ack_o,
      dbi_o          => dbi_o,
      int_n_o        => int_n_o,
      vram_req_o     => vreq,
      vram_we_o      => vwe,
      vram_be_o      => vbe,
      vram_addr_o    => vaddr,
      vram_wdata_o   => vwdata,
      vram_ack_i     => c_ack,
      vram_rdata_i   => vrdata,
      red_o          => r,
      grn_o          => g,
      blu_o          => b,
      hsync_n_o      => hsync_n_o,
      vsync_n_o      => vsync_n_o,
      hblank_o       => hblank_o,
      vblank_o       => vblank_o,
      interlace_o    => open,
      vid_x_o        => x,
      vid_y_o        => y
   );

   red_o   <= r;
   grn_o   <= g;
   blu_o   <= b;
   vid_x_o <= x;
   vid_y_o <= y;

   m_req   <= l_req when loading = '1' else vreq;
   m_we    <= '1' when loading = '1' else vwe;
   m_be    <= "11" when loading = '1' else vbe;
   m_addr  <= l_addr when loading = '1' else vaddr;
   m_wdata <= l_data when loading = '1' else vwdata;
   c_ack   <= m_ack when loading = '0' else '0';

   inst_vram : entity work.v9990_vram_bram
   port map (
      clk            => clk,
      req            => m_req,
      we             => m_we,
      be             => m_be,
      addr           => m_addr,
      wdata          => m_wdata,
      ack            => m_ack,
      rdata          => vrdata
   );

   loader : process
      file f     : text;
      variable l : line;
      variable w : std_logic_vector(15 downto 0);
   begin
      wait until rising_edge(load_i);
      -- Let a transfer of the core finish.
      wait until rising_edge(clk) and vreq = '0';
      loading <= '1';
      file_open(f, CAPTURE_DIR & "/vram.hex", read_mode);
      for a in 0 to 2**18 - 1 loop
         readline(f, l);
         hread(l, w);
         l_addr <= to_unsigned(a, 18);
         l_data <= w;
         l_req  <= '1';
         wait until rising_edge(clk) and m_ack = '1';
      end loop;
      l_req <= '0';
      file_close(f);
      wait until rising_edge(clk);
      loading <= '0';
   end process;

   loading_o <= loading;

   capture : process (clk)
      file f          : text;
      variable l      : line;
      variable active : boolean := false;
      variable armed  : boolean := false;
      variable en_d   : std_logic := '0';
   begin
      if rising_edge(clk) then
         if capture_en_i = '1' and en_d = '0' then
            armed := true;
         end if;
         en_d := capture_en_i;
         if x = 0 and y = 0 then
            if active then
               file_close(f);
               active := false;
               frames <= frames + 1;
            end if;
            if armed then
               armed := false;
               file_open(f, CAPTURE_DIR & "/v9990_" & integer'image(frames) & ".ppm", write_mode);
               write(l, string'("P3 ") & integer'image((2735 + cap_step_i) / cap_step_i) & " 0 255");
               writeline(f, l);
               active := true;
            end if;
         end if;
         if active and to_integer(x) mod cap_step_i = 0 then
            write(l, integer'image(to_integer(unsigned(r))) & " " &
                     integer'image(to_integer(unsigned(g))) & " " &
                     integer'image(to_integer(unsigned(b))));
            writeline(f, l);
         end if;
      end if;
   end process;

   frames_o <= frames;

end sim;
