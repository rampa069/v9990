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


-- V9990 VRAM cache, between the VRAM port of v9990_core and a slow memory
-- (an SDRAM) that reads 4 words at a time.
--
-- The pattern modes and the sprites read the VRAM word by word during the
-- line (a P1 tile: 2 name bytes and 4 pattern bytes in consecutive
-- words), so with an SDRAM each read paid the whole latency.  Here a read
-- that misses brings the line of 4 words (addr with bits 1-0 at 0) and the
-- next reads of that line are acked one clock later, as v9990_vram_bram.
--
-- Core port: as v9990_vram_bram (req held with we / be / addr / wdata until
-- ack, one clock; read data with ack; a new request may follow at once).
-- Memory port: m_req held with m_we / m_be / m_addr / m_wdata until m_ack
-- (one clock).  Reads: m_addr is the first word of a line, m_rdata the 4
-- words with ack (word 0 in bits 15-0).  Writes: one word.
--
-- Writes go through to the memory and update the word if its line is
-- here, so the cache stays the same as the memory (the core is the only
-- one that writes the VRAM).  LINES lines, replaced in turn.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity v9990_vram_cache is
   generic (
      LINES    : natural := 4
   );
   port (
      clk      : in  std_logic;
      reset_n  : in  std_logic;

      -- Core.
      req      : in  std_logic;
      we       : in  std_logic;
      be       : in  std_logic_vector(1 downto 0);
      addr     : in  unsigned(17 downto 0);
      wdata    : in  std_logic_vector(15 downto 0);
      ack      : out std_logic;
      rdata    : out std_logic_vector(15 downto 0);

      -- Memory.
      m_req    : out std_logic;
      m_we     : out std_logic;
      m_be     : out std_logic_vector(1 downto 0);
      m_addr   : out unsigned(17 downto 0);
      m_wdata  : out std_logic_vector(15 downto 0);
      m_ack    : in  std_logic;
      m_rdata  : in  std_logic_vector(63 downto 0)
   );
end v9990_vram_cache;

architecture rtl of v9990_vram_cache is

   type tag_t  is array (0 to LINES - 1) of unsigned(17 downto 2);
   type words_t is array (0 to 3) of std_logic_vector(15 downto 0);
   type data_t is array (0 to LINES - 1) of words_t;

   signal tags    : tag_t := (others => (others => '0'));
   signal valid   : std_logic_vector(0 to LINES - 1) := (others => '0');
   signal data    : data_t := (others => (others => (others => '0')));
   signal victim  : natural range 0 to LINES - 1 := 0;

   type state_t is (S_IDLE, S_READ, S_WRITE);
   signal state   : state_t := S_IDLE;
   signal ack_r   : std_logic := '0';
   signal rdata_r : std_logic_vector(15 downto 0) := (others => '0');
   signal mreq_r  : std_logic := '0';

   signal hit     : std_logic;
   signal hit_l   : natural range 0 to LINES - 1;

   function words(l : std_logic_vector(63 downto 0)) return words_t is
   begin
      return (l(15 downto 0), l(31 downto 16), l(47 downto 32), l(63 downto 48));
   end function;

begin

   process (tags, valid, addr)
   begin
      hit   <= '0';
      hit_l <= 0;
      for l in 0 to LINES - 1 loop
         if valid(l) = '1' and tags(l) = addr(17 downto 2) then
            hit   <= '1';
            hit_l <= l;
         end if;
      end loop;
   end process;

   process (clk)
      variable k  : natural range 0 to 3;
      variable wl : words_t;
   begin
      if rising_edge(clk) then
         ack_r <= '0';
         k := to_integer(addr(1 downto 0));

         case state is

         when S_IDLE =>
            -- The clock of an ack: req is still the request just acked.
            if req = '1' and ack_r = '0' then
               if we = '1' then
                  if hit = '1' then
                     if be(0) = '1' then
                        data(hit_l)(k)(7 downto 0) <= wdata(7 downto 0);
                     end if;
                     if be(1) = '1' then
                        data(hit_l)(k)(15 downto 8) <= wdata(15 downto 8);
                     end if;
                  end if;
                  mreq_r <= '1';
                  state  <= S_WRITE;
               elsif hit = '1' then
                  rdata_r <= data(hit_l)(k);
                  ack_r   <= '1';
               else
                  mreq_r <= '1';
                  state  <= S_READ;
               end if;
            end if;

         when S_READ =>
            if m_ack = '1' then
               tags(victim)  <= addr(17 downto 2);
               valid(victim) <= '1';
               data(victim)  <= words(m_rdata);
               if victim = LINES - 1 then
                  victim <= 0;
               else
                  victim <= victim + 1;
               end if;
               wl      := words(m_rdata);
               rdata_r <= wl(k);
               ack_r   <= '1';
               mreq_r  <= '0';
               state   <= S_IDLE;
            end if;

         when S_WRITE =>
            if m_ack = '1' then
               ack_r  <= '1';
               mreq_r <= '0';
               state  <= S_IDLE;
            end if;

         end case;

         if reset_n = '0' then
            valid  <= (others => '0');
            mreq_r <= '0';
            ack_r  <= '0';
            state  <= S_IDLE;
         end if;
      end if;
   end process;

   ack     <= ack_r;
   rdata   <= rdata_r;

   m_req   <= mreq_r;
   m_we    <= we;
   m_be    <= be;
   m_addr  <= addr when we = '1' else addr(17 downto 2) & "00";
   m_wdata <= wdata;

end rtl;
