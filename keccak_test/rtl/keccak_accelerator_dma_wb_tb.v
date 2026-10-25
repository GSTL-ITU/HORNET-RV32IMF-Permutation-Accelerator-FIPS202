`timescale 1ns/1ps

// Unit testbench for keccak_accelerator_dma_wb. A 4 KiB RAM model answers the DMA master
// one cycle after each accepted request and injects pseudo-random stalls (as the core does
// when it wins the memory port). Output RAM regions are dumped byte by byte to
// dma_out_rtl.hex; sw/dma_test.c computes the same sequence with the reference permutation.
//   1. ABSORB 300 B @ rate 136 (2 blocks + 28 B tail), CPU writes to the state while busy
//      (must be ignored), PIO padding, SQUEEZE 301 B (partial last word, sentinels after it)
//   2. ABSORB 336 B @ rate 168 (exact multiple), PIO padding, SQUEEZE 168 B
//   3. LOAD 200 B, PIO permutation, STORE 200 B, STORE 13 B (partial word)
//   4. Rejected commands (rate 0, unknown command) set DONE + ERROR
//   5. ABSORB 3 B (tail shorter than a word), PIO padding, SQUEEZE 32 B (SHA3-256 shaped)
module keccak_accelerator_dma_wb_tb();

    reg         wb_cyc_i;
    reg         wb_stb_i;
    reg         wb_we_i;
    reg  [31:0] wb_adr_i;
    reg  [31:0] wb_dat_i;
    reg  [ 3:0] wb_sel_i;
    wire        wb_stall_o;
    wire        wb_ack_o;
    wire [31:0] wb_dat_o;
    wire        wb_err_o;
    reg         wb_rst_i;
    reg         wb_clk_i;

    wire        dma_cyc_o;
    wire        dma_stb_o;
    wire        dma_we_o;
    wire [31:0] dma_adr_o;
    wire [31:0] dma_dat_o;
    wire [ 3:0] dma_sel_o;
    wire        dma_stall_i;
    reg         dma_ack_i;
    reg  [31:0] dma_dat_i;

    localparam BASE       = 32'h1000_9000;
    localparam EN_ADDR    = BASE + 32'h000;
    localparam DN_ADDR    = BASE + 32'h010;
    localparam XOR_ADDR   = BASE + 32'h120;
    localparam DMA_ADDR   = BASE + 32'h200;
    localparam DMA_LEN    = BASE + 32'h204;
    localparam DMA_RATE   = BASE + 32'h208;
    localparam DMA_CTRL   = BASE + 32'h20C;
    localparam DMA_STATUS = BASE + 32'h210;

    localparam CMD_ABSORB  = 32'd1;
    localparam CMD_SQUEEZE = 32'd2;
    localparam CMD_LOAD    = 32'd3;
    localparam CMD_STORE   = 32'd4;

    keccak_accelerator_dma_wb DUT (
        .wb_cyc_i(wb_cyc_i),
        .wb_stb_i(wb_stb_i),
        .wb_we_i(wb_we_i),
        .wb_adr_i(wb_adr_i),
        .wb_dat_i(wb_dat_i),
        .wb_sel_i(wb_sel_i),
        .wb_stall_o(wb_stall_o),
        .wb_ack_o(wb_ack_o),
        .wb_dat_o(wb_dat_o),
        .wb_err_o(wb_err_o),
        .wb_rst_i(wb_rst_i),
        .wb_clk_i(wb_clk_i),
        .dma_cyc_o(dma_cyc_o),
        .dma_stb_o(dma_stb_o),
        .dma_we_o(dma_we_o),
        .dma_adr_o(dma_adr_o),
        .dma_dat_o(dma_dat_o),
        .dma_sel_o(dma_sel_o),
        .dma_stall_i(dma_stall_i),
        .dma_ack_i(dma_ack_i),
        .dma_dat_i(dma_dat_i),
        .dma_err_i(1'b0)
    );

    always #5 wb_clk_i = ~wb_clk_i;

    // -------------------------------------------------------------------------
    // RAM model with pseudo-random stalls (about 1 in 4 cycles)
    // -------------------------------------------------------------------------
    reg [31:0] ram [0:1023];
    reg [15:0] lfsr;
    wire       dma_acc = dma_stb_o && !dma_stall_i;
    assign dma_stall_i = (lfsr[1:0] == 2'b00);

    always @(posedge wb_clk_i) begin
        if (wb_rst_i) begin
            lfsr      <= 16'hACE1;
            dma_ack_i <= 1'b0;
        end
        else begin
            lfsr      <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            dma_ack_i <= dma_acc && !dma_we_o;
            if (dma_acc) begin
                if (dma_we_o) begin
                    if (dma_sel_o[0]) ram[dma_adr_o[11:2]][ 7: 0] <= dma_dat_o[ 7: 0];
                    if (dma_sel_o[1]) ram[dma_adr_o[11:2]][15: 8] <= dma_dat_o[15: 8];
                    if (dma_sel_o[2]) ram[dma_adr_o[11:2]][23:16] <= dma_dat_o[23:16];
                    if (dma_sel_o[3]) ram[dma_adr_o[11:2]][31:24] <= dma_dat_o[31:24];
                end
                else
                    dma_dat_i <= ram[dma_adr_o[11:2]];
            end
        end
    end

    // -------------------------------------------------------------------------
    // CPU-side bus tasks
    // -------------------------------------------------------------------------
    task wb_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(posedge wb_clk_i);
            wb_adr_i = addr;
            wb_dat_i = data;
            wb_cyc_i = 1'b1;
            wb_stb_i = 1'b1;
            wb_we_i  = 1'b1;
            wb_sel_i = 4'hF;
            @(posedge wb_clk_i);
            while (!wb_ack_o) @(posedge wb_clk_i);
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
            wb_we_i  = 1'b0;
        end
    endtask

    task wb_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge wb_clk_i);
            wb_adr_i = addr;
            wb_cyc_i = 1'b1;
            wb_stb_i = 1'b1;
            wb_we_i  = 1'b0;
            wb_sel_i = 4'hF;
            @(posedge wb_clk_i);
            while (!wb_ack_o) @(posedge wb_clk_i);
            data     = wb_dat_o;
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
        end
    endtask

    reg [31:0] read_data;
    integer i;
    reg [31:0] msg_word;
    integer file_out;
    integer t_start;
    integer cycle;

    always @(posedge wb_clk_i) cycle = cycle + 1;

    task dma_wait;
        begin
            read_data = 32'h0;
            while (read_data[0] != 1'b1)
                wb_read(DMA_STATUS, read_data);
            if (read_data[2])
                $display("ERROR: DMA reported an error");
        end
    endtask

    task dma_run;
        input [31:0] cmd;
        input [31:0] addr;
        input [31:0] len;
        begin
            wb_write(DMA_ADDR, addr);
            wb_write(DMA_LEN, len);
            t_start = cycle;
            wb_write(DMA_CTRL, cmd);
            dma_wait();
            $display("[%0t]   cmd %0d, %0d bytes: %0d cycles", $time, cmd, len, cycle - t_start);
        end
    endtask

    task acc_permute;
        begin
            wb_write(EN_ADDR, 32'h1);
            read_data = 32'h0;
            while (read_data[0] != 1'b1)
                wb_read(DN_ADDR, read_data);
        end
    endtask

    task dump_bytes;
        input [31:0] addr;
        input integer len;
        begin
            for (i = 0; i < len; i = i + 1)
                $fdisplay(file_out, "%02h", ram[(addr + i) >> 2][8 * ((addr + i) & 3) +: 8]);
        end
    endtask

    initial begin
        // Message bytes msg[i] = 7*i + 3 at 0x000-0x3FF, sentinel 0xA5 everywhere else
        for (i = 0; i < 1024; i = i + 1)
            ram[i] = 32'hA5A5_A5A5;
        for (i = 0; i < 1024; i = i + 1) begin
            msg_word = 7 * i + 3;
            ram[i >> 2][8 * (i & 3) +: 8] = msg_word[7:0];
        end

        file_out = $fopen("../dma_out_rtl.hex", "w");
        if (file_out == 0) begin
            $display("ERROR: Could not open output file (rtl)!");
            $finish;
        end

        cycle    = 0;
        wb_clk_i = 0;
        wb_rst_i = 1;
        wb_cyc_i = 0;
        wb_stb_i = 0;
        wb_we_i  = 0;
        wb_adr_i = 0;
        wb_dat_i = 0;
        wb_sel_i = 0;

        #20;
        wb_rst_i = 0;
        #20;

        // 1. SHAKE256-shaped: multi-block absorb with tail, CPU interference, long squeeze
        $display("[%0t] Test 1: ABSORB 300 B, SQUEEZE 301 B (rate 136)", $time);
        wb_write(EN_ADDR, 32'h2);
        wb_write(DMA_RATE, 32'd136);
        wb_write(DMA_ADDR, 32'h000);
        wb_write(DMA_LEN, 32'd300);
        t_start = cycle;
        wb_write(DMA_CTRL, CMD_ABSORB);
        wb_write(XOR_ADDR, 32'hFFFF_FFFF);          // ignored while busy
        wb_read(DN_ADDR, read_data);                 // reads 0 while busy
        if (read_data != 32'h0)
            $display("ERROR: inner register visible while DMA busy");
        wb_read(DMA_STATUS, read_data);
        if (read_data[1] != 1'b1)
            $display("ERROR: DMA BUSY not reported");
        dma_wait();
        $display("[%0t]   cmd 1, 300 bytes: %0d cycles", $time, cycle - t_start);
        wb_write(XOR_ADDR + 4 * 7,  32'h0000_001F);  // pad byte 28
        wb_write(XOR_ADDR + 4 * 33, 32'h8000_0000);  // pad byte 135
        dma_run(CMD_SQUEEZE, 32'h800, 32'd301);
        dump_bytes(32'h800, 304);

        // 2. SHAKE128-shaped: input is an exact multiple of the rate
        $display("[%0t] Test 2: ABSORB 336 B, SQUEEZE 168 B (rate 168)", $time);
        wb_write(EN_ADDR, 32'h2);
        wb_write(DMA_RATE, 32'd168);
        dma_run(CMD_ABSORB, 32'h000, 32'd336);
        wb_write(XOR_ADDR + 4 * 0,  32'h0000_001F);  // pad byte 0
        wb_write(XOR_ADDR + 4 * 41, 32'h8000_0000);  // pad byte 167
        dma_run(CMD_SQUEEZE, 32'hA00, 32'd168);
        dump_bytes(32'hA00, 168);

        // 3. LOAD / permute / STORE
        $display("[%0t] Test 3: LOAD 200 B, permute, STORE 200 B and 13 B", $time);
        dma_run(CMD_LOAD, 32'h100, 32'd200);
        acc_permute();
        dma_run(CMD_STORE, 32'hC00, 32'd200);
        dma_run(CMD_STORE, 32'hD00, 32'd13);
        dump_bytes(32'hC00, 200);
        dump_bytes(32'hD00, 16);

        // 4. Rejected commands
        $display("[%0t] Test 4: rejected commands", $time);
        wb_write(DMA_RATE, 32'd0);
        wb_write(DMA_CTRL, CMD_ABSORB);
        wb_read(DMA_STATUS, read_data);
        if (read_data != 32'h5)
            $display("ERROR: rate 0 not rejected (status %08h)", read_data);
        wb_write(DMA_RATE, 32'd136);
        wb_write(DMA_CTRL, 32'd7);
        wb_read(DMA_STATUS, read_data);
        if (read_data != 32'h5)
            $display("ERROR: unknown command not rejected (status %08h)", read_data);

        // 5. SHA3-256-shaped: 3-byte message
        $display("[%0t] Test 5: ABSORB 3 B, SQUEEZE 32 B (rate 136)", $time);
        wb_write(EN_ADDR, 32'h2);
        dma_run(CMD_ABSORB, 32'h000, 32'd3);
        wb_read(DMA_STATUS, read_data);
        if (read_data != 32'h1)
            $display("ERROR: error flag not cleared by a valid command (status %08h)", read_data);
        wb_write(XOR_ADDR + 4 * 0,  32'h0600_0000);  // pad byte 3
        wb_write(XOR_ADDR + 4 * 33, 32'h8000_0000);  // pad byte 135
        dma_run(CMD_SQUEEZE, 32'hE00, 32'd32);
        dump_bytes(32'hE00, 36);

        $fclose(file_out);
        $display("[%0t] Finished writing file and file closed.", $time);

        #100;
        $finish;
    end

endmodule
