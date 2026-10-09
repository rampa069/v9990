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


-- V9990 VRAM in block RAM: 256K x 16 (512 KB), the two banks as two byte
-- lanes.  Used by the simulation and by boards with enough block RAM; the
-- same port is served by the SDRAM backend on the others.
--
-- Port: the client holds req with we / be / addr / wdata until ack (one
-- clock); read data is on rdata with ack.  A new request may follow at
-- once (req kept high with the next address).
--
-- Contents at power-on like openMSX (V9990VRAM::clear): 00h and FFh
-- alternating every 512 bytes of each bank.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity v9990_vram_bram is
   port (
      clk      : in  std_logic;
      req      : in  std_logic;
      we       : in  std_logic;
      be       : in  std_logic_vector(1 downto 0);
      addr     : in  unsigned(17 downto 0);
      wdata    : in  std_logic_vector(15 downto 0);
      ack      : out std_logic;
      rdata    : out std_logic_vector(15 downto 0)
   );
end v9990_vram_bram;

architecture rtl of v9990_vram_bram is

   type ram_t is array (0 to 2**18 - 1) of std_logic_vector(7 downto 0);

   function power_on return ram_t is
      variable r : ram_t;
   begin
      for i in r'range loop
         if (i / 512) mod 2 = 0 then
            r(i) := x"00";
         else
            r(i) := x"FF";
         end if;
      end loop;
      return r;
   end function;

   signal ram_lo : ram_t := power_on;
   signal ram_hi : ram_t := power_on;
   signal ack_r  : std_logic := '0';
   signal lo_r, hi_r : std_logic_vector(7 downto 0) := (others => '0');
   signal go     : std_logic;

begin

   go <= req and not ack_r;

   process (clk) begin if rising_edge(clk) then
      if go = '1' and we = '1' and be(0) = '1' then
         ram_lo(to_integer(addr)) <= wdata(7 downto 0);
      end if;
      lo_r <= ram_lo(to_integer(addr));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      if go = '1' and we = '1' and be(1) = '1' then
         ram_hi(to_integer(addr)) <= wdata(15 downto 8);
      end if;
      hi_r <= ram_hi(to_integer(addr));
   end if; end process;

   process (clk) begin if rising_edge(clk) then
      ack_r <= go;
   end if; end process;

   ack   <= ack_r;
   rdata <= hi_r & lo_r;

end rtl;
