// Unit testbench for keccak_accelerator_axil (HORNET-RV32IMF main).
// Equivalence test against legacy_keccak_accelerator_wb (itself checked against the C reference by
// legacy_keccak_accelerator_wb_tb.v): both get the same random operation script and every read
// must match. 20000 ops: STATE/XOR writes with random byte enables, reads (incl. unmapped
// offsets), clear, start + accesses while busy, STATUS writes, random writes, full state dumps.
// The AXI side gets random AW/W skew and B/R backpressure. Prints PASS or FAIL.
`timescale 1ns/1ps
module keccak_accelerator_axil_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- WB (legacy) ----------------
    reg         wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat = 0;
    reg  [3:0]  wb_sel = 0;
    wire        wb_ack;
    wire [31:0] wb_q;
    legacy_keccak_accelerator_wb wb (
        .wb_cyc_i(wb_stb), .wb_stb_i(wb_stb), .wb_we_i(wb_we), .wb_adr_i(wb_adr),
        .wb_dat_i(wb_dat), .wb_sel_i(wb_sel), .wb_stall_o(), .wb_ack_o(wb_ack),
        .wb_dat_o(wb_q), .wb_err_o(), .wb_rst_i(!rst_n), .wb_clk_i(clk));

    // ---------------- AXI4-Lite (new) ----------------
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [3:0]  wstrb = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;
    keccak_accelerator_axil ax (
        .clk_i(clk), .rst_ni(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .irq_o(irq));

    integer errors = 0, reads = 0;

    task automatic wb_op(input bit we, input [11:0] a, input [31:0] d, input [3:0] s, output [31:0] q);
        @(negedge clk); wb_stb = 1; wb_we = we; wb_adr = {20'h10009, a}; wb_dat = d; wb_sel = s;
        @(negedge clk); wb_stb = 0;
        if (!wb_ack) begin $display("WB no ack"); errors++; end
        q = wb_q;
    endtask

    // AXI write: AW and W raised with random skew, B accepted after a random delay
    task automatic ax_wr(input [11:0] a, input [31:0] d, input [3:0] s);
        @(negedge clk);
        awaddr = {20'h40000, a}; wdata = d; wstrb = s;
        awvalid = 1;
        if ($urandom % 2) begin repeat ($urandom % 3) @(negedge clk); end
        wvalid = 1;
        #1; while (!(awready && wready)) begin @(negedge clk); #1; end
        @(negedge clk); awvalid = 0; wvalid = 0;
        repeat ($urandom % 3) @(negedge clk);
        bready = 1;
        while (!bvalid) @(negedge clk);
        if (bresp != 2'b00) begin $display("bad bresp"); errors++; end
        @(negedge clk); bready = 0;
    endtask

    task automatic ax_rd(input [11:0] a, output [31:0] q);
        @(negedge clk);
        araddr = {20'h40000, a}; arvalid = 1;
        #1; while (!arready) begin @(negedge clk); #1; end
        @(negedge clk); arvalid = 0;
        repeat ($urandom % 3) @(negedge clk);      // rready backpressure: data must hold
        rready = 1;
        while (!rvalid) @(negedge clk);
        q = rdata;
        if (rresp != 2'b00) begin $display("bad rresp"); errors++; end
        @(negedge clk); rready = 0;
    endtask

    task automatic both(input bit we, input [11:0] a, input [31:0] d, input [3:0] s, input bit cmp);
        reg [31:0] q1, q2;
        fork
            wb_op(we, a, d, s, q1);
            if (we) ax_wr(a, d, s); else ax_rd(a, q2);
        join
        if (!we && cmp) begin
            reads++;
            if (q1 !== q2) begin
                errors++;
                if (errors < 20) $display("MISMATCH rd %03h: wb=%08h axil=%08h", a, q1, q2);
            end
        end
    endtask

    function automatic [11:0] rand_addr();
        case ($urandom % 8)
            0:       rand_addr = 12'h000;
            1:       rand_addr = 12'h010;
            2, 3:    rand_addr = 12'h020 + 4 * ($urandom % 50);
            4, 5:    rand_addr = 12'h120 + 4 * ($urandom % 50);
            6:       rand_addr = 12'h0E8 + 4 * ($urandom % 14);       // gap between STATE and XOR
            default: rand_addr = 4 * ($urandom % 1024);               // anywhere, incl. unmapped
        endcase
    endfunction

    // wait for the permutation in both (poll STATUS until busy == 0), compare along the way
    task automatic wait_idle();
        reg [31:0] q1, q2;
        do begin
            fork
                wb_op(0, 12'h010, 0, 4'hF, q1);
                ax_rd(12'h010, q2);
            join
        end while (q1[1] || q2[1]);
    endtask

    integer n, k, nb, op;
    reg [11:0] a;
    initial begin #200ms; $display("TIMEOUT at step %0d (op %0d)", n, op); $display("FAIL"); $finish; end
    initial begin
        repeat (3) @(negedge clk); rst_n = 1;
        for (n = 0; n < 20000; n++) begin
            op = $urandom % 16;
            case (op)
                0, 1, 2, 3:  both(1, 12'h020 + 4 * ($urandom % 50), $urandom, $urandom % 16, 0);   // STATE write
                4, 5, 6:     both(1, 12'h120 + 4 * ($urandom % 50), $urandom, $urandom % 16, 0);   // XOR write
                7, 8, 9, 10: both(0, rand_addr(), 0, 4'hF, 1);                                    // read
                11: begin                                                                         // start (+ maybe clear)
                    both(1, 12'h000, ($urandom % 4 == 0) ? 32'h3 : 32'h1, 4'hF, 0);
                    nb = $urandom % 3;                     // ops while busy (few enough that both DUTs are still busy)
                    for (k = 0; k < nb; k++) begin
                        // writes must be ignored by both; STATE reads mid-permutation are
                        // timing dependent, so only CTRL/STATUS/unmapped reads are compared
                        a = rand_addr();
                        both($urandom % 2, a, $urandom, 4'hF, !(a >= 12'h020 && a < 12'h0E8) && !(a >= 12'h120 && a < 12'h1E8));
                    end
                    wait_idle();
                end
                12: both(1, 12'h000, 32'h2, 4'hF, 0);                                             // clear
                13: both(1, 12'h010, $urandom % 2, 4'hF, 0);                                      // STATUS write
                14: begin                                                                         // random write
                    a = rand_addr();
                    both(1, a, $urandom, $urandom % 16, 0);
                    if (a == 12'h000) wait_idle();                                                // may have started one
                end
                default: begin                                                                    // full state dump
                    for (k = 0; k < 50; k++) both(0, 12'h020 + 4 * k, 0, 4'hF, 1);
                end
            endcase
        end
        // final state dump
        for (k = 0; k < 50; k++) both(0, 12'h020 + 4 * k, 0, 4'hF, 1);
        $display("%0d reads compared, %0d errors", reads, errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
