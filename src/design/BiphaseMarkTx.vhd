-- 2019-20 (c) Liam McSherry
--
-- This file is released under the terms of the GNU Affero GPL 3.0. A copy
-- of the text of this licence is available from 'LICENCE.txt' in the project
-- root directory.

library IEEE;
use IEEE.std_logic_1164.all;


-- Provides a biphase mark code (BMC) transmitter which complies with the
-- requirements of BS EN IEC 62680-1-2 (USB Power Delivery).
entity BiphaseMarkTx is
port(
    -- Data clock
    --      Expects input at half the output frequency and 50% duty.
    CLK     : in    std_logic;
    -- Data input
    D       : in    std_logic;
    -- Write enable
    --      Asserting this input indicates the beginning of a transmission,
    --      i.e. that the signal on [D] should be heeded.
    WE      : in    std_logic;
    
    -- Data output
    --      Operates at double the rate of the data clock [DCLK]
    Q       : out   std_ulogic;
    -- 'Output enabled' indicator
    --      Asserted when the output on [Q] is valid. When not asserted, the
    --      output on [Q] is undefined.
    OE      : out   std_ulogic
    );
end BiphaseMarkTx;

architecture Impl of BiphaseMarkTx is        
    -- Outputs from each logic branch
    --
    -- The transmitter uses dual-edged logic to double the clock rate, and
    -- this enables connection to the output without worrying about contention.
    --
    -- BS EN IEC 62680-1-2 requires at s. 5.8.1 that the output begins low. By
    -- setting the default state high, we can avoid the need for special logic
    -- in an initial state. The [OE] signal means our consumer won't make use
    -- of [Q] until we've indicated it should, so defaulting high is fine.
    --
    -- To default high, the values of the rising-edge and falling-edge outputs
    -- must not equal (because line state is their exclusive-or).
    signal REOut    : std_ulogic := '0';
    signal FEOut    : std_ulogic := '1';
    -- A register for the data input so that a change between the rising and
    -- falling edge doesn't adversely impact operation.
    signal DR       : std_ulogic_vector(1 downto 0);
    
    -- States for the internal state machine
    type State_t is (
        -- State 1: Idling
        --      The transmitter is waiting to receive the 'write enable' signal
        --      which indicates the start of a transmission.
        S1_Idle,
        -- State 2a: Transmitting, normal
        --      The transmitter is in the process of transmitting.
        S2a_Tx,
        -- State 2b: Transmitting, last
        --      The transmitter is transmitting the last items in its register.
        S2b_TxLast,
        -- State 3a: Holding line high
        --      The transmitter is holding the line high as required by
        --      BS EN IEC 62680-1-2, s. 5.8.1, and will soon transition to
        --      state 3b.
        S3a_HoldHigh,
        -- State 3b: Holding line low
        --      The transmitter is holding the line low as required by
        --      BS EN IEC 62680-1-2, s. 5.8.1.
        S3b_HoldLow
        );
begin
    main: process(CLK)
        variable State      : State_t := S1_Idle;
    begin
    
        if rising_edge(CLK) then
            case State is
                -- In the idle state, we simply wait for the write-enable
                -- signal to prompt a transition to another state.
                when S1_Idle =>
                    -- Output is always disabled when idling
                    OE  <= '0';
                    -- If writing is enabled...
                    if WE = '1' then
                        -- Begin transmitting
                        State := S2a_Tx;
                        -- Store the current input
                        DR(0) <= D;
                    end if;
                
                
                -- In the transmitting state, on the rising edge, we're reading
                -- data in and waiting for the write-enable signal to go low.
                when S2a_Tx | S2b_TxLast =>
                    -- Enable our output
                    OE      <= '1';
                    -- Invert the line at the start of each unit interval.
                    REOut   <= not REOut;
                    
                    -- The one-cycle delay introduced by the idle state means
                    -- we need a two-item register, and so that we need to shift
                    -- the value from previous cycles forward.
                    DR(1)   <= DR(0);
                    
                    -- Allowing us to read in the present value.
                    DR(0)   <= D;
                    
                    -- If writing is no longer enabled, however, we want to
                    -- move to the next state. This indicates that the value we
                    -- just read in is invalid, and so we need a state that is
                    -- aware it shouldn't transmit it.
                    if WE = '0' then
                        State := S2b_TxLast;
                    end if;
                    
                    
                -- Fairly self-evident, when in hold-high state we hold
                -- the line high for a unit interval.
                when S3a_HoldHigh =>
                    -- First invert the line
                    REOut   <= not REOut;
                    -- Then move on to holding low
                    State   := S3b_HoldLow;
                    
                    
                -- Largely the same as above, but for holding low.
                when S3b_HoldLow =>
                    REOut   <= not REOut;
                    -- Our transmission is now finished, so we return to
                    -- idle to wait for the next one.
                    State   := S1_Idle;
            end case;
        end if;
        
        if falling_edge(CLK) then
            case State is
                -- There is nothing to do on the falling edge when idle.
                when S1_Idle =>
                    null;
                    
                    
                -- When transmitting, the falling edge is when we make a
                -- mid-interval transition if necessary.
                when S2a_Tx | S2b_TxLast =>
                    -- If we're transmitting a '1', BMC demands that
                    -- a transition occur mid-interval.
                    if DR(1) = '1' then
                        FEOut   <= not FEOut;
                    end if;
                    
                    -- If this is the last bit to transmit, we now transition
                    -- into a line-holding state to finish up.
                    --
                    -- If inverting the line would cause it to become high, we
                    -- first hold high then low.
                    if State = S2b_TxLast then
                        State   := S3a_HoldHigh when (not Q) = '1'
                                                else S3b_HoldLow;
                    end if;
                    
                
                -- We don't need to do anything on the falling edge when in one
                -- of the holding states.
                when S3a_HoldHigh | S3b_HoldLow =>
                    null;
            end case;
        end if;
        
    end process;


    -- As we use double-edged logic, this seems like a suitable way to
    -- ensure the synthesiser doesn't do anything weird. This should prompt
    -- it to produce an inversion of CLK and two chains of logic separately
    -- driven from the normal and inverted clock.
    Q   <= REOut xor FEOut;
end;