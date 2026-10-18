//=============================================================================
// Module: wptr_full
// Description: Write Pointer & Full Flag Generator for Asynchronous FIFO.
//              - Operates purely within the wclk domain.
//              - Converts binary write pointer to Gray code before transmitting
//                across clock domain boundary to prevent multi-bit CDC skew.
//              - Generates conservative (pessimistic) full flag by comparing
//                next write Gray pointer with synchronized read Gray pointer.
//              - Uses the Clifford Cummings full-detection equation:
//                MSB and 2nd MSB inverted, remaining LSBs identical.
//=============================================================================

`timescale 1ns / 1ps

module wptr_full #(
    parameter ADDRSIZE = 4
)(
    input                     wclk,        // Write clock
    input                     wrst_n,      // Active-low write reset
    input                     winc,        // Write enable / increment
    input      [ADDRSIZE:0]   wq2_rptr,    // Synchronized read pointer from rclk domain
    output reg                wfull,       // FIFO full status flag
    output     [ADDRSIZE-1:0] waddr,       // Binary write address to memory array
    output reg [ADDRSIZE:0]   wptr         // Gray-coded write pointer to rclk domain
);

    reg  [ADDRSIZE:0] wbin;
    wire [ADDRSIZE:0] wbin_next;
    wire [ADDRSIZE:0] wgray_next;
    wire              wfull_val;

    // 1. Memory write address is lower ADDRSIZE bits of binary counter
    assign waddr = wbin[ADDRSIZE-1:0];

    // 2. Increment binary write pointer only when write is requested and FIFO is not full
    assign wbin_next = wbin + (winc & ~wfull);

    // 3. Binary-to-Gray pointer conversion:
    //    Guarantees only one bit toggles per adjacent pointer increment
    assign wgray_next = (wbin_next >> 1) ^ wbin_next;

    // 4. Full condition generation (Clifford Cummings equation):
    //    Due to Gray code reflection, full occurs when:
    //    - MSB is inverted (~wq2_rptr[ADDRSIZE])
    //    - 2nd MSB is inverted (~wq2_rptr[ADDRSIZE-1])
    //    - All remaining LSBs are identical (wq2_rptr[ADDRSIZE-2:0])
    assign wfull_val = (wgray_next == {~wq2_rptr[ADDRSIZE:ADDRSIZE-1], wq2_rptr[ADDRSIZE-2:0]});

    // 5. Register updates on wclk
    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin  <= {(ADDRSIZE+1){1'b0}};
            wptr  <= {(ADDRSIZE+1){1'b0}};
            wfull <= 1'b0; // FIFO starts NOT FULL after reset
        end else begin
            wbin  <= wbin_next;
            wptr  <= wgray_next;
            wfull <= wfull_val;
        end
    end

endmodule
