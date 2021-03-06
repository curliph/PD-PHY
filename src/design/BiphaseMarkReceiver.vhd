-- 2019-20 (c) Liam McSherry
--
-- This file is released under the terms of the GNU Affero GPL 3.0. A copy
-- of the text of this licence is available from 'LICENCE.txt' in the project
-- root directory.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;


-- A control unit which interprets the state of an asynchronous line to
-- retrieve biphase mark code (BMC) transmissions, and exposes received
-- data via a Wishbone bus interface.
entity BiphaseMarkReceiver is
port(
    -- Wishbone and master clock
    WB_CLK      : in    std_logic;
    
    -- Wishbone reset input
    WB_RST_I    : in    std_logic;
    -- Wishbone address bus
    WB_ADR_I    : in    std_logic_vector(1 downto 0);
    -- Wishbone data input bus
    WB_DAT_I    : in    std_logic_vector(7 downto 0);
    -- Wishbone cycle input
    WB_CYC_I    : in    std_logic;
    -- Wishbone strobe (slave select) input
    WB_STB_I    : in    std_logic;
    -- Wishbone write-enable input
    WB_WE_I     : in    std_logic;
    
    -- Receive input
    --      Intended to be connected to the output from a filter and
    --      processing arrangement which extracts a square wave from
    --      the raw state of the line.
    RXIN        : in    std_logic;
    
    -- Wishbone data output bus
    WB_DAT_O    : out   std_ulogic_vector(7 downto 0) := (others => '0');
    -- Wishbone acknowledge output
    WB_ACK_O    : out   std_ulogic := '0';
    -- Wishbone error output
    WB_ERR_O    : out   std_ulogic := '0'
    );
end BiphaseMarkReceiver;


architecture Impl of BiphaseMarkReceiver is
    component FIFO9
        generic(
            ASYNC   : boolean
            );
        port(
            WRCLK   : in    std_logic;
            WREQ    : in    std_logic;
            DI      : in    std_logic_vector(8 downto 0);
            FULL    : out   std_ulogic;
            FILLING : out   std_ulogic;
            WERR    : out   std_ulogic;
            
            RDCLK   : in    std_logic;
            RREQ    : in    std_logic;
            DO      : out   std_ulogic_vector(8 downto 0);
            EMPTY   : out   std_ulogic;
            RERR    : out   std_ulogic;
            
            RST     : in    std_logic
            );
    end component;
    
    component PDCRCEngine port(
        CLK : in    std_logic;
        WE  : in    std_logic;
        D   : in    std_logic;
        RST : in    std_logic;
        Q   : out   std_ulogic_vector(31 downto 0)
        );
    end component;
    
    component PDEOPDetector port(
        CLK : in    std_logic;
        EN  : in    std_logic;
        D   : in    std_logic_vector(4 downto 0);
        RST : in    std_logic;
        DET : out   std_ulogic
        );
    end component;
    
    component Decoder4b5b port(
        CLK : in    std_logic;
        WE  : in    std_logic;
        ARG : in    std_logic_vector(4 downto 0);
        Q   : out   std_ulogic_vector(3 downto 0);
        K   : out   std_ulogic
        );
    end component;
        
    component BinarySearcher port(
        CLK : in    std_logic;
        TRG : in    std_logic;
        CMP : in    std_logic;
        RST : in    std_logic;
        Q   : out   std_ulogic_vector(6 downto 0);
        RDY : out   std_ulogic
        );
    end component;
    
    
    -- Control unit Wishbone registers
    signal REG_RXQ      : std_ulogic_vector(7 downto 0) := (others => '0');
    signal REG_TYPE     : std_ulogic_vector(7 downto 0) := (others => '0');
    signal REG_ERRNO    : std_ulogic_vector(7 downto 0) := (others => '0');
    
    -- Control unit internal glue signals
    --
    -- Shift register for holding a line symbol prior to decode
    signal SR_RXIN      : std_ulogic_vector(4 downto 0) := (others => '0');
    -- Register for holding a decoded byte before it is added to the RX queue.
    signal R_DECODE     : std_ulogic_vector(7 downto 0) := (others => '0');
    -- Signal asserted when a transition occurs on RXIN
    signal RXIN_EDGE    : std_ulogic := '0';
    -- Signal strobed when RXIN has returned to line idle
    signal RXIN_IDLE    : std_ulogic := '0';
    -- The shift register used to measure the duration of pulses
    signal SR_RXDECODE  : std_ulogic_vector(27 downto 0) := (others => '0');
    -- And taps off that shift register used to decode
    signal TAP_OF_UI     : std_ulogic := '0'; -- Overlong, full
    signal TAP_OT_UI     : std_ulogic := '0'; -- Overlong, tuning
    signal TAP_F_UI     : std_ulogic  := '0'; -- Full UI
    signal TAP_OH_UI     : std_ulogic := '0'; -- Overlong, half
    signal TAP_H_UI     : std_ulogic  := '0'; -- Half UI
    
    -- Error signals to allow the Wishbone interface to correctly report any
    -- errors identified by the line-decoding portion. The signal remains
    -- asserted until the error condition is cleared.
    --
    -- Invalid line symbol
    signal ERR_INVSYM   : std_ulogic := '0';
    -- Buffer overflow
    signal ERR_BUFOVF   : std_ulogic := '0';
    -- Receive timeout
    signal ERR_RECTIME  : std_ulogic := '0';
    -- CRC failure
    signal ERR_CRCFAIL  : std_ulogic := '0';
    
    -- Frequency divider signals
    --
    -- The signal asserted, synchronously with WB_CLK, at a frequency equal
    -- to that for which the divider is configured.
    signal DCO_PULSE            : std_ulogic := '0';
    -- Division-refiner signals
    signal FDIV_TRG             : std_ulogic := '0';
    signal FDIV_CMP             : std_ulogic := '0';
    signal FDIV_OUT             : std_ulogic_vector(6 downto 0);
    signal FDIV_READY           : std_ulogic;
    
    -- RX queue signals
    signal RXQ_WREQ, RXQ_RREQ   : std_ulogic := '0';
    signal RXQ_FULL, RXQ_EMPTY  : std_ulogic;
    signal RXQ_WERR, RXQ_RERR   : std_ulogic;
    signal RXQ_IS_K             : std_ulogic;
    signal RXQ_RST              : std_ulogic := '0';
    
    -- CRC engine signals
    signal CRC_WE, CRC_D        : std_ulogic := '0';
    signal CRC_RST              : std_ulogic := '0';
    signal CRC_OUT              : std_ulogic_vector(31 downto 0);
    
    -- CRC constants
    constant CRC_RESIDUAL       : std_ulogic_vector(31 downto 0) := x"2144DF1C";
    constant CRC_INITIAL        : std_ulogic_vector(31 downto 0) := x"00000000";
    
    -- End-of-packet detector signals
    signal EOPD_DET             : std_ulogic;
    signal EOPD_RST             : std_ulogic := '0';
    
    -- 4b5b decoder signals
    signal LDEC_WE              : std_ulogic := '0';
    signal LDEC_OUT             : std_ulogic_vector(3 downto 0);
    signal LDEC_K               : std_ulogic;
    
    -- Line synchronisation signals
    signal SYNC_RXIN            : std_ulogic_vector(2 downto 0) := (others => '0');
    
    -- Error number constants
    constant ERRNO_BUS          : std_ulogic_vector(7 downto 0) := x"00";
    constant ERRNO_BADREG       : std_ulogic_vector(7 downto 0) := x"01";
    constant ERRNO_NOTSUPPT     : std_ulogic_vector(7 downto 0) := x"02";
    constant ERRNO_INVSYMBOL    : std_ulogic_vector(7 downto 0) := x"80";
    constant ERRNO_RXBUFOVF     : std_ulogic_vector(7 downto 0) := x"81";
    constant ERRNO_RECVTIMEOUT  : std_ulogic_vector(7 downto 0) := x"82";
    constant ERRNO_CRCFAILURE   : std_ulogic_vector(7 downto 0) := x"83";
