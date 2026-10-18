//=============================================================================
// Module: rptr_empty
// Description: Read Pointer & Empty Flag Generator for Asynchronous FIFO.
//              - Operates purely within the rclk domain.
//              - Converts binary read pointer to Gray code before transmitting
//                across clock domain boundary to prevent multi-bit CDC skew.
//              - Generates conservative (pessimistic) empty flag by comparing
//                next read Gray pointer with synchronized write Gray pointer.
//=============================================================================

`timescale 1ns / 1ps

module rptr_empty #(
    parameter ADDRSIZE = 4
)(
    input                     rclk,        // Read clock
    input                     rrst_n,      // Active-low read reset
    input                     rinc,        // Read enable / increment
    input      [ADDRSIZE:0]   rq2_wptr,    // Synchronized write pointer from wclk domain
    output reg                rempty,      // FIFO empty status flag
    output     [ADDRSIZE-1:0] raddr,       // Binary read address to memory array
    output reg [ADDRSIZE:0]   rptr         // Gray-coded read pointer to wclk domain
);

    reg  [ADDRSIZE:0] rbin;
    wire [ADDRSIZE:0] rbin_next;
    wire [ADDRSIZE:0] rgray_next;
    wire              rempty_val;

    // 1. Memory read address is lower ADDRSIZE bits of binary counter
    assign raddr = rbin[ADDRSIZE-1:0];

    // 2. Increment binary read pointer only when read is requested and FIFO is not empty
    assign rbin_next = rbin + (rinc & ~rempty);

    // 3. Binary-to-Gray pointer conversion:
    //    Guarantees only one bit toggles per adjacent pointer increment
    assign rgray_next = (rbin_next >> 1) ^ rbin_next;

    // 4. Empty condition generation:
    //    FIFO is empty when next read Gray pointer matches synchronized write Gray pointer
    assign rempty_val = (rgray_next == rq2_wptr);

    // 5. Register updates on rclk
    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin   <= {(ADDRSIZE+1){1'b0}};
            rptr   <= {(ADDRSIZE+1){1'b0}};
            rempty <= 1'b1; // FIFO starts EMPTY after reset
        end else begin
            rbin   <= rbin_next;
            rptr   <= rgray_next;
            rempty <= rempty_val;
        end
    end

endmodule
