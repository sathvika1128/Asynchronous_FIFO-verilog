//=============================================================================
// Module: fifo_mem
// Description: Dual-Port RAM Buffer for Asynchronous FIFO.
//              Synchronous write to wclk domain and combinational read
//              in rclk domain.
//=============================================================================

`timescale 1ns / 1ps

module fifo_mem #(
    parameter DATASIZE = 8,  // Width of data word
    parameter ADDRSIZE = 4   // Depth = 2^ADDRSIZE (e.g., 4 -> depth = 16)
)(
    input                   wclk,     // Write clock
    input                   wclken,   // Write clock enable (winc & !wfull)
    input  [ADDRSIZE-1:0]   waddr,    // Write address
    input  [DATASIZE-1:0]   wdata,    // Write data input
    input  [ADDRSIZE-1:0]   raddr,    // Read address
    output [DATASIZE-1:0]   rdata     // Read data output
);

    localparam DEPTH = 1 << ADDRSIZE;

    // Memory array
    reg [DATASIZE-1:0] mem [0:DEPTH-1];

    // Synchronous write
    always @(posedge wclk) begin
        if (wclken) begin
            mem[waddr] <= wdata;
        end
    end

    // Combinational read (data is immediately available at raddr)
    assign rdata = mem[raddr];

endmodule
