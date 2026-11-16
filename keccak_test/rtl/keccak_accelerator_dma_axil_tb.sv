// Unit testbench for keccak_accelerator_dma_axil (HORNET-RV32IMF main).
// Equivalence test against legacy_keccak_accelerator_dma_wb (itself checked against the C reference
// by legacy_keccak_accelerator_dma_wb_tb.v): same memory contents, same command script.
//   - 1500 random steps: LOAD/STORE 0..200 B, ABSORB/SQUEEZE 0..700 B with random rates, rejected
//     commands (unknown command, bad rate), register-path XOR writes / permutations, clear.
//   - WB side: pipelined RAM with 30 % random stalls. AXI side: random arready/awready/wready
//     (AW and W independent), in-order R/B with random latency, several transactions outstanding,
//     every third step with heavy backpressure. Valid/payload stability is checked every cycle.
//   - After every step STATUS, the DMA registers, the full state and all of memory must match.
//   - Then AXI-only error responses: ABSORB running off the end of memory, SQUEEZE / STORE to
//     unmapped addresses (DONE + ERROR, no hang), and a following LOAD that clears ERROR.
// Prints PASS or FAIL.
`timescale 1ns/1ps
module keccak_accelerator_dma_axil_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    localparam MEM_BASE  = 32'h1000_0000;
    localparam MEM_WORDS = 4096;                 // 16 KiB; addresses past it answer SLVERR (AXI side)

    reg [31:0] mem_wb [0:MEM_WORDS-1];
    reg [31:0] mem_ax [0:MEM_WORDS-1];

    // ======================= legacy (Wishbone) =======================
    reg         wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat = 0;
    reg  [3:0]  wb_sel = 0;
    wire        wb_ack;
    wire [31:0] wb_q;

    wire        d_cyc, d_stb, d_we;
    wire [31:0] d_adr, d_dat;
    wire [3:0]  d_sel;
    reg         d_stall = 0, d_ack = 0;
    reg  [31:0] d_rdat = 0;

    legacy_keccak_accelerator_dma_wb wb (
        .wb_cyc_i(wb_stb), .wb_stb_i(wb_stb), .wb_we_i(wb_we), .wb_adr_i(wb_adr),
        .wb_dat_i(wb_dat), .wb_sel_i(wb_sel), .wb_stall_o(), .wb_ack_o(wb_ack),
        .wb_dat_o(wb_q), .wb_err_o(), .wb_rst_i(!rst_n), .wb_clk_i(clk),
        .dma_cyc_o(d_cyc), .dma_stb_o(d_stb), .dma_we_o(d_we), .dma_adr_o(d_adr),
        .dma_dat_o(d_dat), .dma_sel_o(d_sel), .dma_stall_i(d_stall), .dma_ack_i(d_ack),
        .dma_dat_i(d_rdat), .dma_err_i(1'b0));

    // pipelined WB memory with random stalls, read ack one cycle after acceptance
    always @(posedge clk) begin
        d_ack <= 0;
        if (d_stb && !d_stall) begin
            integer w; w = (d_adr - MEM_BASE) >> 2;
            if (d_we) begin
                if (d_sel[0]) mem_wb[w][7:0]   <= d_dat[7:0];
                if (d_sel[1]) mem_wb[w][15:8]  <= d_dat[15:8];
                if (d_sel[2]) mem_wb[w][23:16] <= d_dat[23:16];
                if (d_sel[3]) mem_wb[w][31:24] <= d_dat[31:24];
            end
            else begin
                d_ack  <= 1;
                d_rdat <= mem_wb[w];
            end
        end
        d_stall <= ($urandom % 100) < 30;
    end

    // ======================= new (AXI4-Lite) =======================
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [3:0]  wstrb = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid, irq;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    wire [31:0] m_awaddr, m_wdata, m_araddr;
    wire [3:0]  m_wstrb;
    wire        m_awvalid, m_wvalid, m_bready, m_arvalid, m_rready;
    reg         m_awready = 0, m_wready = 0, m_arready = 0;
    reg         m_bvalid = 0, m_rvalid = 0;
    reg  [1:0]  m_bresp = 0, m_rresp = 0;
    reg  [31:0] m_rdata = 0;

    keccak_accelerator_dma_axil ax (
        .clk_i(clk), .rst_ni(rst_n),
        .s_awaddr(awaddr), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wvalid(wvalid), .s_wready(wready),
        .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_araddr(araddr), .s_arvalid(arvalid), .s_arready(arready),
        .s_rdata(rdata), .s_rresp(rresp), .s_rvalid(rvalid), .s_rready(rready),
        .m_awaddr(m_awaddr), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .irq_o(irq));

    // AXI4-Lite memory: random readies, in-order R/B with random latency, several outstanding
    integer slow = 0;                            // 0: fast, 1: slow (more backpressure)
    integer proto_err = 0;
    reg [31:0] ar_q [$];  integer ar_t [$];
    reg [31:0] aw_q [$];
    reg [35:0] w_q  [$];
    reg [1:0]  b_q  [$];  integer b_t [$];
    integer cyc = 0;

    function automatic bit in_mem(input [31:0] a);
        in_mem = a >= MEM_BASE && a < MEM_BASE + 4 * MEM_WORDS;
    endfunction

    // AXI rule checks on the master: valid must stay up and payload stable until the handshake
    reg        p_arv = 0, p_awv = 0, p_wv = 0;
    reg [31:0] p_ara, p_awa, p_wd;
    reg [3:0]  p_ws;
    always @(posedge clk) if (rst_n) begin
        if (p_arv && !(m_arvalid && m_araddr == p_ara)) begin proto_err++; $display("AR dropped/changed"); end
        if (p_awv && !(m_awvalid && m_awaddr == p_awa)) begin proto_err++; $display("AW dropped/changed"); end
        if (p_wv  && !(m_wvalid && m_wdata == p_wd && m_wstrb == p_ws)) begin proto_err++; $display("W dropped/changed"); end
        p_arv <= m_arvalid && !m_arready; p_ara <= m_araddr;
        p_awv <= m_awvalid && !m_awready; p_awa <= m_awaddr;
        p_wv  <= m_wvalid  && !m_wready;  p_wd  <= m_wdata; p_ws <= m_wstrb;
    end

    always @(posedge clk) begin
        cyc <= cyc + 1;
        // R
        if (m_rvalid && m_rready) m_rvalid <= 0;
        if ((!m_rvalid || m_rready) && ar_q.size() > 0 && ar_t[0] <= cyc) begin
            reg [31:0] a; a = ar_q.pop_front(); void'(ar_t.pop_front());
            m_rvalid <= 1;
            m_rresp  <= in_mem(a) ? 2'b00 : 2'b10;
            m_rdata  <= in_mem(a) ? mem_ax[(a - MEM_BASE) >> 2] : 32'hDEAD_BEEF;
        end
        // AR
        if (m_arvalid && m_arready) begin
            ar_q.push_back(m_araddr);
            ar_t.push_back(cyc + 1 + $urandom % (slow ? 6 : 2));
        end
        // AW / W (independent), write when both are there
        if (m_awvalid && m_awready) aw_q.push_back(m_awaddr);
        if (m_wvalid && m_wready)   w_q.push_back({m_wstrb, m_wdata});
        if (aw_q.size() > 0 && w_q.size() > 0) begin
            reg [31:0] a; reg [35:0] w; integer i;
            a = aw_q.pop_front(); w = w_q.pop_front();
            if (in_mem(a))
                for (i = 0; i < 4; i++) if (w[32 + i]) mem_ax[(a - MEM_BASE) >> 2][8*i +: 8] <= w[8*i +: 8];
            b_q.push_back(in_mem(a) ? 2'b00 : 2'b11);
            b_t.push_back(cyc + 1 + $urandom % (slow ? 8 : 2));
        end
        // B
        if (m_bvalid && m_bready) m_bvalid <= 0;
        if ((!m_bvalid || m_bready) && b_q.size() > 0 && b_t[0] <= cyc) begin
            m_bvalid <= 1;
            m_bresp  <= b_q.pop_front(); void'(b_t.pop_front());
        end
        m_arready <= ($urandom % 100) < (slow ? 40 : 85);
        m_awready <= ($urandom % 100) < (slow ? 40 : 85);
        m_wready  <= ($urandom % 100) < (slow ? 40 : 85);
    end

    // ======================= CPU tasks =======================
    integer errors = 0;

    task automatic wb_op(input bit we, input [11:0] a, input [31:0] d, input [3:0] s, output [31:0] q);
        @(negedge clk); wb_stb = 1; wb_we = we; wb_adr = {20'h10009, a}; wb_dat = d; wb_sel = s;
        @(negedge clk); wb_stb = 0;
        q = wb_q;
    endtask

    task automatic ax_wr(input [11:0] a, input [31:0] d, input [3:0] s);
        @(negedge clk);
        awaddr = {20'h40000, a}; wdata = d; wstrb = s; awvalid = 1; wvalid = 1; bready = $urandom % 2;
        #1; while (!(awready && wready)) begin @(negedge clk); #1; end
        @(negedge clk); awvalid = 0; wvalid = 0; bready = 1;
        while (!bvalid) @(negedge clk);
        @(negedge clk); bready = 0;
    endtask

    task automatic ax_rd(input [11:0] a, output [31:0] q);
        @(negedge clk);
        araddr = {20'h40000, a}; arvalid = 1; rready = 0;
        #1; while (!arready) begin @(negedge clk); #1; end
        @(negedge clk); arvalid = 0;
        repeat ($urandom % 2) @(negedge clk);
        rready = 1;
        while (!rvalid) @(negedge clk);
        q = rdata;
        @(negedge clk); rready = 0;
    endtask

    task automatic wr_both(input [11:0] a, input [31:0] d, input [3:0] s);
        reg [31:0] dummy;
        fork wb_op(1, a, d, s, dummy); ax_wr(a, d, s); join
    endtask

    task automatic rd_both(input [11:0] a, input string what);
        reg [31:0] q1, q2;
        fork wb_op(0, a, 0, 4'hF, q1); ax_rd(a, q2); join
        if (q1 !== q2) begin
            errors++;
            if (errors < 20) $display("MISMATCH %s @%03h: wb=%08h axil=%08h", what, a, q1, q2);
        end
    endtask

    // poll DMA_STATUS until not busy on both (independently)
    task automatic wait_both();
        reg [31:0] q; integer t;
        fork
            begin t = 0; do begin wb_op(0, 12'h210, 0, 4'hF, q); t++; end while (q[1] && t < 100000); if (q[1]) begin errors++; $display("WB DMA hang"); end end
            begin t = 0; do begin ax_rd(12'h210, q);             t++; end while (q[1] && t < 100000); if (q[1]) begin errors++; $display("AXI DMA hang"); end end
        join
    endtask

    task automatic compare_all();
        integer k;
        rd_both(12'h210, "DMA_STATUS");
        rd_both(12'h200, "DMA_ADDR");
        rd_both(12'h204, "DMA_LEN");
        rd_both(12'h208, "DMA_RATE");
        rd_both(12'h010, "ACC_STATUS");
        for (k = 0; k < 50; k++) rd_both(12'h020 + 4 * k, "STATE");
        for (k = 0; k < MEM_WORDS; k++)
            if (mem_wb[k] !== mem_ax[k]) begin
                errors++;
                if (errors < 20) $display("MISMATCH mem[%0d]: wb=%08h axil=%08h", k, mem_wb[k], mem_ax[k]);
            end
    endtask

    function automatic [7:0] rand_rate();
        case ($urandom % 6)
            0: rand_rate = 136;  1: rand_rate = 168;  2: rand_rate = 72;  3: rand_rate = 104;
            default: rand_rate = 4 * (1 + $urandom % 50);
        endcase
    endfunction

    task automatic dma_cmd(input [2:0] c, input [31:0] len, input [7:0] rate);
        reg [31:0] addr;
        addr = MEM_BASE + 4 * ($urandom % (MEM_WORDS - (len + 3) / 4));
        wr_both(12'h200, addr, 4'hF);
        wr_both(12'h204, len, 4'hF);
        wr_both(12'h208, rate, 4'hF);
        wr_both(12'h20C, c, 4'hF);
        wait_both();
    endtask

    integer n, k, cmds = 0;
    initial begin #200ms; $display("TIMEOUT at step %0d", n); $display("FAIL"); $finish; end
    reg [31:0] q;
    initial begin
        for (k = 0; k < MEM_WORDS; k++) begin mem_wb[k] = $urandom; mem_ax[k] = mem_wb[k]; end
        repeat (3) @(negedge clk); rst_n = 1;

        for (n = 0; n < 1500; n++) begin
            slow = (n % 3 == 0);
            case ($urandom % 12)
                0, 1:    dma_cmd(3'd3, $urandom % 201, rand_rate());                       // LOAD
                2, 3:    dma_cmd(3'd4, $urandom % 201, rand_rate());                       // STORE
                4, 5, 6: dma_cmd(3'd1, $urandom % 700, rand_rate());                       // ABSORB
                7, 8:    dma_cmd(3'd2, $urandom % 700, rand_rate());                       // SQUEEZE
                9: begin                                                                   // rejected command
                    case ($urandom % 3)
                        0: dma_cmd(3'd0 + 3'd5 * ($urandom % 2), 16, 136);                 // unknown
                        1: dma_cmd(3'd1, 64, ($urandom % 2) ? 8'd0 : 8'd204);              // bad rate
                        default: dma_cmd(3'd2, 64, 8'd130);                                // rate not /4
                    endcase
                end
                10: begin                                                                  // register-path ops
                    for (k = 0; k < 8; k++) wr_both(12'h120 + 4 * ($urandom % 50), $urandom, $urandom % 16);
                    if ($urandom % 2) wr_both(12'h000, 32'h1, 4'hF);
                    repeat (30) @(negedge clk);
                end
                default: begin
                    wr_both(12'h000, 32'h2, 4'hF);                                         // clear
                    wr_both(12'h210, 32'h0, 4'hF);                                         // clear DMA done
                end
            endcase
            cmds++;
            compare_all();
            if (errors >= 20) break;
        end
        $display("equivalence: %0d steps, %0d errors, %0d protocol errors", cmds, errors, proto_err);

        // ---------------- AXI-only: error responses ----------------
        begin : err_tests
            integer e0; e0 = errors;
            // ABSORB that runs off the end of memory part way: ERROR + DONE, no hang
            ax_wr(12'h200, MEM_BASE + 4 * MEM_WORDS - 64, 4'hF);
            ax_wr(12'h204, 300, 4'hF); ax_wr(12'h208, 136, 4'hF); ax_wr(12'h20C, 1, 4'hF);
            t_wait();
            ax_rd(12'h210, q); if (q[2:0] !== 3'b101) begin errors++; $display("ABSORB err: status %h", q); end
            // SQUEEZE into a bad region
            ax_wr(12'h200, 32'h2000_0000, 4'hF); ax_wr(12'h204, 500, 4'hF); ax_wr(12'h20C, 2, 4'hF);
            t_wait();
            ax_rd(12'h210, q); if (q[2:0] !== 3'b101) begin errors++; $display("SQUEEZE err: status %h", q); end
            // STORE with a bad address, then a good LOAD clears ERROR
            ax_wr(12'h200, 32'h0, 4'hF); ax_wr(12'h204, 200, 4'hF); ax_wr(12'h20C, 4, 4'hF);
            t_wait();
            ax_rd(12'h210, q); if (q[2:0] !== 3'b101) begin errors++; $display("STORE err: status %h", q); end
            ax_wr(12'h200, MEM_BASE, 4'hF); ax_wr(12'h204, 200, 4'hF); ax_wr(12'h20C, 3, 4'hF);
            t_wait();
            ax_rd(12'h210, q); if (q[2:0] !== 3'b001) begin errors++; $display("LOAD after err: status %h", q); end
            for (k = 0; k < 50; k++) begin
                ax_rd(12'h020 + 4 * k, q);
                if (q !== mem_ax[k]) begin errors++; $display("LOAD after err: state[%0d]", k); end
            end
            $display("error tests: %0d errors", errors - e0);
        end

        if (errors == 0 && proto_err == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

    task automatic t_wait();
        integer t; t = 0;
        do begin ax_rd(12'h210, q); t++; end while (q[1] && t < 100000);
        if (q[1]) begin errors++; $display("AXI DMA hang"); end
    endtask
endmodule
