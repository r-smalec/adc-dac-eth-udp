// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
`default_nettype none

// Arty A7 DP83848J setup, PHY address 1, Clause 22 at 1 MHz MDC.
// Advertise only 100BASE-TX full duplex, restart autonegotiation, then poll
// PHYSTS. Gate acquisition until link + autonegotiation + 100/full are valid.
module dp83848_init #(
    parameter integer MDC_HALF_CYCLES = 50,
    parameter integer RESET_CYCLES = 1000000,
    parameter integer SETTLE_CYCLES = 1000000,
    parameter integer POLL_CYCLES = 100000
)(
    input wire clk,
    input wire rst,
    input wire mdio_i,
    output wire mdio_o,
    output wire mdio_oe,
    output logic mdc = 0,
    output logic phy_reset_n = 0,
    output logic link_ready = 0,
    output logic [15:0] phy_status = 0
);
    logic [31:0] reset_count = 0, wait_count = 0;
    logic [15:0] divider = 0;
    logic [63:0] tx_bits = 0;
    logic [15:0] read_data = 0;
    logic [5:0] bit_index = 0;
    logic [1:0] phase = 0, next_phase = 0;
    logic busy = 0, read_transaction = 0, phy_ack = 0;
    (* ASYNC_REG = "TRUE" *) logic mdio_meta = 1, mdio_sync = 1;
    always @(posedge clk) begin
        mdio_meta <= mdio_i;
        mdio_sync <= mdio_meta;
    end
    assign mdio_o = tx_bits[63];
    assign mdio_oe = busy && (!read_transaction || bit_index < 46);

    always @(posedge clk) begin
        if (rst) begin
            reset_count <= 0;
            wait_count <= 0;
            divider <= 0;
            tx_bits <= 0;
            read_data <= 0;
            bit_index <= 0;
            phase <= 0;
            next_phase <= 0;
            busy <= 0;
            read_transaction <= 0;
            phy_ack <= 0;
            mdc <= 0;
            phy_reset_n <= 0;
            link_ready <= 0;
            phy_status <= 0;
        end else if (reset_count < RESET_CYCLES) begin
            reset_count <= reset_count + 1'b1;
        end else begin
            phy_reset_n <= 1;
            if (!busy) begin
                if ((phase == 0 && wait_count < SETTLE_CYCLES) ||
                    (phase == 3 && wait_count < POLL_CYCLES)) begin
                    wait_count <= wait_count + 1'b1;
                end else if (phase == 0) begin
                    phase <= 1;
                    wait_count <= 0;
                end else begin
                    busy <= 1;
                    bit_index <= 0;
                    divider <= 0;
                    mdc <= 0;
                    read_data <= 0;
                    phy_ack <= 0;
                    wait_count <= 0;
                    read_transaction <= phase == 3;
                    case (phase)
                        1: begin
                            tx_bits <= {32'hffffffff, 2'b01, 2'b01, 5'd1, 5'd4, 2'b10, 16'h0101};
                            next_phase <= 2;
                        end
                        2: begin
                            tx_bits <= {32'hffffffff, 2'b01, 2'b01, 5'd1, 5'd0, 2'b10, 16'h1200};
                            next_phase <= 3;
                        end
                        default: begin
                            tx_bits <= {32'hffffffff, 2'b01, 2'b10, 5'd1, 5'd16, 2'b11, 16'hffff};
                            next_phase <= 3;
                        end
                    endcase
                end
            end else if (divider == MDC_HALF_CYCLES-1) begin
                divider <= 0;
                mdc <= !mdc;
                // PHY read data may change after the rising MDC edge.
                // Sample on the falling edge, after the full half-period.
                if (mdc && read_transaction && bit_index == 47) phy_ack <= !mdio_sync;
                if (mdc && read_transaction && bit_index >= 48)
                    read_data <= {read_data[14:0], mdio_sync};
                if (mdc && bit_index == 63) begin
                    busy <= 0;
                    phase <= next_phase;
                    if (read_transaction) begin
                        phy_status <= {read_data[14:0], mdio_sync};
                        link_ready <= phy_ack && (({read_data[14:0], mdio_sync} & 16'h0017) == 16'h0015);
                    end
                end else if (mdc) begin
                    bit_index <= bit_index + 1'b1;
                    tx_bits <= {tx_bits[62:0], 1'b1};
                end
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
