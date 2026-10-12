// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
`default_nettype none

// Board-independent AD9226 stream formatter. The caller must register the
// parallel ADC bus on a board-qualified capture edge before this module.
// Output is deliberately non-backpressurable; connect to a frame FIFO with
// DROP_WHEN_FULL=1 so overload discards complete acquisition blocks.
module ad9226_frame_source #(
    parameter integer DECIMATION = 16,
    parameter integer SAMPLES_PER_PACKET = 512,
    parameter integer WARMUP_CYCLES = 10
)(
    input wire clk,
    input wire rst,
    input wire [11:0] adc_data,
    input wire adc_otr,
    input wire test_pattern,
    output logic [31:0] data,
    output logic valid,
    output logic last
);
    localparam integer DW = $clog2(DECIMATION);
    localparam integer SW = $clog2(SAMPLES_PER_PACKET+1);
    localparam integer WW = $clog2(WARMUP_CYCLES+1);
    logic [DW-1:0] decimation_count = '0;
    logic [SW-1:0] sample_count = '0;
    logic [WW-1:0] warmup_count = '0;
    logic [31:0] raw_index = 0, block_sequence = 0;
    logic [31:0] frame_sequence = 0, first_index = 0;
    logic [15:0] first_sample = 0;
    logic frame_open = 0;
    logic [2:0] header_step = 0;
    wire [15:0] sample_word = {2'b00, test_pattern,
        adc_otr && !test_pattern, test_pattern ? raw_index[11:0] : adc_data};

    initial begin
        if (DECIMATION < 8 || DECIMATION > 65535)
            $fatal(1, "DECIMATION must be 8..65535 (header scheduling needs spare cycles)");
        if (SAMPLES_PER_PACKET < 2 || SAMPLES_PER_PACKET > 720 || SAMPLES_PER_PACKET % 2)
            $fatal(1, "SAMPLES_PER_PACKET must be even, 2..720 (IPv4 MTU 1500)");
        if (WARMUP_CYCLES < 1) $fatal(1, "WARMUP_CYCLES must be positive");
    end

    always @(posedge clk) begin
        if (rst) begin
            data <= 0;
            valid <= 0;
            last <= 0;
            decimation_count <= 0;
            sample_count <= 0;
            warmup_count <= 0;
            raw_index <= 0;
            block_sequence <= 0;
            frame_sequence <= 0;
            first_index <= 0;
            first_sample <= 0;
            frame_open <= 0;
            header_step <= 0;
        end else begin
            valid <= 0;
            last <= 0;
            if (warmup_count != WARMUP_CYCLES) begin
                warmup_count <= warmup_count + 1'b1;
            end else begin
                raw_index <= raw_index + 1'b1;
                if (header_step != 0) begin
                    valid <= 1;
                    case (header_step)
                        1: data <= 32'h41443236; // ASCII "AD26"
                        2: data <= frame_sequence;
                        3: data <= first_index;
                        4: data <= {16'(DECIMATION), 16'(SAMPLES_PER_PACKET)};
                        default: data <= 0;
                    endcase
                    header_step <= header_step == 4 ? 0 : header_step + 1'b1;
                end
                if (decimation_count == DECIMATION-1)
                    decimation_count <= 0;
                else
                    decimation_count <= decimation_count + 1'b1;

                if (decimation_count == 0) begin
                    if (!frame_open) begin
                        frame_open <= 1;
                        frame_sequence <= block_sequence;
                        block_sequence <= block_sequence + 1'b1;
                        first_index <= raw_index;
                        first_sample <= sample_word;
                        sample_count <= 1;
                        header_step <= 1;
                    end else if (sample_count[0]) begin
                        data <= {first_sample, sample_word};
                        valid <= 1;
                        sample_count <= sample_count + 1'b1;
                        if (sample_count == SAMPLES_PER_PACKET-1) begin
                            last <= 1;
                            frame_open <= 0;
                            sample_count <= 0;
                        end
                    end else begin
                        first_sample <= sample_word;
                        sample_count <= sample_count + 1'b1;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
