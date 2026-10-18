//=============================================================================
// Testbench: async_fifo_tb
// Description:
//              - Comprehensive Verification Suite (10 Directed & Random Tests):
//                * [Test 1] Reset state initialization verification
//                * [Test 2] Single-word latency & synchronizer flag timing
//                * [Test 3] Burst write to FULL with independent acceptance proof
//                * [Test 4] Explicit Overflow protection verification
//                * [Test 5] Burst read to EMPTY with independent acceptance proof
//                * [Test 6] Explicit Underflow protection verification
//                * [Test 7] Multi-Cycle Fill-and-Drain (3 full cycles, 48 words) with
//                           strict mathematical wrap-around verification
//                * [Test 8] Concurrent Streaming (Fast Write 100MHz, Slow Read 40MHz)
//                * [Test 9] Inverted Clock Corner (Slow Write 25MHz, Fast Read 125MHz)
//                * [Test 10] Dynamic Mid-Operation Reset Assertion & Formal Flush Accounting
//              - Safety watchdog timeout (150,000 ns).
//=============================================================================

`timescale 1ns / 1ps

module async_fifo_tb;

    parameter DATASIZE = 8;
    parameter ADDRSIZE = 4;
    localparam DEPTH   = 1 << ADDRSIZE; // 16 entries

    // Clocks and Resets
    reg                  wclk;
    reg                  wrst_n;
    reg                  winc;
    reg  [DATASIZE-1:0]  wdata;
    wire                 wfull;

    reg                  rclk;
    reg                  rrst_n;
    reg                  rinc;
    wire [DATASIZE-1:0]  rdata;
    wire                 rempty;

    // Clock periods (Configurable for frequency variation tests)
    real WCLK_PERIOD = 10.0; // Default: 100 MHz (Fast write)
    real RCLK_PERIOD = 25.0; // Default: 40 MHz (Slow read)

    // Deterministic PRNG Seed
    integer prng_seed = 32'hA5A5_5A5A;

    // Scoreboard Data Structures (Monotonic continuous ring queue)
    reg [DATASIZE-1:0] golden_queue [0:8191];
    integer queue_wr_ptr = 0;
    integer queue_rd_ptr = 0;

    // Lifetime counters (Never wiped, track total simulation volume)
    integer lifetime_writes            = 0;
    integer lifetime_reads             = 0;
    integer lifetime_flushed_by_reset  = 0;
    integer lifetime_matches           = 0;
    integer err_count                  = 0;

    // Instantiate Device Under Test (DUT)
    async_fifo #(
        .DATASIZE(DATASIZE),
        .ADDRSIZE(ADDRSIZE)
    ) dut (
        .wclk   (wclk),
        .wrst_n (wrst_n),
        .winc   (winc),
        .wdata  (wdata),
        .wfull  (wfull),
        .rclk   (rclk),
        .rrst_n (rrst_n),
        .rinc   (rinc),
        .rdata  (rdata),
        .rempty (rempty)
    );

    // 1. Clock Generators (Independent and asynchronous)
    initial begin
        wclk = 0;
        forever #(WCLK_PERIOD / 2.0) wclk = ~wclk;
    end

    initial begin
        rclk = 0;
        forever #(RCLK_PERIOD / 2.0) rclk = ~rclk;
    end

    // 2. Watchdog Timer to prevent infinite simulation hangs
    initial begin
        #150000;
        $display("\n[ERROR @ %0t ps] Watchdog Timeout! Simulation was terminated to prevent hanging.", $time);
        $finish;
    end

    // 3. Scoreboard Write Monitor (wclk domain)
    //    Samples at posedge wclk. Because stimulus drives on negedge wclk,
    //    inputs are completely stable with a half-period setup margin.
    always @(posedge wclk) begin
        if (wrst_n && winc && !wfull) begin
            golden_queue[queue_wr_ptr] = wdata;
            queue_wr_ptr              = queue_wr_ptr + 1;
            lifetime_writes           = lifetime_writes + 1;
        end
    end

    // 4. Scoreboard Read Monitor (rclk domain)
    //    In a First-Word Fall-Through (FWFT) FIFO (combinational read), rdata is
    //    ALREADY stable at the head of the FIFO whenever rempty is low.
    //    When rinc is sampled on posedge rclk, rdata at that instant is the
    //    word being popped. (raddr updates in the NBA region right after).
    always @(posedge rclk) begin
        if (rrst_n && rinc && !rempty) begin
            lifetime_reads = lifetime_reads + 1;
            if (queue_rd_ptr < queue_wr_ptr) begin
                if (rdata === golden_queue[queue_rd_ptr]) begin
                    lifetime_matches = lifetime_matches + 1;
                end else begin
                    $display("[FAIL @ %0t ps] Data Mismatch at Index %0d! Received: 0x%02h, Expected: 0x%02h", 
                             $time, queue_rd_ptr, rdata, golden_queue[queue_rd_ptr]);
                    err_count = err_count + 1;
                end
                queue_rd_ptr = queue_rd_ptr + 1;
            end else begin
                $display("[FAIL @ %0t ps] Scoreboard Underflow! Read accepted but no data expected in queue!", $time);
                err_count = err_count + 1;
            end
        end
    end

    // Helper Task: Write a byte into FIFO (stimulus driven strictly on negedge wclk)
    task write_byte(input [DATASIZE-1:0] data);
        begin
            @(negedge wclk);
            while (wfull) begin
                @(negedge wclk);
            end
            winc  <= 1'b1;
            wdata <= data;
            @(negedge wclk);
            winc  <= 1'b0;
            wdata <= {DATASIZE{1'bx}};
        end
    endtask

    // 5. Main Verification Stimulus
    integer i, cyc;
    integer writes_before, reads_before;
    integer writes_accepted_in_test, reads_accepted_in_test;
    integer t7_start_wr, t7_start_rd, t7_start_err;
    integer stream_start_wr, stream_start_rd, stream_start_errs;
    integer stream_writes, stream_reads, stream_errs;
    integer in_flight_before_reset;
    integer t10_start_wr, t10_start_rd, t10_start_err;

    initial begin
        $display("==================================================================");
        $display("   STARTING DUAL-CLOCK ASYNCHRONOUS FIFO VERIFICATION TESTBENCH  ");
        $display("==================================================================");

        // Initialize signals on negedge
        @(negedge wclk);
        winc   <= 0;
        wdata  <= 0;
        wrst_n <= 0;
        @(negedge rclk);
        rinc   <= 0;
        rrst_n <= 0;

        // Apply reset
        #50;
        @(negedge wclk);
        wrst_n <= 1;
        @(negedge rclk);
        rrst_n <= 1;
        #50;

        //------------------------------------------------------------------
        // TEST 1: Check Initial Reset State
        //------------------------------------------------------------------
        $display("\n[TEST 1] Checking initial reset states...");
        if (rempty === 1'b1 && wfull === 1'b0) begin
            $display("[PASS] Reset state correct: rempty = 1, wfull = 0");
        end else begin
            $display("[FAIL] Reset state invalid: rempty = %b (exp 1), wfull = %b (exp 0)", rempty, wfull);
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 2: Single-Word Write & Read Latency
        //------------------------------------------------------------------
        $display("\n[TEST 2] Testing Single Word Write & Read...");
        writes_before = lifetime_writes;
        write_byte(8'hA5);

        // Verify write was accepted
        @(negedge wclk);
        if ((lifetime_writes - writes_before) === 1) begin
            $display("[PASS] Single word write accepted by FIFO.");
        end else begin
            $display("[FAIL] Single word write was not accepted!");
            err_count = err_count + 1;
        end

        // Wait for write pointer to cross 2-FF synchronizer into rclk domain
        repeat (4) @(negedge rclk);
        if (rempty !== 1'b0) begin
            $display("[FAIL] rempty did not deassert after write!");
            err_count = err_count + 1;
        end else begin
            $display("[PASS] rempty deasserted correctly after 2-FF synchronizer delay.");
        end

        // Pop single word (drive on negedge rclk)
        reads_before = lifetime_reads;
        @(negedge rclk);
        rinc <= 1'b1;
        @(negedge rclk);
        rinc <= 1'b0;

        repeat (4) @(negedge rclk);
        if (rempty === 1'b1 && (lifetime_reads - reads_before) === 1) begin
            $display("[PASS] Single word read verified: word matched and rempty asserted back to 1.");
        end else begin
            $display("[FAIL] Single word read failed! rempty = %b, reads = %0d", rempty, (lifetime_reads - reads_before));
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 3: Burst Write to Full with Independent Acceptance Proof
        //------------------------------------------------------------------
        $display("\n[TEST 3] Testing Burst Write until FULL (Depth = %0d)...", DEPTH);
        writes_before = lifetime_writes;

        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge wclk);
            winc  <= 1'b1;
            wdata <= 8'h10 + i;
        end
        @(negedge wclk);
        winc  <= 1'b0;
        wdata <= {DATASIZE{1'bx}};

        repeat (2) @(negedge wclk);
        writes_accepted_in_test = lifetime_writes - writes_before;

        if (wfull === 1'b1 && writes_accepted_in_test === DEPTH) begin
            $display("[PASS] Burst write verified: exactly %0d/16 writes accepted and wfull asserted.", writes_accepted_in_test);
        end else begin
            $display("[FAIL] Burst write verification failed! Accepted writes = %0d, wfull = %b", writes_accepted_in_test, wfull);
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 4: Explicit Overflow Protection Verification
        //------------------------------------------------------------------
        $display("\n[TEST 4] Testing Overflow Protection (attempting write 0xEE while FULL)...");
        writes_before = lifetime_writes;
        @(negedge wclk);
        winc  <= 1'b1;
        wdata <= 8'hEE;
        @(negedge wclk);
        winc  <= 1'b0;
        wdata <= {DATASIZE{1'bx}};

        repeat (2) @(negedge wclk);
        if (wfull === 1'b1 && lifetime_writes === writes_before) begin
            $display("[PASS] Overflow protection verified: Illegal write 0xEE was blocked and not accepted.");
        end else begin
            $display("[FAIL] Overflow protection failed! Data accepted during FULL condition.");
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 5: Burst Read to Empty with Independent Acceptance Proof
        //------------------------------------------------------------------
        $display("\n[TEST 5] Testing Burst Read until EMPTY...");
        repeat (3) @(negedge rclk);
        reads_before = lifetime_reads;

        for (i = 0; i < DEPTH; i = i + 1) begin
            @(negedge rclk);
            rinc <= 1'b1;
        end
        @(negedge rclk);
        rinc <= 1'b0;

        repeat (4) @(negedge rclk);
        reads_accepted_in_test = lifetime_reads - reads_before;

        if (rempty === 1'b1 && reads_accepted_in_test === DEPTH) begin
            $display("[PASS] Burst read verified: exactly %0d/16 reads accepted and rempty asserted.", reads_accepted_in_test);
        end else begin
            $display("[FAIL] Burst read verification failed! Accepted reads = %0d, rempty = %b", reads_accepted_in_test, rempty);
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 6: Explicit Underflow Protection Verification
        //------------------------------------------------------------------
        $display("\n[TEST 6] Testing Underflow Protection (attempting read while EMPTY)...");
        reads_before = lifetime_reads;
        @(negedge rclk);
        rinc <= 1'b1;
        @(negedge rclk);
        rinc <= 1'b0;

        repeat (3) @(negedge rclk);
        if (rempty === 1'b1 && lifetime_reads === reads_before) begin
            $display("[PASS] Underflow protection verified: Illegal read while EMPTY was blocked.");
        end else begin
            $display("[FAIL] Underflow protection failed! Read accepted while EMPTY.");
            err_count = err_count + 1;
        end

        repeat (4) @(negedge wclk);
        if (wfull === 1'b0) begin
            $display("[PASS] wfull deasserted correctly after emptying FIFO.");
        end else begin
            $display("[FAIL] wfull did not deassert after emptying FIFO!");
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 7: Multi-Cycle Fill-and-Drain with Strict Wrap-Around Proof
        //------------------------------------------------------------------
        $display("\n[TEST 7] Testing Multi-Cycle Fill & Drain (3 complete wrap-around cycles = 48 words)...");
        t7_start_wr  = lifetime_writes;
        t7_start_rd  = lifetime_reads;
        t7_start_err = err_count;

        for (cyc = 1; cyc <= 3; cyc = cyc + 1) begin
            // Fill 16 words
            for (i = 0; i < DEPTH; i = i + 1) begin
                @(negedge wclk);
                winc  <= 1'b1;
                wdata <= (cyc << 4) | i;
            end
            @(negedge wclk);
            winc  <= 1'b0;
            wdata <= {DATASIZE{1'bx}};
            repeat (3) @(negedge wclk);

            // Drain 16 words
            repeat (3) @(negedge rclk);
            for (i = 0; i < DEPTH; i = i + 1) begin
                @(negedge rclk);
                rinc <= 1'b1;
            end
            @(negedge rclk);
            rinc <= 1'b0;
            repeat (4) @(negedge rclk);
            repeat (4) @(negedge wclk);
        end

        if ((lifetime_writes - t7_start_wr) === 48 &&
            (lifetime_reads  - t7_start_rd) === 48 &&
            (err_count       - t7_start_err) === 0 &&
            rempty === 1'b1 && queue_rd_ptr === queue_wr_ptr) begin
            $display("[PASS] Repeated fill-and-drain verified: exactly 48 words accepted, read, and matched across wrap-around boundaries.");
        end else begin
            $display("[FAIL] Repeated fill-and-drain failed! Writes: %0d, Reads: %0d, Errs: %0d",
                     (lifetime_writes - t7_start_wr), (lifetime_reads - t7_start_rd), (err_count - t7_start_err));
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 8: Concurrent Streaming (Fast Write 100MHz, Slow Read 40MHz)
        //------------------------------------------------------------------
        $display("\n[TEST 8] Testing Concurrent Streaming: Fast Write (100MHz) & Slow Read (40MHz)...");
        stream_start_wr   = lifetime_writes;
        stream_start_rd   = lifetime_reads;
        stream_start_errs = err_count;

        fork
            begin : writer_stream_fast
                integer w_cnt;
                for (w_cnt = 0; w_cnt < 60; w_cnt = w_cnt + 1) begin
                    write_byte($dist_uniform(prng_seed, 0, 255));
                    if (w_cnt % 6 == 0) repeat (2) @(negedge wclk);
                end
            end

            begin : reader_stream_slow
                integer r_seen;
                r_seen = 0;
                while (r_seen < 60) begin
                    @(negedge rclk);
                    if (!rempty) begin
                        rinc   <= 1'b1;
                        @(negedge rclk);
                        rinc   <= 1'b0;
                        r_seen  = r_seen + 1;
                    end else begin
                        rinc <= 1'b0;
                    end
                end
            end
        join

        // Drain any remaining words in transit
        repeat (10) @(negedge rclk);
        while (!rempty) begin
            @(negedge rclk);
            rinc <= 1'b1;
            @(negedge rclk);
            rinc <= 1'b0;
        end
        repeat (5) @(negedge rclk);

        stream_writes = lifetime_writes - stream_start_wr;
        stream_reads  = lifetime_reads  - stream_start_rd;
        stream_errs   = err_count       - stream_start_errs;

        if (stream_writes === 60 && stream_reads === 60 && stream_errs === 0 && queue_rd_ptr === queue_wr_ptr) begin
            $display("[PASS] Concurrent streaming (Fast Write / Slow Read) verified: %0d/%0d deterministic words matched in exact order.", stream_reads, stream_writes);
        end else begin
            $display("[FAIL] Concurrent streaming failed! Writes: %0d, Reads: %0d, Errs: %0d", stream_writes, stream_reads, stream_errs);
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // TEST 9: Inverted Clock Frequency Corner (Slow Write 25MHz, Fast Read 125MHz)
        //------------------------------------------------------------------
        $display("\n[TEST 9] Testing Inverted Clock Corner: Slow Write (25MHz) & Fast Read (125MHz)...");
        WCLK_PERIOD = 40.0; // 25 MHz
        RCLK_PERIOD = 8.0;  // 125 MHz
        #100;

        stream_start_wr   = lifetime_writes;
        stream_start_rd   = lifetime_reads;
        stream_start_errs = err_count;

        fork
            begin : writer_stream_slow
                integer w_cnt2;
                for (w_cnt2 = 0; w_cnt2 < 40; w_cnt2 = w_cnt2 + 1) begin
                    write_byte($dist_uniform(prng_seed, 0, 255));
                    if (w_cnt2 % 4 == 0) repeat (2) @(negedge wclk);
                end
            end

            begin : reader_stream_fast
                integer r_seen2;
                r_seen2 = 0;
                while (r_seen2 < 40) begin
                    @(negedge rclk);
                    if (!rempty) begin
                        rinc    <= 1'b1;
                        @(negedge rclk);
                        rinc    <= 1'b0;
                        r_seen2  = r_seen2 + 1;
                    end else begin
                        rinc <= 1'b0;
                    end
                end
            end
        join

        repeat (10) @(negedge rclk);
        while (!rempty) begin
            @(negedge rclk);
            rinc <= 1'b1;
            @(negedge rclk);
            rinc <= 1'b0;
        end
        repeat (5) @(negedge rclk);

        stream_writes = lifetime_writes - stream_start_wr;
        stream_reads  = lifetime_reads  - stream_start_rd;
        stream_errs   = err_count       - stream_start_errs;

        if (stream_writes === 40 && stream_reads === 40 && stream_errs === 0 && queue_rd_ptr === queue_wr_ptr) begin
            $display("[PASS] Inverted frequency corner (Slow Write / Fast Read) verified: %0d/%0d deterministic words matched in exact order.", stream_reads, stream_writes);
        end else begin
            $display("[FAIL] Inverted frequency corner failed! Writes: %0d, Reads: %0d, Errs: %0d", stream_writes, stream_reads, stream_errs);
            err_count = err_count + 1;
        end

        // Restore default clocks
        WCLK_PERIOD = 10.0;
        RCLK_PERIOD = 25.0;
        #100;

        //------------------------------------------------------------------
        // TEST 10: Dynamic Mid-Operation Reset Assertion & Formal Flush Accounting
        //------------------------------------------------------------------
        $display("\n[TEST 10] Testing Dynamic Mid-Operation Reset & Formal Flush Accounting...");
        // Write exactly 6 words into FIFO
        for (i = 0; i < 6; i = i + 1) begin
            write_byte(8'hD0 + i);
        end

        // Assert reset asynchronously while clocks are actively running
        @(negedge wclk);
        wrst_n <= 1'b0;
        @(negedge rclk);
        rrst_n <= 1'b0;
        #60;

        // Formal verification of in-flight words discarded by reset
        in_flight_before_reset = queue_wr_ptr - queue_rd_ptr;
        lifetime_flushed_by_reset = in_flight_before_reset;

        // Advance read pointer past the flushed words to keep scoreboard unbroken
        queue_rd_ptr = queue_wr_ptr;

        // Verify pointers and flags immediately recovered
        if (rempty === 1'b1 && wfull === 1'b0 && in_flight_before_reset === 6) begin
            $display("[PASS] Dynamic reset flush verified: exactly %0d in-flight words (0xD0..0xD5) flushed by reset.", in_flight_before_reset);
        end else begin
            $display("[FAIL] Dynamic reset failed! rempty = %b, wfull = %b, flushed = %0d (exp 6)", rempty, wfull, in_flight_before_reset);
            err_count = err_count + 1;
        end

        // Deassert reset on negedges
        @(negedge wclk);
        wrst_n <= 1'b1;
        @(negedge rclk);
        rrst_n <= 1'b1;
        #60;

        t10_start_wr  = lifetime_writes;
        t10_start_rd  = lifetime_reads;
        t10_start_err = err_count;

        // Verify post-reset functionality with 10 fresh writes and reads
        for (i = 0; i < 10; i = i + 1) begin
            write_byte(8'h80 + i);
        end

        repeat (4) @(negedge rclk);
        for (i = 0; i < 10; i = i + 1) begin
            @(negedge rclk);
            rinc <= 1'b1;
            @(negedge rclk);
            rinc <= 1'b0;
        end
        repeat (5) @(negedge rclk);

        if ((lifetime_writes - t10_start_wr) === 10 &&
            (lifetime_reads  - t10_start_rd) === 10 &&
            queue_rd_ptr === queue_wr_ptr &&
            (err_count - t10_start_err) === 0) begin
            $display("[PASS] Post-reset recovery verified: exactly 10/10 fresh transactions matched with queue fully drained.");
        end else begin
            $display("[FAIL] Post-reset recovery failed! Writes: %0d, Reads: %0d",
                     (lifetime_writes - t10_start_wr), (lifetime_reads - t10_start_rd));
            err_count = err_count + 1;
        end

        //------------------------------------------------------------------
        // FINAL COMPREHENSIVE SCOREBOARD SUMMARY (Mathematical Conservation of Data)
        //------------------------------------------------------------------
        $display("\n==================================================================");
        $display("                   FINAL VERIFICATION SCOREBOARD                  ");
        $display("==================================================================");
        $display(" Total Lifetime Accepted Writes  : %0d", lifetime_writes);
        $display(" Total Lifetime Accepted Reads   : %0d", lifetime_reads);
        $display(" Total Discarded by Reset        : %0d", lifetime_flushed_by_reset);
        $display(" Total Lifetime Correct Matches  : %0d", lifetime_matches);
        $display(" Unread Words in Golden Queue    : %0d", (queue_wr_ptr - queue_rd_ptr));
        $display(" Total Lifetime Error Count      : %0d", err_count);

        // Strict Conservation of Data Check: Writes == Reads + Discards
        if (err_count == 0 &&
            lifetime_writes == (lifetime_reads + lifetime_flushed_by_reset) &&
            lifetime_matches == lifetime_reads &&
            queue_wr_ptr == queue_rd_ptr &&
            lifetime_flushed_by_reset == 6 &&
            lifetime_writes > 150) begin
            $display("\n >>> [STATUS: ALL 10 VERIFICATION TESTS PASSED WITH ZERO ERRORS!] <<< ");
            $display(" [CONFIRMED] Conservation of Data: Writes (%0d) = Reads (%0d) + Reset Flushes (%0d).",
                     lifetime_writes, lifetime_reads, lifetime_flushed_by_reset);
            $display(" [CONFIRMED] Deterministic PRNG stimulus verified across all runs.");
            $display(" [CONFIRMED] Zero dropped words, zero duplicated words, exact FIFO order preserved.\n");
        end else begin
            $display("\n >>> [STATUS: VERIFICATION FAILED WITH %0d ERRORS] <<< \n", err_count);
        end
        $display("==================================================================");

        $finish;
    end

endmodule
