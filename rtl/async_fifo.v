//=============================================================================
// Module: async_fifo
// Description: Top-Level Parameterized Dual-Clock Asynchronous FIFO.
//              - Safely transfers data across unsynchronized clock domains.
//              - Binary-to-Gray pointer conversion prevents multi-bit CDC errors.
//              - 2-Stage Flip-Flop synchronizers mitigate metastability propagation.
//              - Pessimistic full and empty status flags prevent overflow/underflow.
//=============================================================================

`timescale 1ns / 1ps

module async_fifo #(
    parameter DATASIZE = 8,  // Data bus width in bits
    parameter ADDRSIZE = 4   // Address bus width (FIFO depth = 2^ADDRSIZE = 16)
)(
    // Write Domain (wclk)
    input                  wclk,      // Write clock
    input                  wrst_n,    // Active-low asynchronous write reset
    input                  winc,      // Write enable / increment
    input  [DATASIZE-1:0]  wdata,     // Write data input
    output                 wfull,     // FIFO full flag (synchronous to wclk)

    // Read Domain (rclk)
    input                  rclk,      // Read clock
    input                  rrst_n,    // Active-low asynchronous read reset
    input                  rinc,      // Read enable / increment
    output [DATASIZE-1:0]  rdata,     // Read data output
    output                 rempty     // FIFO empty flag (synchronous to rclk)
);

    // Internal interconnect wires
    wire [ADDRSIZE-1:0] waddr, raddr;
    wire [ADDRSIZE:0]   wptr, rptr;
    wire [ADDRSIZE:0]   wq2_rptr, rq2_wptr;

    // 1. Dual-Port Memory Array
    fifo_mem #(
        .DATASIZE(DATASIZE),
        .ADDRSIZE(ADDRSIZE)
    ) u_fifo_mem (
        .wclk   (wclk),
        .wclken (winc & ~wfull),
        .waddr  (waddr),
        .wdata  (wdata),
        .raddr  (raddr),
        .rdata  (rdata)
    );

    // 2. Synchronize Read Pointer into Write Domain (rclk -> wclk)
    sync_ptr #(
        .ADDRSIZE(ADDRSIZE)
    ) u_sync_r2w (
        .dest_clk   (wclk),
        .dest_rst_n (wrst_n),
        .src_ptr    (rptr),
        .dest_ptr   (wq2_rptr)
    );

    // 3. Synchronize Write Pointer into Read Domain (wclk -> rclk)
    sync_ptr #(
        .ADDRSIZE(ADDRSIZE)
    ) u_sync_w2r (
        .dest_clk   (rclk),
        .dest_rst_n (rrst_n),
        .src_ptr    (wptr),
        .dest_ptr   (rq2_wptr)
    );

    // 4. Read Pointer & Empty Flag Logic (rclk domain)
    rptr_empty #(
        .ADDRSIZE(ADDRSIZE)
    ) u_rptr_empty (
        .rclk     (rclk),
        .rrst_n   (rrst_n),
        .rinc     (rinc),
        .rq2_wptr (rq2_wptr),
        .rempty   (rempty),
        .raddr    (raddr),
        .rptr     (rptr)
    );

    // 5. Write Pointer & Full Flag Logic (wclk domain)
    wptr_full #(
        .ADDRSIZE(ADDRSIZE)
    ) u_wptr_full (
        .wclk     (wclk),
        .wrst_n   (wrst_n),
        .winc     (winc),
        .wq2_rptr (wq2_rptr),
        .wfull    (wfull),
        .waddr    (waddr),
        .wptr     (wptr)
    );

endmodule
