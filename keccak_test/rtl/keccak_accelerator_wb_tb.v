`timescale 1ns/1ps

// Unit testbench for keccak_accelerator_wb. Writes one 25-lane state per test case to
// test_data_out_rtl.hex; sw/test.c computes the same sequence with the reference C code.
//   1. legacy flow: load via STATE, start, poll DONE, read back      -> P(in)
//   2-4. back-to-back permutations on the resident state             -> P^2(in) .. P^4(in)
//   5. CLEAR command, permute the zero state                         -> P(0)
//   6. CLEAR, absorb via XOR window (mixed byte-enable writes)       -> P(in)
//   7. XOR in again, attempt a STATE write while busy (must be ignored) -> P(P(in) ^ in)
module keccak_accelerator_wb_tb();

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

    localparam EN_ADDR  = 32'h1000_9000;
    localparam DN_ADDR  = 32'h1000_9010;
    localparam ST_ADDR  = 32'h1000_9020;
    localparam XOR_ADDR = 32'h1000_9120;

    keccak_accelerator_wb DUT (
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
        .wb_clk_i(wb_clk_i)
    );

    always #5 wb_clk_i = ~wb_clk_i;

    task wb_write_sel;
        input [31:0] addr;
        input [31:0] data;
        input [ 3:0] sel;
        begin
            @(posedge wb_clk_i);
            wb_adr_i = addr;
            wb_dat_i = data;
            wb_cyc_i = 1'b1;
            wb_stb_i = 1'b1;
            wb_we_i  = 1'b1;
            wb_sel_i = sel;
            @(posedge wb_clk_i);
            while (!wb_ack_o) @(posedge wb_clk_i);
            wb_cyc_i = 1'b0;
            wb_stb_i = 1'b0;
            wb_we_i  = 1'b0;
        end
    endtask

    task wb_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            wb_write_sel(addr, data, 4'hF);
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
    reg [31:0] low_word, high_word;
    reg [63:0] file_state [0:24];
    integer i, k;
    integer file_out;
    integer cycles;

    task wait_done;
        begin
            read_data = 32'h0;
            while (read_data[0] != 1'b1)
                wb_read(DN_ADDR, read_data);
        end
    endtask

    task permute;
        begin
            cycles = 0;
            wb_write(EN_ADDR, 32'h0000_0001);
            wait_done();
        end
    endtask

    task dump_state;
        begin
            for (i = 0; i < 25; i = i + 1) begin
                wb_read(ST_ADDR + (i * 8),     low_word);
                wb_read(ST_ADDR + (i * 8) + 4, high_word);
                $fdisplay(file_out, "%08h%08h", high_word, low_word);
            end
        end
    endtask

    // Absorb file_state through the XOR window: low words as full-word writes,
    // high words as four single-byte writes to exercise wb_sel_i.
    task xor_in_file_state;
        begin
            for (i = 0; i < 25; i = i + 1) begin
                wb_write(XOR_ADDR + (i * 8), file_state[i][31:0]);
                for (k = 0; k < 4; k = k + 1)
                    wb_write_sel(XOR_ADDR + (i * 8) + 4,
                                 file_state[i][63:32] & (32'hFF << (8 * k)), 4'b0001 << k);
            end
        end
    endtask

    always @(posedge wb_clk_i) if (DUT.busy) cycles = cycles + 1;

    initial begin
        $readmemh("../test_data_in.hex", file_state);

        file_out = $fopen("../test_data_out_rtl.hex", "w");
        if (file_out == 0) begin
            $display("ERROR: Could not open output file (rtl)!");
            $finish;
        end

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

        // 1. Legacy driver flow
        $display("[%0t] Test 1: load state, permute, read back", $time);
        wb_write(DN_ADDR, 32'h0000_0000);
        wb_write(EN_ADDR, 32'h0000_0000);
        for (i = 0; i < 25; i = i + 1) begin
            wb_write(ST_ADDR + (i * 8),     file_state[i][31:0 ]);
            wb_write(ST_ADDR + (i * 8) + 4, file_state[i][63:32]);
        end
        permute();
        $display("[%0t] Permutation took %0d cycles", $time, cycles);
        dump_state();

        // 2-4. Back-to-back on the resident state
        for (k = 2; k <= 4; k = k + 1) begin
            $display("[%0t] Test %0d: back-to-back permutation", $time, k);
            permute();
            dump_state();
        end

        // 5. Clear command
        $display("[%0t] Test 5: clear + permute zero state", $time);
        wb_write(EN_ADDR, 32'h0000_0002);
        permute();
        dump_state();

        // 6. Clear + absorb through XOR window
        $display("[%0t] Test 6: clear + XOR-absorb + permute", $time);
        wb_write(EN_ADDR, 32'h0000_0002);
        xor_in_file_state();
        permute();
        dump_state();

        // 7. XOR again, then try to corrupt the state while busy
        $display("[%0t] Test 7: XOR-absorb + permute, STATE write while busy", $time);
        xor_in_file_state();
        wb_write(EN_ADDR, 32'h0000_0001);
        wb_read(DN_ADDR, read_data);
        if (read_data[1] != 1'b1)
            $display("ERROR: BUSY not reported during permutation");
        wb_write(ST_ADDR, 32'hDEAD_BEEF);
        wb_write(XOR_ADDR, 32'hDEAD_BEEF);
        wb_write(EN_ADDR, 32'h0000_0003);
        wait_done();
        dump_state();

        // Unmapped address reads as zero
        wb_read(32'h1000_9800, read_data);
        if (read_data != 32'h0)
            $display("ERROR: unmapped read returned %08h", read_data);

        $fclose(file_out);
        $display("[%0t] Finished writing file and file closed.", $time);

        #100;
        $finish;
    end

endmodule
