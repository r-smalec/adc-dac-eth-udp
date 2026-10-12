// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
`default_nettype none

module arty_ad9226_udp #(
    parameter integer DECIMATION = 16,
    parameter integer SAMPLES_PER_PACKET = 512,
    parameter logic [47:0] SOURCE_MAC = 48'h02_00_00_00_00_01,
    // Static broadcast default works without learning the PC MAC. Set an
    // explicit NIC MAC here or through config.tcl for directed transmission.
    parameter logic [47:0] DEST_MAC = 48'hff_ff_ff_ff_ff_ff,
    parameter logic [31:0] SOURCE_IP = 32'hc0a8_0a02,
    parameter logic [31:0] DEST_IP = 32'hc0a8_0a01,
    parameter logic [15:0] DEST_PORT = 16'd5000
)(
    input wire clk_100mhz,
    input wire reset_button,
    input wire test_switch,
    input wire [11:0] adc_data,
    input wire adc_otr,
    output wire adc_clk,
    output wire eth_ref_clk,
    output wire eth_reset_n,
    input wire eth_tx_clk,
    input wire eth_rx_clk,
    input wire [3:0] eth_rxd,
    input wire eth_rx_dv,
    input wire eth_rx_er,
    output wire [3:0] eth_txd,
    output wire eth_tx_en,
    output wire eth_mdc,
    inout wire eth_mdio,
    output wire [3:0] led
);
    wire input_clk, feedback, feedback_buf, locked;
    wire sys_raw, adc_raw, sample_raw, phy_raw;
    wire sys_clk, adc_launch_clk, sample_clk, phy_ref_clk;
    IBUF input_buffer (.I(clk_100mhz), .O(input_clk));
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
        .CLKOUT0_DIVIDE_F(10.0), .CLKOUT1_DIVIDE(20),
        .CLKOUT2_DIVIDE(20), .CLKOUT2_PHASE(0.0), .CLKOUT3_DIVIDE(40)
    ) clock_manager (
        .CLKIN1(input_clk), .CLKFBIN(feedback_buf), .CLKFBOUT(feedback),
        .RST(reset_button), .PWRDWN(1'b0), .LOCKED(locked),
        .CLKOUT0(sys_raw), .CLKOUT1(adc_raw), .CLKOUT2(sample_raw), .CLKOUT3(phy_raw)
    );
    BUFG feedback_buffer (.I(feedback), .O(feedback_buf));
    BUFG system_buffer (.I(sys_raw), .O(sys_clk));
    BUFG adc_buffer (.I(adc_raw), .O(adc_launch_clk));
    BUFG sample_buffer (.I(sample_raw), .O(sample_clk));
    BUFG phy_buffer (.I(phy_raw), .O(phy_ref_clk));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) adc_clock_output (
        .C(adc_launch_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
        .R(1'b0), .S(1'b0), .Q(adc_clk)
    );
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) phy_clock_output (
        .C(phy_ref_clk), .CE(1'b1), .D1(1'b1), .D2(1'b0),
        .R(1'b0), .S(1'b0), .Q(eth_ref_clk)
    );
    wire board_rst;
    taxi_sync_reset #(.N(4)) board_reset (
        .clk(sys_clk), .rst(reset_button || !locked), .out(board_rst)
    );
    wire mdio_i, mdio_o, mdio_oe, link_ready;
    IOBUF mdio_buffer (.I(mdio_o), .T(!mdio_oe), .O(mdio_i), .IO(eth_mdio));
    dp83848_init phy_setup (
        .clk(sys_clk), .rst(board_rst), .mdio_i(mdio_i),
        .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdc(eth_mdc),
        .phy_reset_n(eth_reset_n), .link_ready(link_ready), .phy_status()
    );
    // Register the combined condition before distributing asynchronous
    // reset requests to the per-domain reset synchronizers.
    logic acquisition_rst = 1;
    always @(posedge sys_clk or posedge board_rst) begin
        if (board_rst) acquisition_rst <= 1;
        else acquisition_rst <= !link_ready;
    end

    // AD9226 output delay is 3.5..7 ns after its rising clock edge.
    // Capture the preceding output word on the following rising edge, 20 ns
    // later at 50 MHz; validate the clock/data PCB and cable budget
    // in constraints/arty_a7.xdc when the actual ADC connection is known.
    (* IOB = "TRUE" *) logic [12:0] adc_input_reg = 0;
    always @(posedge sample_clk) adc_input_reg <= {adc_otr, adc_data};
    (* ASYNC_REG = "TRUE" *) logic test_meta = 0, test_sync = 0;
    always @(posedge sample_clk) begin
        test_meta <= test_switch;
        test_sync <= test_meta;
    end
    wire [31:0] dropped_blocks;
    wire underflow, packet_started;
    ad9226_udp_core #(
        .SIM(0), .DECIMATION(DECIMATION), .SAMPLES_PER_PACKET(SAMPLES_PER_PACKET),
        .SOURCE_MAC(SOURCE_MAC), .DEST_MAC(DEST_MAC), .SOURCE_IP(SOURCE_IP),
        .DEST_IP(DEST_IP), .DEST_PORT(DEST_PORT)
    ) core (
        .sys_clk(sys_clk), .sample_clk(sample_clk), .rst(acquisition_rst),
        .adc_data(adc_input_reg[11:0]), .adc_otr(adc_input_reg[12]),
        .test_pattern(test_sync), .tx_enable(link_ready),
        .mii_tx_clk(eth_tx_clk), .mii_rx_clk(eth_rx_clk),
        .mii_rxd(eth_rxd), .mii_rx_dv(eth_rx_dv), .mii_rx_er(eth_rx_er),
        .mii_txd(eth_txd), .mii_tx_en(eth_tx_en), .mii_tx_er(),
        .dropped_blocks(dropped_blocks), .tx_underflow(underflow), .tx_packet(packet_started)
    );
    // Register the counter reduction in its own domain before crossing.
    logic drop_seen = 0;
    always @(posedge sample_clk) drop_seen <= |dropped_blocks;
    wire drop_seen_sync;
    taxi_sync_signal #(.WIDTH(1), .N(2)) drop_led_sync (
        .clk(sys_clk), .in(drop_seen), .out(drop_seen_sync)
    );
    // Stretch raw PHY-domain TX_EN activity for a visible LED.
    wire active_sync;
    taxi_sync_signal #(.WIDTH(1), .N(2)) activity_sync (
        .clk(sys_clk), .in(eth_tx_en), .out(active_sync)
    );
    logic [22:0] activity_hold = 0;
    always @(posedge sys_clk) begin
        if (board_rst) activity_hold <= 0;
        else if (active_sync) activity_hold <= 23'd5000000;
        else if (activity_hold != 0) activity_hold <= activity_hold - 1'b1;
    end
    assign led = {activity_hold != 0, drop_seen_sync, link_ready, locked};
endmodule
`default_nettype wire
