// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
module tb_dp83848;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    wire mdc, mdio_o, mdio_oe, phy_rst_n, link_ready;
    wire [15:0] phy_status;
    logic phy_drive = 0, phy_bit = 1;
    wire mdio = mdio_oe ? mdio_o : (phy_drive ? phy_bit : 1'b1);
    logic [15:0] model_status = 0;
    bit model_ack = 1;
    dp83848_init #(.MDC_HALF_CYCLES(10), .RESET_CYCLES(20),
                   .SETTLE_CYCLES(20), .POLL_CYCLES(200)) dut (
        .clk(clk), .rst(rst), .mdio_i(mdio), .mdio_o(mdio_o), .mdio_oe(mdio_oe),
        .mdc(mdc), .phy_reset_n(phy_rst_n), .link_ready(link_ready), .phy_status(phy_status)
    );
    integer bit_pos = 0, writes = 0, reads = 0;
    logic [63:0] transaction = 0;
    bit read_op = 0;
    // PHY changes read data 30 ns after rising MDC, matching TI's maximum.
    always @(posedge mdc) begin
        transaction = {transaction[62:0], mdio};
        if (bit_pos == 45) begin
            if (transaction[45:14] != 32'hffffffff || transaction[13:12] != 2'b01 ||
                transaction[9:5] != 5'd1) $fatal(1, "Malformed Clause 22 management frame");
            read_op = transaction[11:10] == 2'b10;
        end
        if (read_op && bit_pos >= 46) begin
            #30;
            phy_drive = bit_pos != 46 && model_ack;
            if (bit_pos == 47) phy_bit = 0;
            else if (bit_pos >= 48) phy_bit = model_status[63-bit_pos];
        end
        if (bit_pos == 63) begin
            if (!read_op) begin
                if (transaction[17:16] != 2'b10) $fatal(1, "Bad write turnaround");
                if (writes == 0 && (transaction[22:18] != 4 || transaction[15:0] != 16'h0101))
                    $fatal(1, "ANAR must advertise 100/full only");
                if (writes == 1 && (transaction[22:18] != 0 || transaction[15:0] != 16'h1200))
                    $fatal(1, "BMCR must restart autonegotiation");
                writes = writes + 1;
            end else begin
                if (transaction[22:18] != 16) $fatal(1, "Expected PHYSTS read");
                reads = reads + 1;
            end
            bit_pos = 0;
        end else bit_pos = bit_pos + 1;
    end
    always @(negedge mdc) if (bit_pos == 0) phy_drive = 0;
    initial begin
        repeat (5) @(negedge clk); rst = 0;
        #100000;
        if (writes != 2 || reads < 2 || link_ready) $fatal(1, "Initial PHY setup failed");
        model_status = 16'h0011; // link + completed AN, half duplex
        #60000; if (link_ready) $fatal(1, "Half duplex must not enable acquisition");
        model_status = 16'h0017; // link + completed AN, 10/full
        #60000; if (link_ready) $fatal(1, "10 Mb/s must not enable acquisition");
        model_status = 16'h0015;
        #60000; if (!link_ready || phy_status != model_status) $fatal(1, "100/full link not accepted");
        model_ack = 0;
        #60000; if (link_ready) $fatal(1, "Missing PHY turnaround acknowledgement accepted");
        model_ack = 1; model_status = 0;
        #60000; if (link_ready) $fatal(1, "Link loss not propagated");
        $display("PASS MDIO writes=%0d reads=%0d link-gating/turnaround", writes, reads);
        $finish;
    end
    initial begin #600000; $fatal(1, "PHY test timeout"); end
endmodule
