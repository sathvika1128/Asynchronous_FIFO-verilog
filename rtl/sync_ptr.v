//=============================================================================
// Module: sync_ptr
// Description: Generic 2-Stage Flip-Flop Synchronizer for Clock Domain Crossing.
//              - Mitigates metastability by providing settling time for
//                metastable voltages to resolve before sampling.
//              - Uses Xilinx Vivado (* ASYNC_REG = "TRUE" *) attribute to ensure
//                both registers are placed in the same slice, minimizing routing
//                delay and maximizing Mean Time Between Failures (MTBF).
//=============================================================================

`timescale 1ns / 1ps

module sync_ptr #(
    parameter ADDRSIZE = 4
)(
    input                     dest_clk,     // Destination clock domain
    input                     dest_rst_n,   // Active-low destination reset
    input      [ADDRSIZE:0]   src_ptr,      // Asynchronous Gray pointer from source domain
    output     [ADDRSIZE:0]   dest_ptr      // Synchronized Gray pointer in destination domain
);

    // Xilinx Vivado attribute for CDC synchronizer registers
    (* ASYNC_REG = "TRUE" *) reg [ADDRSIZE:0] sync_stage1;
    (* ASYNC_REG = "TRUE" *) reg [ADDRSIZE:0] sync_stage2;

    always @(posedge dest_clk or negedge dest_rst_n) begin
        if (!dest_rst_n) begin
            sync_stage1 <= {(ADDRSIZE+1){1'b0}};
            sync_stage2 <= {(ADDRSIZE+1){1'b0}};
        end else begin
            sync_stage1 <= src_ptr;      // Stage 1 captures asynchronous input
            sync_stage2 <= sync_stage1;  // Stage 2 provides resolved, synchronized output
        end
    end

    assign dest_ptr = sync_stage2;

endmodule
