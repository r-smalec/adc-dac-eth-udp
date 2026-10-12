// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
module tb_packetizer;
    parameter integer STALL = 0;
    logic clk = 0, rst = 1, send = 0, ready = 1;
    always #5 clk = !clk;
    wire [7:0] data;
    wire valid, last, busy, fifo_rd;
    integer fifo_pos = 0;
    wire [31:0] fifo_data = fifo_pos == 0 ? 32'h01234567 : 32'h89abcdef;
    fifo_to_udp dut (
        .my_MAC(48'h020000000001), .my_IP(32'hc0a80a02),
        .rcv_MAC(48'h020000000002), .rcv_IP(32'hc0a80a01), .dport(16'd5000),
        .send(send), .busy(busy), .max_words(12'd2), .clk(clk), .rst_p(rst),
        .fifo_av_words(12'd2), .fifo_din(fifo_data), .fifo_rd(fifo_rd),
        .fifo_empty(fifo_pos >= 2), .tx_data(data), .tx_valid(valid),
        .tx_last(last), .tx_ready(ready)
    );
    integer fd, cycles = 0, stall_remaining = 0;
    bit last_stalled = 0, held = 0;
    logic [7:0] held_data;
    logic held_last;
    string output_path;
    initial begin
        if (!$value$plusargs("OUTPUT=%s", output_path)) output_path = "packet.hex";
        fd = $fopen(output_path, "w");
        repeat (5) @(negedge clk);
        rst = 0;
        @(negedge clk); send = 1;
        @(negedge clk); send = 0;
    end
    always @(negedge clk) begin
        cycles = cycles + 1;
        if (STALL && !rst) begin
            if (last && valid && !last_stalled) begin
                last_stalled = 1;
                stall_remaining = 5;
            end
            if (stall_remaining > 0) begin
                ready = 0;
                stall_remaining = stall_remaining - 1;
            end else ready = cycles % 7 != 0 && cycles % 7 != 1;
        end
    end
    always @(posedge clk) if (!rst) begin
        if (held && (!valid || data != held_data || last != held_last))
            $fatal(1, "Ready/valid contract violated while stalled");
        held = valid && !ready;
        held_data = data;
        held_last = last;
        if (fifo_rd) fifo_pos <= fifo_pos + 1;
        if (valid && ready) begin
            $fwrite(fd, "%02x", data);
            if (last) begin
                $fwrite(fd, "\n");
                $fclose(fd);
                $display("PASS packetizer final-byte-stall=%0d", last_stalled);
                $finish;
            end
        end
    end
    initial begin #20000; $fatal(1, "Packetizer did not finish"); end
endmodule
