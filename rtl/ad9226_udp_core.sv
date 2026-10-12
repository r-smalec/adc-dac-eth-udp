// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
`default_nettype none

module ad9226_udp_core #(
    parameter bit SIM = 0,
    parameter integer DECIMATION = 16,
    parameter integer SAMPLES_PER_PACKET = 512,
    parameter integer SAMPLE_FIFO_BYTES = 8192,
    parameter integer TX_FIFO_BYTES = 4096,
    parameter logic [47:0] SOURCE_MAC = 48'h02_00_00_00_00_01,
    parameter logic [47:0] DEST_MAC = 48'h02_00_00_00_00_02,
    parameter logic [31:0] SOURCE_IP = 32'hc0a8_0a02,
    parameter logic [31:0] DEST_IP = 32'hc0a8_0a01,
    parameter logic [15:0] DEST_PORT = 16'd5000
)(
    input wire sys_clk,
    input wire sample_clk,
    input wire rst,
    input wire [11:0] adc_data,
    input wire adc_otr,
    input wire test_pattern,
    input wire tx_enable,
    input wire mii_tx_clk,
    input wire mii_rx_clk,
    input wire [3:0] mii_rxd,
    input wire mii_rx_dv,
    input wire mii_rx_er,
    output wire [3:0] mii_txd,
    output wire mii_tx_en,
    output wire mii_tx_er,
    output logic [31:0] dropped_blocks = 0,
    output wire tx_underflow,
    output wire tx_packet
);
    localparam integer PACKET_WORDS = 4 + SAMPLES_PER_PACKET/2;
    localparam integer COUNT_WIDTH = 12;
    wire sys_rst, sample_rst, tx_clk, tx_rst, rx_clk, rx_rst;
    taxi_sync_reset #(.N(4)) sys_reset (.clk(sys_clk), .rst(rst), .out(sys_rst));
    taxi_sync_reset #(.N(4)) sample_reset (.clk(sample_clk), .rst(rst), .out(sample_rst));

    taxi_axis_if #(.DATA_W(32), .KEEP_EN(1), .LAST_EN(1)) samples_in();
    taxi_axis_if #(.DATA_W(32), .KEEP_EN(1), .LAST_EN(1)) samples_out();
    wire sample_overflow;
    ad9226_frame_source #(
        .DECIMATION(DECIMATION), .SAMPLES_PER_PACKET(SAMPLES_PER_PACKET)
    ) adc_source (
        .clk(sample_clk), .rst(sample_rst), .adc_data(adc_data),
        .adc_otr(adc_otr), .test_pattern(test_pattern),
        .data(samples_in.tdata), .valid(samples_in.tvalid), .last(samples_in.tlast)
    );
    assign samples_in.tkeep = '1;
    assign samples_in.tstrb = '1;
    assign samples_in.tuser = '0;
    assign samples_in.tid = '0;
    assign samples_in.tdest = '0;

    // Store-and-forward ensures a committed, fixed-size block is available
    // before the upstream packetizer starts. Never emit a partial ADC block.
    taxi_axis_async_fifo #(
        .DEPTH(SAMPLE_FIFO_BYTES), .RAM_PIPELINE(2), .FRAME_FIFO(1),
        .DROP_OVERSIZE_FRAME(1), .DROP_WHEN_FULL(1)
    ) sample_fifo (
        .s_clk(sample_clk), .s_rst(sample_rst), .s_axis(samples_in),
        .m_clk(sys_clk), .m_rst(sys_rst), .m_axis(samples_out),
        .s_status_overflow(sample_overflow)
    );
    always @(posedge sample_clk) begin
        if (sample_rst) dropped_blocks <= 0;
        else if (sample_overflow) dropped_blocks <= dropped_blocks + 1'b1;
    end

    taxi_axis_if #(.DATA_W(8), .KEEP_EN(0), .USER_EN(1), .USER_W(2)) packet_in();
    taxi_axis_if #(.DATA_W(8), .KEEP_EN(0), .USER_EN(1), .USER_W(2)) packet_out();
    wire busy, fifo_rd;
    logic send = 0;
    logic [1:0] send_state = 0;
    // Account for the registered send/busy handshake; do not start twice.
    always @(posedge sys_clk) begin
        if (sys_rst) begin
            send <= 0;
            send_state <= 0;
        end else begin
            send <= 0;
            case (send_state)
                0: if (samples_out.tvalid && !busy) begin
                    send <= 1;
                    send_state <= 1;
                end
                1: if (busy) send_state <= 2;
                2: if (!busy) send_state <= 0;
                default: send_state <= 0;
            endcase
        end
    end
    // Built from pinned upstream VHDL, with the reviewed patch in patches/.
    fifo_to_udp packetizer (
        .my_MAC(SOURCE_MAC), .my_IP(SOURCE_IP),
        .rcv_MAC(DEST_MAC), .rcv_IP(DEST_IP), .dport(DEST_PORT),
        .send(send), .busy(busy), .max_words(COUNT_WIDTH'(PACKET_WORDS)),
        .clk(sys_clk), .rst_p(sys_rst),
        .fifo_av_words(COUNT_WIDTH'(PACKET_WORDS)), .fifo_din(samples_out.tdata),
        .fifo_rd(fifo_rd), .fifo_empty(!samples_out.tvalid),
        .tx_data(packet_in.tdata), .tx_valid(packet_in.tvalid),
        .tx_last(packet_in.tlast), .tx_ready(packet_in.tready)
    );
    assign samples_out.tready = fifo_rd;
    assign packet_in.tkeep = 1'b1;
    assign packet_in.tstrb = 1'b1;
    assign packet_in.tuser = 2'b00;
    assign packet_in.tid = '0;
    assign packet_in.tdest = '0;

    // Entire Ethernet frames cross to the PHY clock before transmission.
    // This prevents MAC underrun when the packetizer stalls between bytes.
    taxi_axis_async_fifo #(
        .DEPTH(TX_FIFO_BYTES), .RAM_PIPELINE(2), .FRAME_FIFO(1),
        .DROP_OVERSIZE_FRAME(1), .DROP_WHEN_FULL(0)
    ) tx_fifo (
        .s_clk(sys_clk), .s_rst(sys_rst), .s_axis(packet_in),
        .m_clk(tx_clk), .m_rst(tx_rst), .m_axis(packet_out)
    );

    taxi_axis_if #(.DATA_W(96), .KEEP_EN(0), .ID_EN(1)) tx_completion();
    taxi_axis_if #(.DATA_W(8), .KEEP_EN(0), .USER_EN(1), .USER_W(1)) rx_unused();
    taxi_axis_if #(.DATA_W(32), .KEEP_EN(0)) stats_unused();
    assign tx_completion.tready = 1'b1;
    assign rx_unused.tready = 1'b1;
    assign stats_unused.tready = 1'b1;
    wire tx_enable_sync;
    taxi_sync_signal #(.WIDTH(1), .N(2)) enable_sync (
        .clk(tx_clk), .in(tx_enable), .out(tx_enable_sync)
    );
    taxi_eth_mac_mii #(
        .SIM(SIM), .VENDOR("XILINX"), .FAMILY("artix7"),
        .PTP_TS_EN(0), .PFC_EN(0), .PAUSE_EN(0), .STAT_EN(0)
    ) mac (
        .rst(rst), .tx_clk(tx_clk), .tx_rst(tx_rst), .rx_clk(rx_clk), .rx_rst(rx_rst),
        .s_axis_tx(packet_out), .m_axis_tx_cpl(tx_completion), .m_axis_rx(rx_unused),
        .mii_tx_clk(mii_tx_clk), .mii_rx_clk(mii_rx_clk),
        .mii_rxd(mii_rxd), .mii_rx_dv(mii_rx_dv), .mii_rx_er(mii_rx_er),
        .mii_txd(mii_txd), .mii_tx_en(mii_tx_en), .mii_tx_er(mii_tx_er),
        .stat_clk(sys_clk), .stat_rst(sys_rst), .m_axis_stat(stats_unused),
        .tx_start_packet(tx_packet), .stat_tx_err_underflow(tx_underflow),
        .cfg_tx_enable(tx_enable_sync), .cfg_rx_enable(1'b0),
        .cfg_tx_ifg(8'd12), .cfg_tx_max_pkt_len(16'd1517)
    );
`ifndef SYNTHESIS
    always @(posedge sys_clk) if (!sys_rst && fifo_rd && !samples_out.tvalid)
        $fatal(1, "Packetizer read an empty committed ADC frame");
    always @(posedge sample_clk) if (!sample_rst && samples_in.tvalid && !samples_in.tready)
        $fatal(1, "ADC source requires an always-ready, whole-frame-drop FIFO");
`endif
endmodule
`default_nettype wire
