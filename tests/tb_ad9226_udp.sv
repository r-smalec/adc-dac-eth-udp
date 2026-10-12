// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
module tb_ad9226_udp;
    parameter integer DECIMATION = 16;
    parameter integer SAMPLES = 512;
    parameter integer SAMPLE_FIFO_BYTES = 8192;
    parameter integer TX_FIFO_BYTES = 4096;
    parameter integer TARGET_FRAMES = 8;
    parameter integer HOLD_TX_CYCLES = 0;
    parameter integer TEST_PATTERN = 0;
    parameter integer RESET_DURING_FRAME = 0;
    logic sys_clk = 0, sample_clk = 0, tx_clk = 0, rx_clk = 0;
    always #5 sys_clk = !sys_clk;
    initial begin #3; forever #10 sample_clk = !sample_clk; end
    initial begin #7; forever #20 tx_clk = !tx_clk; end
    initial begin #11; forever #20 rx_clk = !rx_clk; end
    logic rst = 1, tx_enable = 0;
    logic [11:0] adc_data = 0;
    logic adc_otr = 0;
    wire [3:0] txd;
    wire tx_en, tx_er, tx_underflow, tx_packet;
    wire [31:0] dropped_blocks;
    ad9226_udp_core #(
        .SIM(1), .DECIMATION(DECIMATION), .SAMPLES_PER_PACKET(SAMPLES),
        .SAMPLE_FIFO_BYTES(SAMPLE_FIFO_BYTES), .TX_FIFO_BYTES(TX_FIFO_BYTES)
    ) dut (
        .sys_clk(sys_clk), .sample_clk(sample_clk), .rst(rst),
        .adc_data(adc_data), .adc_otr(adc_otr), .test_pattern(TEST_PATTERN != 0),
        .tx_enable(tx_enable), .mii_tx_clk(tx_clk), .mii_rx_clk(rx_clk),
        .mii_rxd(4'd0), .mii_rx_dv(1'b0), .mii_rx_er(1'b0),
        .mii_txd(txd), .mii_tx_en(tx_en), .mii_tx_er(tx_er),
        .dropped_blocks(dropped_blocks), .tx_underflow(tx_underflow), .tx_packet(tx_packet)
    );
    // Independent deterministic AD9226 output model, driven before capture.
    // Read the source's raw cycle index solely to align the declared warmup;
    // payload expectations are recomputed independently from packet metadata.
    always @(negedge sample_clk) begin
        adc_data = dut.adc_source.raw_index[11:0] ^ 12'h5a5;
        adc_otr = dut.adc_source.raw_index[5];
    end
    integer fd, byte_count = 0, frame_count = 0;
    logic low_nibble = 1;
    logic [3:0] saved_nibble;
    logic previous_en = 0;
    integer ifg_nibbles = 100;
    string output_path;
    initial begin
        if (!$value$plusargs("OUTPUT=%s", output_path)) output_path = "frames.hex";
        fd = $fopen(output_path, "w");
        if (!fd) $fatal(1, "Cannot open frame capture");
        repeat (25) @(negedge sys_clk);
        rst = 0;
        repeat (HOLD_TX_CYCLES) @(negedge sys_clk);
        tx_enable = 1;
        if (RESET_DURING_FRAME) begin
            wait (tx_en);
            repeat (50) @(negedge sys_clk);
            rst = 1;
            repeat (25) @(negedge sys_clk);
            rst = 0;
        end
    end
    // MII is sampled opposite the launching edge, after signal settling.
    // Preserve preamble + SFD + complete frame + FCS for the Python checker.
    always @(negedge tx_clk) begin
        if (rst) begin
            if (byte_count != 0) $fwrite(fd, " RESET\n");
            byte_count = 0;
            previous_en = 0;
            low_nibble = 1;
            ifg_nibbles = 100;
        end else begin
            if (tx_er || tx_underflow) $fatal(1, "MAC signalled transmit error/underflow");
            if (tx_en) begin
                if (!previous_en && ifg_nibbles < 24)
                    $fatal(1, "Ethernet interframe gap below 96 bit times");
                ifg_nibbles = 0;
                if (low_nibble) saved_nibble = txd;
                else begin
                    $fwrite(fd, "%02x", {txd, saved_nibble});
                    byte_count = byte_count + 1;
                end
                low_nibble = !low_nibble;
            end else begin
                ifg_nibbles = ifg_nibbles + 1;
                if (previous_en) begin
                    if (!low_nibble) $fatal(1, "Odd MII nibble count");
                    $fwrite(fd, "\n");
                    byte_count = 0;
                    frame_count = frame_count + 1;
                    if (frame_count == TARGET_FRAMES) begin
                        $fclose(fd);
                        $display("PASS frames=%0d dropped_blocks=%0d", frame_count, dropped_blocks);
                        $finish;
                    end
                end
            end
            previous_en = tx_en;
        end
    end
    initial begin
        #20000000;
        $fatal(1, "Timeout waiting for complete Ethernet frames");
    end
endmodule