begin

    -- Processes and responds to requests on the receiver's Wishbone interface.
    WishboneIF: process(WB_CLK)        
        type WBState_t is (
            -- The interface is waiting to load data from the RX queue, and
            -- will begin doing so when data becomes available
            S1_BeginDataLoad,
            
            -- The interface has started loading data from the queue, but it
            -- isn't yet ready.
            S2_DataStall,
            
            -- Data is ready and can be read by the interface's master
            S3_Ready,
            
            -- The interface encountered an error when receiving data and is
            -- waiting for the line to return to idle
            S4_Error
            );
            
        variable State : WBState_t := S1_BeginDataLoad;
    begin    
        if rising_edge(WB_CLK) then
            -- Clearing the read request on each cycle isn't really the nicest
            -- way to do it, but it saves on extra logic to clear one cycle after
            -- the request is made.
            RXQ_RREQ <= '0';
            
            -- Update our state register.
            REG_TYPE(0) <= '1' when State = S3_Ready else '0';
            REG_TYPE(1) <= RXQ_IS_K when State = S3_Ready else '0';
            
            -- We need this small bit of state to kick off loading data from the
            -- RX queue when it has been emptied or on first start-up.
            case State is
                when S1_BeginDataLoad =>
                    if RXQ_EMPTY = '0' then
                        RXQ_RREQ    <= '1';
                        State       := S2_DataStall;
                    end if;
                    
                when S2_DataStall =>
                    State       := S3_Ready;
                    
                when S3_Ready =>
                    State := S4_Error when (ERR_INVSYM or ERR_BUFOVF or
                                            ERR_RECTIME or ERR_CRCFAIL) = '1';
                    
                when S4_Error =>
                    State := S1_BeginDataLoad when RXIN_IDLE = '1';
                    
                when others =>
                    null;
            end case;            
        
            -- If we're being reset, clear our control signals
            if WB_RST_I = '1' then
                WB_ACK_O    <= '0';
                WB_ERR_O    <= '0';
                State       := S1_BeginDataLoad;
                
            -- Otherwise, if a cycle is ongoing and our strobe has been
            -- asserted, a Wishbone master is requesting we do something.
            elsif WB_CYC_I = '1' and WB_STB_I = '1' then
            
                -- We expose three registers to the bus, so we need to switch
                -- on the address provided to determine our behaviour.
                case WB_ADR_I is
                
                    -- RXQ is the front of the receive queue
                    when "00" =>
                        -- If a write is requested, that's an error. We only
                        -- have read-only registers.
                        if WB_WE_I = '1' then
                            WB_ERR_O    <= '1';
                            REG_ERRNO   <= ERRNO_NOTSUPPT;
                            
                        -- If a read is requested, that's fine in the general
                        -- case, but...
                        else                        
                            -- If any internal error signals are asserted, we
                            -- can't provide any data.
                            if State = S4_Error then
                                WB_ERR_O    <= '1';
                                REG_ERRNO   <= ERRNO_INVSYMBOL      when ERR_INVSYM = '1'   else
                                               ERRNO_RXBUFOVF       when ERR_BUFOVF = '1'   else
                                               ERRNO_RECVTIMEOUT    when ERR_RECTIME = '1'  else
                                               ERRNO_CRCFAILURE     when ERR_CRCFAIL = '1';
                           
                            -- Similarly, if we've cleared the RX queue of all
                            -- data, then we have nothing to provide.
                            --
                            -- We don't rely on 'RXQ_EMPTY' directly as it will
                            -- be asserted when the last item in the queue is
                            -- on the FIFO's outputs. Instead, 'LastCleared' is
                            -- set when that value has actually been used, and
                            -- cleared when a new one is available.
                            elsif State /= S3_Ready then
                                WB_ERR_O    <= '1';
                                REG_ERRNO   <= ERRNO_NOTSUPPT;
                            
                            -- But if we're error free and have data, we can go.
                            else
                                -- The data we provide is that in our RXQ register.
                                WB_ACK_O    <= '1';
                                WB_DAT_O    <= REG_RXQ;
                                
                                -- We then move to the next item in the queue. We
                                -- know another item is available because we test
                                -- for emptiness above.
                                RXQ_RREQ    <= '1';
                                
                                -- Indicate whether we've cleared the last item.
                                State := S1_BeginDataLoad when RXQ_EMPTY = '1' else
                                         S3_Ready;
                            end if;
                        end if;
                    
                    -- TYPE indicates what the contents of RXQ are
                    -- ERRNO provides information on the last error
                    --
                    -- For each of these, we simply copy from another source,
                    -- so it makes sense to handle them together.
                    when "01" | "10" =>
                        -- If a write is requested, that's an error: all our
                        -- registers are read-only.
                        if WB_WE_I = '1' then
                            WB_ERR_O    <= '1';
                            REG_ERRNO   <= ERRNO_NOTSUPPT;
                            
                        -- If it's a read, that's fine
                        else
                            WB_ACK_O    <= '1';
                            WB_DAT_O    <= REG_TYPE when WB_ADR_I = "01"
                                                    else REG_ERRNO;
                        end if;
                    
                    -- And the last address is unused, but should prompt
                    -- an error when accesssed.
                    when "11" =>
                        WB_ERR_O    <= '1';
                        REG_ERRNO   <= ERRNO_NOTSUPPT;
                    
                    when others =>
                        assert false report "Invalid address value";
                        
                end case;
            
            -- The Wishbone spec requires that we clear our bus signals when
            -- our strobe is deasserted.
            elsif WB_STB_I = '0' then
                WB_ACK_O    <= '0';
                WB_ERR_O    <= '0';
                
            end if;
            
        end if;
    end process;
    
    
    -- Interprets the input from the line and writes the results to the RX queue.
    LineInterpreting: process(WB_CLK)
        type RXState_t is (
            -- State 0: Startup
            S0_Startup,
        
            -- State 1: Idling
            --      The interpreter is waiting for the start of a new
            --      transmission.
            S1_Idle,
            
            -- State 2: Receiving preamble
            --      The interpreter is receiving the preamble. It begins by
            --      using the preamble to refine its frequency divider, and
            --      finishes by waiting for the end of the preamble.
            S2a_Preamble_RefineLow,
            S2b_Preamble_RefineHigh1,
            S2b_Preamble_RefineHigh2,
            S2c_Preamble_WaitLow,
            S2d_Preamble_WaitHigh1,
            S2d_Preamble_WaitHigh2,
            
            -- State 3: Read in
            --      The interpreter is decoding the value from the line and
            --      shifting it into a register ready to be decoded.
            S3_ReadIn_Start,
            S3_ReadIn_HighEnd,
            
            -- State 4: Error hold
            --      The interpreter encountered an error and is waiting until
            --      the end of the transmission.
            S4_ErrorHold,
            
            -- State 5: Returning to idle
            --      The interpreter has detected the end of a packet and is
            --      now waiting for the line to return to idle.
            S5_ReturnToIdle
        );
        
        -- The current state
        variable State  : RXState_t := S0_Startup;
        -- A scratchpad count register, used for:
        --  o Keeping track of the current position in the preamble
        --  o Counting the K-codes of an ordered set
        variable Count  : integer range 0 to 63 := 0;
    begin
        if rising_edge(WB_CLK) then
        
            -- Reset our state if the reset is asserted
            if WB_RST_I = '1' then
                State := S1_Idle;
                Count := 0;
                
            else
                -- If we receive a FIFO write error at any time, that indicates
                -- that we've filled the FIFO. We can no longer store data there,
                -- but the data will keep coming from the remote transmitter. Error.
                if RXQ_WERR = '1' then
                    ERR_BUFOVF  <= '1';
                    State       := S4_ErrorHold;
                end if;
                
                
                -- **********
                --
                -- The first set of logic handles reading in values from the
                -- line and readying them for decoding, as appropriate.
                case State is
                    -- ##########
                    --
                    -- Here, we wait for four clocks to allow our line
                    -- synchroniser to clock in the idle line state.
                    --
                    -- If we didn't do this, the line idling at a level
                    -- other than that which our synchroniser was initialised
                    -- to would result in an edge being detected when none
                    -- was actually present.
                    when S0_Startup =>
                        if Count = 4 then
                            Count := 0;
                            State := S1_Idle;
                        else
                            Count := Count + 1;
                        end if;
                
                    -- ##########
                    --
                    -- In the idle state, we're looking for our initial
                    -- transition indicating the start of the preamble.
                    when S1_Idle =>                            
                        -- If we detect an edge...
                        if RXIN_EDGE = '1' then
                            -- We need to know which edge. Receivers must
                            -- tolerate a missing first edge as part of the
                            -- USB-PD spec, but we need to know our position
                            -- in the preamble.
                            --
                            -- If it's a falling edge, that's a transition
                            -- from line idle to low, so we're on the first
                            -- bit of the preamble and are looking for a
                            -- logic low to be transmitted.
                            if SYNC_RXIN(2) = '1' then
                                State := S2a_Preamble_RefineLow;
                                Count := 0;
                            -- Otherwise, it's a rising edge and we missed
                            -- the first bit of the preamble.
                            else
                                State := S2b_Preamble_RefineHigh1;
                                Count := 1;
                            end if;
                        end if;
                    
                    -- ##########
                    --
                    -- When we're still refining and it's a logic zero we
                    -- expect, we're monitoring the full-UI and overlong taps.
                    when S2a_Preamble_RefineLow =>
                        -- Clear any binary search trigger from a previous state
                        FDIV_TRG <= '0';
                    
                        if RXIN_EDGE = '1' then
                            -- If we're finished refining, we want to just wait,
                            -- expecting a logic one to follow us.
                            --
                            -- Because we might reach a suitable frequency before
                            -- setting all the frequency divider's bits, we'll
                            -- transition unconditionally to the wait state after
                            -- 48 cycles. This is more than enough time to set
                            -- all the bits if that's needed.
                            if FDIV_READY = '1' or Count > 47 then
                                State := S2d_Preamble_WaitHigh1;
                                
                            -- Otherwise, if we aren't finished, we want to check
                            -- we're not too fast and not too slow
                            elsif TAP_OT_UI = '1' or TAP_F_UI = '0' then
                                FDIV_TRG    <= '1';
                                FDIV_CMP    <= TAP_F_UI;
                                State := S2b_Preamble_RefineHigh1;
                                
                            -- And if we're just right, we can move on.
                            else
                                State := S2b_Preamble_RefineHigh1;
                            end if;
                            
                            Count := Count + 1;
                        end if;
                        
                    -- ##########
                    --
                    -- Just to simplify, we don't refine on logic ones.
                    when S2b_Preamble_RefineHigh1 | S2b_Preamble_RefineHigh2 =>
                        -- Clear any binary search trigger
                        FDIV_TRG <= '0';
                        
                        if RXIN_EDGE = '1' then
                            if State = S2b_Preamble_RefineHigh1 then
                                State := S2b_Preamble_RefineHigh2;
                            else
                                State := S2a_Preamble_RefineLow;
                                Count := Count + 1;
                            end if;
                        end if;
                    
                    -- ##########
                    --
                    -- We don't need to do anything while we're waiting for
                    -- the end of the preamble.
                    when S2c_Preamble_WaitLow | S2d_Preamble_WaitHigh1 | S2d_Preamble_WaitHigh2 =>
                        FDIV_TRG <= '0';
                        
                        if RXIN_EDGE = '1' then
                        
                            -- We know the preamble ends on a logic one, so we
                            -- can test our count register at the end of each
                            -- logic one we expect.
                            --
                            -- In other cases, we just progress through the
                            -- states, incrementing our count as needed.
                            if State = S2c_Preamble_WaitLow then
                                State := S2d_Preamble_WaitHigh1;
                                Count := Count + 1;
                                
                            elsif State = S2d_Preamble_WaitHigh1 then
                                State := S2d_Preamble_WaitHigh2;
                                
                            elsif Count = 63 then
                                State       := S3_ReadIn_Start;
                                Count       := 0;
                                EOPD_RST    <= '0';
                                
                            else
                                State := S2c_Preamble_WaitLow;
                                Count := Count + 1;
                            end if;
                        end if;
                        
                    -- ##########
                    --
                    -- We're ready to interpret the next line symbol, but we
                    -- don't know what it will be yet. It could be low, in
                    -- which case we can move on to the next one, or it could
                    -- be high, in which case we need to wait for its second
                    -- transition to confirm.
                    when S3_ReadIn_Start =>
                        -- When we detect a line transition...
                        if RXIN_EDGE = '1' then
                            -- If the overlong tap is high, something is wrong
                            -- with the data we're receiving
                            if (TAP_OF_UI or RXIN_IDLE or (TAP_OH_UI and not TAP_F_UI)) = '1' then
                                ERR_RECTIME <= '1';
                                State       := S4_ErrorHold;
                                Count       := 0;
                                
                            -- If the full-UI tap is high, logic zero. We
                            -- stay in the same state because we don't know
                            -- what to expect next.
                            elsif TAP_F_UI = '1' then                              
                                SR_RXIN <= '0' & SR_RXIN(4 downto 1);
                                Count := Count + 1;
                                
                            -- If the half-UI tap is high but the full-UI tap
                            -- isn't, logic one. We need to wait for the second
                            -- transition, and so move from this state.
                            elsif TAP_H_UI = '1' then
                                State := S3_ReadIn_HighEnd;
                                
                            -- If none of the taps are high, something else
                            -- has gone wrong with our data.
                            else
                                assert false report "Not implemented";
                            end if;
                        end if;
                        
                    -- ##########
                    --
                    -- We're now expecting that, on the next edge, we'll have
                    -- the second half of the logic one.
                    when S3_ReadIn_HighEnd =>
                        if RXIN_EDGE = '1' then
                            -- We only expect the half-UI tap to be high. If
                            -- anything else is, that's an error. We need only
                            -- check the next-highest tap here, as it will be
                            -- set if any further ones are also set.
                            --
                            -- If we encounter an unexpected idle
                            if (TAP_OH_UI or RXIN_IDLE) = '1' then
                                ERR_RECTIME <= '1';
                                State       := S4_ErrorHold;
                                Count       := 0;
                                
                            -- If that tap is high, we can shift in the next
                            -- bit and return to our previous state
                            elsif TAP_H_UI = '1' then                              
                                SR_RXIN <= '1' & SR_RXIN(4 downto 1);
                                State   := S3_ReadIn_Start;
                                Count   := Count + 1;
                                
                            -- If no taps are high, something else is wrong.
                            else
                                assert false report "Not implemented";
                            end if;
                        end if;
                        
                    -- ##########
                    --
                    -- If we're in an error state, we wait until the line
                    -- returns to idle.
                    when S4_ErrorHold | S5_ReturnToIdle =>
                        if RXIN_IDLE = '1' then
                            -- Clear all of our error signals
                            ERR_INVSYM  <= '0';
                            ERR_BUFOVF  <= '0';
                            ERR_RECTIME <= '0';
                            ERR_CRCFAIL <= '0';
                            
                            -- Clear other state
                            Count       := 0;
                            EOPD_RST    <= '1';
                            
                            -- Then wait for the next transmission
                            State := S1_Idle;
                        end if;
                end case;
                
                
                -- **********
                --
                -- The second bit of logic is fairly simple, it just needs to
                -- operate concurrently with the first bit and so it is more
                -- easily organised separately.
                case State is
                    
                    -- ##########
                    --
                    -- Every time a transition is detected, the logic above
                    -- shifts a new bit in. What we do here is keep track of
                    -- how many bits have been shifted in and enable the
                    -- decoder when necessary.
                    --
                    -- Other logic deals with conveying decoder output to
                    -- the RX queue.
                    when S3_ReadIn_Start | S3_ReadIn_HighEnd =>
                        if RXIN_EDGE = '1' and Count = 5 then
                            
                            -- When we reach this point, the shift register won't
                            -- have updated and so we need to decode for a second
                            -- time so we can correctly detect invalid symbols.
                            case (not TAP_F_UI and TAP_H_UI) & SR_RXIN(4 downto 1) is
                                -- These symbols are all reserved and so invalid.
                                when "00000" | "00001" | "00010" | "00011" |
                                     "00100" | "00101" | "01000" | "01100" |
                                     "10000" | "11111" =>
                                    ERR_INVSYM  <= '1';
                                    State       := S4_ErrorHold;
                                    
                                -- Any others are valid and so we can signal to
                                -- the decoder that it should proceed.
                                when others =>                        
                                    LDEC_WE <= '1';
                                    Count   := 0;
                            end case;
                        else
                            -- If we detected the end of the packet, we're done
                            -- and can verify the CRC before returning to idle.
                            if EOPD_DET = '1' then
                                -- USB-PD transmissions are specified such that
                                -- CRC'ing the whole message (excl. K-codes) will
                                -- produce a constant final value in the CRC
                                -- generator if the code is correct. This value is
                                -- known as the residual.
                                --
                                -- This is only relevant for packets that include
                                -- data. If a packet is solely K-codes, it doesn't
                                -- include a CRC (and so its CRC will be the
                                -- standard-specified initial value).
                                if (CRC_OUT /= CRC_INITIAL) and (CRC_OUT /= CRC_RESIDUAL) then
                                    ERR_CRCFAIL <= '1';
                                    State       := S4_ErrorHold;
                                else
                                    State := S5_ReturnToIdle;
                                end if;
                            end if;
                        
                            LDEC_WE <= '0';
                        end if;
                        
                
                    -- ##########
                    --
                    -- We want to idle in other states, as they indicate that
                    -- data we're looking to decode isn't ready yet.
                    when others =>
                        null;
                end case;
            end if;
        
        end if;
    end process;
    
    
    -- Transfers data from the output of the decoder into the RX queue.
    Queuer: process(WB_CLK)
        type QState_t is (
            -- State 1: Idling
            --      The queuer is waiting for the decoder to be triggered.
            S1_Idle,
            
            -- State 2: Assembling
            --      The queuer is assembling data to write to the RX queue. A
            --      pair of states are provided because, if it is raw data, it
            --      will be decoded in two 4-bit halves, so a second state is
            --      required to handle the second half.
            S2a_Assemble_FirstHalfOrK,
            S2b_Assemble_WaitForSecond,
            S2c_Assemble_SecondHalf
        );
        
        variable State : QState_t := S1_Idle;
    begin
        if rising_edge(WB_CLK) then
            -- As we need to clear this in almost every state, it's easier
            -- to put it before the switch.
            RXQ_WREQ <= '0';
            
            -- If the queue is being cleared, we should reset too
            if RXQ_RST = '1' then
                State := S1_Idle;
            end if;
        
            case State is
            
                -- ##########
                --
                -- We don't have anything to do until the decoder produces
                -- output, and it only produces output when its write-enable
                -- input is asserted. If we see it's asserted, we know that
                -- output will be available on the next cycle.
                when S1_Idle =>                
                    if LDEC_WE = '1' then
                        State := S2a_Assemble_FirstHalfOrK;
                    end if;
                    
                -- ##########
                --
                -- One cycle after the decoder was enabled, its output will
                -- be available.
                when S2a_Assemble_FirstHalfOrK =>
                    -- No matter what we've decoded, it'll go in the least
                    -- significant half of the word we write to the queue.
                    R_DECODE(3 downto 0)    <= LDEC_OUT;
                    
                    -- If this was a K-code, we clear the higher half of
                    -- the input and write to the queue, then return to
                    -- idle to wait for the next piece of data.
                    if LDEC_K = '1' then
                        R_DECODE(7 downto 4)    <= (others => '0');
                        State                   := S1_Idle;
                        RXQ_WREQ                <= '1';
                        
                    -- Otherwise, we need to wait for the second half
                    else
                        State := S2b_Assemble_WaitForSecond;
                    end if;
                    
                -- ##########
                --
                -- Similarly to the idle state, we wait for the decoder to
                -- be enabled before we add the second half.
                when S2b_Assemble_WaitForSecond =>
                    if LDEC_WE = '1' then
                        State := S2c_Assemble_SecondHalf;
                    end if;
                    
                -- ##########
                --
                -- And now that we have the second half of the data, we
                -- can add it to the RX queue's input and enqueue.
                when S2c_Assemble_SecondHalf =>
                    R_DECODE(7 downto 4)    <= LDEC_OUT;
                    RXQ_WREQ                <= '1';
                    State                   := S1_Idle;
                    
            end case;
        
        end if;
    end process;
    
    
    -- Waits for a line symbol decode to be requested and, if the decode is for
    -- raw data, passes it through the CRC engine.
    --
    -- Note that, because of the inversion and reversing introduced by the CRC
    -- engine, a residual of '2144DF1Ch' is produced instead of 'C704DD7Bh'.
    --
    -- As implemented, this takes six 'WB_CLK' cycles. As the Wishbone clock
    -- should be much faster than any data from the line, this should work with
    -- no issues related to new data being missed.
    CRCShifter: process(WB_CLK)
        type CRCState_t is (
            -- State 1: Idling
            --      The shifter is waiting for a 4b5b decode to be signalled.
            S1_Idle,
            
            -- State 2: Shift First or Cancel
            --      The shifter identifies whether the decode produced a K-code
            --      and, if it didn't, it shifts the data through the CRC
            --      engine. If it did, it returns to idle.
            S2_Shift1OrCancel,
            
            -- States 3 through 5: Shifting
            --      The shifter passes each bit through the CRC engine in
            --      sequence before returning to idle.
            S3_Shift2,
            S4_Shift3,
            S5_Shift4
            );
        
        -- The current state
        variable State : CRCState_t := S1_Idle;
        -- A register to hold a copy of the 4b5b decoder's output
        variable RDATA : std_ulogic_vector(3 downto 0) := (others => '0');
    begin
        if rising_edge(WB_CLK) then
        
            -- We respond to three resets:
            --  o By the Wishbone master
            --  o As a result of an error
            --  o Specific to us, which will be handled by the 
            --    end-of-transmission logic
            if (WB_RST_I or RXQ_RST or CRC_RST) = '1' then
                State   := S1_Idle;
                CRC_WE  <= '0';
                
            else
                case State is
                    
                    -- ##########
                    --
                    -- Wait for a decode to be signalled.
                    when S1_Idle =>
                        CRC_WE  <= '0';
                        State   := S2_Shift1OrCancel when LDEC_WE = '1';
                        
                    -- ##########
                    --
                    -- Once the decode has completed, determine whether we
                    -- proceed with CRC'ing its output.
                    when S2_Shift1OrCancel =>
                        -- If it's a K-code, we can ignore it. USB-PD at s5.6.2
                        -- excludes K-codes from CRC calculations.
                        if LDEC_K = '1' then
                            State := S1_Idle;
                            
                        -- But if it's data, we have to process it.
                        else
                            -- Keep a copy for ourselves, as we don't know
                            -- what the decoder will do after this cycle.
                            RDATA   := LDEC_OUT;
                            -- Feed in the first bit
                            CRC_D   <= RDATA(0);
                            -- Enable the CRC engine
                            CRC_WE  <= '1';
                            -- Process the next bit
                            State   := S3_Shift2;
                       end if;
                       
                    -- ##########
                    --
                    -- Then shift all the data through until we've finished.
                    when S3_Shift2 | S4_Shift3 | S5_Shift4 =>
                        -- Shift
                        RDATA   := '-' & RDATA(3 downto 1);
                        -- Feed in
                        CRC_D   <= RDATA(0);
                        -- Next state
                        State    := S4_Shift3 when State = S3_Shift2 else
                                    S5_Shift4 when State = S4_Shift3 else
                                    S1_Idle;
                
                end case;
            end if;
        
        end if;
    end process;
    
    
    -- Divides the Wishbone/master clock frequency based on the output of the
    -- binary search unit.
    FrequencyDivider: process(WB_CLK)
        variable Count      : integer range 0 to 127 := 127;
        variable Initial    : integer range 0 to 127 := 0;
    begin
        if rising_edge(WB_CLK) then
            Initial := to_integer(unsigned(FDIV_OUT));
            
            if Count = 127 then
                Count       := Initial;
                DCO_PULSE   <= '1';
            else
                Count       := Count + 1;
                DCO_PULSE   <= '0';
            end if;
        end if;
    end process;


    -- The decode shift register allows measurement of the width of each
    -- line steady-state condition
    DecodeShifter: process(WB_CLK)
    begin
        if rising_edge(WB_CLK) then
        
            -- Each time a transition occurs on the line, reset the shift
            -- register to its initial state.
            if RXIN_EDGE = '1' then
                SR_RXDECODE <= (others => '0');
        
            -- And before then, shift in a one for each pulse of the divided
            -- master clock.
            elsif DCO_PULSE = '1' then
                SR_RXDECODE <= SR_RXDECODE(SR_RXDECODE'left - 1 downto 0) & '1';
                
            end if;
        end if;
    end process;
    
    -- We take taps off the decode shift register to allow us to decode the
    -- line state from its contents. As ones are shifted in at a defined
    -- interval, this effectively measures time.
    --
    -- The full-UI tap is placed at the 20th bit position (bit 19) so that a
    -- UI occupies most of the register. Rather than being placed halfway
    -- between this tap and the start (10th position), moving the tap back
    -- provides leeway for when the received signal frequency does not cleanly
    -- align with that of the frequency divider.
    --
    -- The overlong tap is placed three positions further up than the full-UI
    -- tap. This allows frequency refinement to three bits of leeway when it
    -- searches for the full-UI frequency, which should account for unusual
    -- frequencies not dividing nicely.
    TAP_H_UI    <= SR_RXDECODE(8);
    TAP_OH_UI   <= SR_RXDECODE(12);
    TAP_F_UI    <= SR_RXDECODE(19);
    TAP_OT_UI   <= SR_RXDECODE(22);
    TAP_OF_UI   <= SR_RXDECODE(27);

    
    -- An edge detector which synchronises the external input from a remote
    -- transmitter with the receiver's clock and detects transitions in the
    -- received signal.
    -- 
    -- In the receiver, this is used to indicate when the contents of the
    -- decoding shift register (and the taps aff it) should be evaluated.
    EdgeDetector: process(WB_CLK)
    begin
        if rising_edge(WB_CLK) then
            -- Three cascaded flip-flops, the first two to synchronise and the
            -- third to allow change-in-state detections.
            SYNC_RXIN(0) <= RXIN;
            SYNC_RXIN(1) <= SYNC_RXIN(0);
            SYNC_RXIN(2) <= SYNC_RXIN(1);
        end if;
    end process;
    
    -- If the second and third aren't the same, a change occurred.
    RXIN_EDGE <= '1' when SYNC_RXIN(1) /= SYNC_RXIN(2) else '0';
    
    
    -- A component which monitors the line for transitions and determines
    -- whether the line is idle based on the number of transitions within
    -- a given period.
    IdleDetector: process(WB_CLK)
        type SR_EDGES_t is array(13 downto 0) of integer range 0 to 3;
    
        variable SR_EDGES   : SR_EDGES_t := (others => 0);
        variable PERIOD_CNT : integer range 0 to 100 := 0;
        variable EDGE_CNT   : integer range 0 to 42  := 0;
        
        -- Adjust this value based on WB_CLK; should be the number of clock
        -- cycles (or as near as) per microsecond.
        constant N_US       : integer := 100;
    begin
        if rising_edge(WB_CLK) then
        
            -- USB-PD sets out that the line idle state occurs when fewer than
            -- three transitions have occurred within the last 12-20us.
            --
            -- To detect this condition, we maintain a 14-item shift register
            -- of edge counts. An item is ejected every 1us, and so the delay
            -- between an item entering the register and exiting it is 14us.
            --
            -- Each time an item is ejected, its value is subtracted from a
            -- running count of edges. When an item is shifted in, its value is
            -- added to the running count. This is likely to require more
            -- resources than a population count, but should be possible to
            -- carry out in a single cycle.
            
            -- NOTE:
            --      In simulation, at 12us, very slow data clocks resulted in
            --      false detection of overlong pulses. It is set to 14us here,
            --      which should provide extra leeway.
        
            -- If we detect an edge and haven't maxed out our count, increment.
            if RXIN_EDGE = '1' and SR_EDGES(0) /= 3 then
                SR_EDGES(0) := SR_EDGES(0) + 1;
            end if;
            
            -- Every 1us...
            if PERIOD_CNT = N_US then
                -- Update the edge count
                EDGE_CNT := (EDGE_CNT - SR_EDGES(SR_EDGES'left)) + SR_EDGES(0);
                
                -- Shift
                SR_EDGES := SR_EDGES(SR_EDGES'left - 1 downto 0) & 0;
                
                -- Reset count
                PERIOD_CNT := 0;
            else
                PERIOD_CNT := PERIOD_CNT + 1;
            end if;
            
            -- If the running count, including the current 1us, is 3 or
            -- greater, we're not idle.
            RXIN_IDLE <= '1' when (EDGE_CNT + SR_EDGES(0)) < 3 else '0';
            
        end if;
    end process;
    
    
    -- A synchronous FIFO to hold the data we've obtained from the line
    RXQueue: entity work.FIFO9(FFREG)
        generic map(
            ASYNC           => false
            )
        port map(
            WRCLK           => WB_CLK,
            WREQ            => RXQ_WREQ,
            DI(8)           => LDEC_K,
            DI(7 downto 0)  => R_DECODE,
            FULL            => RXQ_FULL,
            FILLING         => open,
            WERR            => RXQ_WERR,
            
            RST             => RXQ_RST,
            
            RDCLK           => '0',
            RREQ            => RXQ_RREQ,
            DO(8)           => RXQ_IS_K,
            DO(7 downto 0)  => REG_RXQ,
            EMPTY           => RXQ_EMPTY,
            RERR            => RXQ_RERR
            );
            
    RXQ_RST <= '1' when (WB_RST_I or ERR_INVSYM or ERR_BUFOVF or ERR_RECTIME or
                         ERR_CRCFAIL) = '1' else '0';
    
    -- A CRC-32 generator to verify the integrity of received data
    CRCEngine: PDCRCEngine port map(
        CLK => WB_CLK,
        WE  => CRC_WE,
        D   => CRC_D,
        RST => CRC_RST,
        Q   => CRC_OUT
        );
    
    -- A unit for detecting the ends of USB-PD packets
    EOPDetector: PDEOPDetector port map(
        CLK => WB_CLK,
        EN  => LDEC_WE,
        D   => SR_RXIN,
        RST => EOPD_RST,
        DET => EOPD_DET
        );
        
    -- A 4b5b decoder to translate received line symbols into byte values
    LineDecoder: Decoder4b5b port map(
        CLK => WB_CLK,
        WE  => LDEC_WE,
        ARG => SR_RXIN,
        Q   => LDEC_OUT,
        K   => LDEC_K
        );
    
    -- A binary search component which will refine the frequency the
    -- receiver operates in synchronism with the remote transmitter
    FreqRefiner: BinarySearcher port map(
        CLK => WB_CLK,
        TRG => FDIV_TRG,
        CMP => FDIV_CMP,
        RST => WB_RST_I,
        Q   => FDIV_OUT,
        RDY => FDIV_READY
        );
end;
