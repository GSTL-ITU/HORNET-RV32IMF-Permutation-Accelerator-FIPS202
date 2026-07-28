`timescale 1ns/1ps

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

    localparam EN_ADDR = 32'h1000_9000;
    localparam DN_ADDR = 32'h1000_9010;
    localparam ST_ADDR = 32'h1000_9020;

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
    reg [63:0] file_state [0:24];
    integer i;
    integer file_out;

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

        $display("[%0t] -- Starting Keccak Permutation --", $time);

        // *keccak_dn_ptr = 0; *keccak_en_ptr = 0;
        wb_write(DN_ADDR, 32'h0000_0000);
        wb_write(EN_ADDR, 32'h0000_0000);

        $display("[%0t] Loading state data from 'test_data_in.hex'", $time);
        for (i = 0; i < 25; i = i + 1) begin
            wb_write(ST_ADDR + (i * 8),     file_state[i][31:0 ]);
            wb_write(ST_ADDR + (i * 8) + 4, file_state[i][63:32]);
            //$display("ST_ADDR: %d, file_state[%d][31:0 ]: %d", ST_ADDR + (i * 8),     i, file_state[i][31:0 ]);
            //$display("ST_ADDR: %d, file_state[%d][63:32]: %d", ST_ADDR + (i * 8) + 4, i, file_state[i][63:32]);
        end

        $display("[%0t] Activating hardware (EN = 1)...", $time);
        wb_write(EN_ADDR, 32'h0000_0001);

        // while (*keccak_dn_ptr != 1) { __asm__ volatile ("nop") }
        read_data = 32'h0;
        while (read_data[0] != 1'b1) begin
            #20;
            wb_read(DN_ADDR, read_data);
        end

        $display("[%0t] Hardware finished execution (DN = 1).", $time);
        for (i = 0; i < 25; i = i + 1) begin
            reg [31:0] low_word, high_word;
            wb_read(ST_ADDR + (i * 8),     low_word);
            wb_read(ST_ADDR + (i * 8) + 4, high_word);

            //if (i == 24) begin
            //$display("DEBUG: i=24 (Addr: 0x%h) -> High: 0x%h, Low: 0x%h", 
            //          ST_ADDR + (i * 8) + 4, high_word, low_word);
            //end

            $fdisplay(file_out, "%08h%08h", high_word, low_word);
        end

        $fclose(file_out);
        $display("[%0t] Finished writing file and file closed.", $time);

        #100;
        $finish;
    end
 
endmodule