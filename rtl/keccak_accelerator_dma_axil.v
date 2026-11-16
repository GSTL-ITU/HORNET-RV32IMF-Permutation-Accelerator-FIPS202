// Keccak-f[1600] accelerator with DMA (FIPS 202), AXI4-Lite slave + AXI4-Lite master,
// for HORNET-RV32IMF (main).
//
// keccak_accelerator_core (register map 0x000-0x1E7, see keccak_accelerator_core.v) plus a DMA
// engine that moves data between memory and the state without the CPU touching every word.
// Register map and commands are the same as legacy_keccak_accelerator_dma_wb:
//
//   0x200  DMA_ADDR    R/W  memory byte address (word aligned)
//   0x204  DMA_LEN     R/W  length in bytes
//   0x208  DMA_RATE    R/W  rate in bytes (multiple of 4, 4..200), used by ABSORB/SQUEEZE
//   0x20C  DMA_CTRL    W: bits[2:0] = command (ignored while busy), R: bit0 = busy
//                         1 ABSORB : XOR LEN bytes from memory into the state starting at byte 0,
//                                    permuting after every full RATE block. A trailing partial
//                                    block is absorbed but not permuted (padding is left to SW).
//                         2 SQUEEZE: repeat { permute; write min(RATE, left) bytes to memory }
//                         3 LOAD   : overwrite the first LEN (<= 200) state bytes from memory
//                         4 STORE  : write the first LEN (<= 200) state bytes to memory
//   0x210  DMA_STATUS  R: bit0 = done (sticky, cleared on start), bit1 = busy,
//                         bit2 = error (command rejected, or an error response on the master port)
//                      W: bit0 -> done
// Partial words are handled with write strobes, so memory bytes past LEN are never written.
// While the DMA is busy, CPU accesses to 0x000-0x1FF are answered but ignored (reads return 0).
//
// Slave port: one transaction at a time, responses one cycle after acceptance, always OKAY.
//
// Master port: several reads (S_IN) or writes (S_OUT) may be outstanding; rready and bready are
// always high. AW and W of a write are offered together and may be accepted in different cycles.
// DONE is set only after every write response has come back, so memory is up to date when
// software sees DONE. An error response (SLVERR/DECERR) sets ERROR and ends the command at the
// next block boundary (requests already started are completed).
//
// irq_o is the sticky DMA DONE bit (level).

module keccak_accelerator_dma_axil (
    input  wire        clk_i,
    input  wire        rst_ni,

    // CPU slave
    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [ 3:0] s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [ 1:0] s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [ 1:0] s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    // DMA master
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [ 3:0] m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [ 1:0] m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [ 1:0] m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire        irq_o
);
    localparam ACC_CTRL_OFS   = 12'h000;
    localparam ACC_STATE_OFS  = 12'h020;
    localparam ACC_XOR_OFS    = 12'h120;

    localparam DMA_ADDR_OFS   = 12'h200;
    localparam DMA_LEN_OFS    = 12'h204;
    localparam DMA_RATE_OFS   = 12'h208;
    localparam DMA_CTRL_OFS   = 12'h20C;
    localparam DMA_STATUS_OFS = 12'h210;

    localparam CMD_ABSORB  = 3'd1;
    localparam CMD_SQUEEZE = 3'd2;
    localparam CMD_LOAD    = 3'd3;
    localparam CMD_STORE   = 3'd4;

    localparam S_IDLE       = 3'd0;
    localparam S_CHUNK      = 3'd1;   // set up the next block transfer
    localparam S_IN         = 3'd2;   // memory -> state
    localparam S_OUT        = 3'd3;   // state -> memory
    localparam S_PERM_START = 3'd4;
    localparam S_PERM_WAIT  = 3'd5;
    localparam S_DONE       = 3'd6;   // wait for outstanding write responses

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    reg [31:0] dma_addr;
    reg [31:0] dma_len;
    reg [ 7:0] dma_rate;
    reg [ 2:0] cmd;
    reg        dma_done;
    reg        dma_error;
    reg [ 2:0] state;

    reg [31:0] cur_addr;      // memory address of the current block
    reg [31:0] bytes_left;    // bytes not yet transferred
    reg [ 7:0] chunk;         // bytes in the current block
    reg [ 5:0] nwords;        // words in the current block
    reg [ 5:0] issued;        // requests issued (memory reads in S_IN, state reads in S_OUT)
    reg [ 5:0] done_words;    // words completed (state writes in S_IN, memory writes in S_OUT)
    reg        rd_pend;       // a state read was issued last cycle (S_OUT)
    reg [31:0] fifo0, fifo1;  // S_OUT skid buffer, fifo0 is the head
    reg [ 1:0] fifo_cnt;
    reg        aw_ok, w_ok;   // AW / W of the current write already accepted
    reg [ 7:0] b_out;         // writes waiting for their B response

    wire dma_busy = (state != S_IDLE);
    assign irq_o  = dma_done;

    // -------------------------------------------------------------------------
    // CPU slave: one transaction at a time
    // -------------------------------------------------------------------------
    wire        s_idle    = !s_bvalid && !s_rvalid;
    wire        wr_go     = s_idle && s_awvalid && s_wvalid;
    wire        rd_go     = s_idle && s_arvalid && !wr_go;

    assign s_awready = wr_go;
    assign s_wready  = wr_go;
    assign s_arready = rd_go;
    assign s_bresp   = 2'b00;
    assign s_rresp   = 2'b00;

    wire [11:0] ofs       = wr_go ? s_awaddr[11:0] : s_araddr[11:0];
    wire        cpu_req   = wr_go || rd_go;
    wire        cpu_wr    = wr_go;
    wire        is_inner  = (ofs < 12'h200);
    wire        is_dma    = !is_inner;

    // -------------------------------------------------------------------------
    // Permutation core, shared between the CPU (idle) and the DMA engine (busy)
    // -------------------------------------------------------------------------
    reg         eng_req;
    reg         eng_we;
    reg  [11:0] eng_adr;
    reg  [31:0] eng_dat;
    reg  [ 3:0] eng_sel;

    wire        cpu_to_inner = cpu_req && is_inner && !dma_busy;
    wire [31:0] core_rdata;
    wire        core_busy;

    keccak_accelerator_core core (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (dma_busy ? eng_req : cpu_to_inner),
        .we_i   (dma_busy ? eng_we  : cpu_wr),
        .addr_i (dma_busy ? eng_adr : ofs),
        .wdata_i(dma_busy ? eng_dat : s_wdata),
        .be_i   (dma_busy ? eng_sel : s_wstrb),
        .rdata_o(core_rdata),
        .busy_o (core_busy),
        .done_o ()
    );

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    // Byte enables for word k of a block with n bytes
    function [3:0] byte_mask;
        input [7:0] n;
        input [5:0] k;
        byte_mask = ((n - {k, 2'b00}) >= 8'd4) ? 4'b1111 :
                    ((n - {k, 2'b00}) == 8'd3) ? 4'b0111 :
                    ((n - {k, 2'b00}) == 8'd2) ? 4'b0011 : 4'b0001;
    endfunction

    wire        is_stream  = (cmd == CMD_ABSORB) || (cmd == CMD_SQUEEZE);
    wire [ 7:0] blk_max    = is_stream ? dma_rate : 8'd200;
    wire [ 7:0] next_chunk = (bytes_left < {24'b0, blk_max}) ? bytes_left[7:0] : blk_max;

    // S_IN: memory reads (AR), responses go straight into the state (R)
    wire        ar_hs      = m_arvalid && m_arready;
    wire        r_hs       = m_rvalid;                      // m_rready is always 1
    wire        r_err      = r_hs && m_rresp[1];

    assign m_arvalid = (state == S_IN) && (issued < nwords);
    assign m_araddr  = cur_addr + {24'b0, issued, 2'b00};
    assign m_rready  = 1'b1;

    // S_OUT: state reads into the skid buffer, memory writes (AW + W) out of it
    wire        out_wr_stb = (state == S_OUT) && (fifo_cnt != 2'd0) && (b_out != 8'hFF);
    wire        aw_now     = aw_ok || (m_awvalid && m_awready);
    wire        w_now      = w_ok  || (m_wvalid  && m_wready);
    wire        out_wr_acc = out_wr_stb && aw_now && w_now;
    wire        out_rd_go  = (state == S_OUT) && (issued < nwords) &&
                             ({1'b0, fifo_cnt} + {2'b0, rd_pend} - {2'b0, out_wr_acc} < 3'd2);
    wire        b_hs       = m_bvalid;                      // m_bready is always 1
    wire        b_err      = b_hs && m_bresp[1];

    assign m_awvalid = out_wr_stb && !aw_ok;
    assign m_awaddr  = cur_addr + {24'b0, done_words, 2'b00};
    assign m_wvalid  = out_wr_stb && !w_ok;
    assign m_wdata   = fifo0;
    assign m_wstrb   = byte_mask(chunk, done_words);
    assign m_bready  = 1'b1;

    wire        err_now    = dma_error || r_err || b_err;

    // Engine requests to the core
    always @(*) begin
        eng_req = 1'b0;
        eng_we  = 1'b0;
        eng_adr = 12'b0;
        eng_dat = 32'b0;
        eng_sel = 4'b1111;
        case (state)
            S_IN: if (r_hs) begin
                eng_req = 1'b1;
                eng_we  = 1'b1;
                eng_adr = ((cmd == CMD_LOAD) ? ACC_STATE_OFS : ACC_XOR_OFS) + {4'b0, done_words, 2'b00};
                eng_dat = m_rdata;
                eng_sel = byte_mask(chunk, done_words);
            end
            S_OUT: if (out_rd_go) begin
                eng_req = 1'b1;
                eng_adr = ACC_STATE_OFS + {4'b0, issued, 2'b00};
            end
            S_PERM_START: begin
                eng_req = 1'b1;
                eng_we  = 1'b1;
                eng_adr = ACC_CTRL_OFS;
                eng_dat = 32'h1;
            end
            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // DMA engine
    // -------------------------------------------------------------------------
    wire       cmd_wr    = cpu_wr && (ofs == DMA_CTRL_OFS) && !dma_busy;
    wire [2:0] cmd_new   = s_wdata[2:0];
    wire       rate_ok   = (dma_rate != 8'd0) && (dma_rate[1:0] == 2'b00) && (dma_rate <= 8'd200);
    wire       cmd_ok    = ((cmd_new == CMD_ABSORB || cmd_new == CMD_SQUEEZE) && rate_ok) ||
                           cmd_new == CMD_LOAD || cmd_new == CMD_STORE;
    wire       start_cmd = cmd_wr && cmd_ok;

    wire [7:0] b_out_nxt = b_out + {7'b0, out_wr_acc} - {7'b0, b_hs};

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dma_addr   <= 32'b0;
            dma_len    <= 32'b0;
            dma_rate   <= 8'd0;
            cmd        <= 3'd0;
            dma_done   <= 1'b0;
            dma_error  <= 1'b0;
            state      <= S_IDLE;
            cur_addr   <= 32'b0;
            bytes_left <= 32'b0;
            chunk      <= 8'd0;
            nwords     <= 6'd0;
            issued     <= 6'd0;
            done_words <= 6'd0;
            rd_pend    <= 1'b0;
            fifo0      <= 32'b0;
            fifo1      <= 32'b0;
            fifo_cnt   <= 2'd0;
            aw_ok      <= 1'b0;
            w_ok       <= 1'b0;
            b_out      <= 8'd0;
        end
        else begin
            b_out <= b_out_nxt;
            if (r_err || b_err)
                dma_error <= 1'b1;

            // CPU register writes (configuration is ignored while busy)
            if (cpu_wr && is_dma && !dma_busy) begin
                case (ofs)
                    DMA_ADDR_OFS:   dma_addr <= s_wdata;
                    DMA_LEN_OFS:    dma_len  <= s_wdata;
                    DMA_RATE_OFS:   dma_rate <= s_wdata[7:0];
                    DMA_STATUS_OFS: dma_done <= s_wdata[0];
                    default: ;
                endcase
            end

            case (state)
                S_IDLE: if (cmd_wr && !cmd_ok) begin
                    dma_error  <= 1'b1;
                    dma_done   <= 1'b1;
                end
                else if (start_cmd) begin
                    cmd        <= cmd_new;
                    dma_done   <= 1'b0;
                    dma_error  <= 1'b0;
                    cur_addr   <= dma_addr;
                    bytes_left <= dma_len;
                    state      <= (cmd_new == CMD_SQUEEZE) ? S_PERM_START : S_CHUNK;
                end

                S_CHUNK: begin
                    if (bytes_left == 32'b0 || err_now) begin
                        state <= S_DONE;
                    end
                    else begin
                        chunk      <= next_chunk;
                        nwords     <= next_chunk[7:2] + {5'b0, |next_chunk[1:0]};
                        issued     <= 6'd0;
                        done_words <= 6'd0;
                        rd_pend    <= 1'b0;
                        fifo_cnt   <= 2'd0;
                        aw_ok      <= 1'b0;
                        w_ok       <= 1'b0;
                        state      <= (cmd == CMD_ABSORB || cmd == CMD_LOAD) ? S_IN : S_OUT;
                    end
                end

                S_IN: begin
                    if (ar_hs)
                        issued <= issued + 6'd1;
                    if (r_hs) begin
                        done_words <= done_words + 6'd1;
                        if (done_words + 6'd1 == nwords) begin
                            cur_addr   <= cur_addr + {24'b0, chunk};
                            bytes_left <= bytes_left - {24'b0, chunk};
                            if (cmd == CMD_ABSORB && chunk == dma_rate && !err_now)
                                state <= S_PERM_START;
                            else
                                state <= S_DONE;
                        end
                    end
                end

                S_OUT: begin
                    if (out_rd_go)
                        issued <= issued + 6'd1;
                    rd_pend <= out_rd_go;

                    // skid buffer: push the state word read last cycle, pop on memory write
                    case ({rd_pend, out_wr_acc})
                        2'b10: begin
                            if (fifo_cnt == 2'd0) fifo0 <= core_rdata;
                            else                  fifo1 <= core_rdata;
                            fifo_cnt <= fifo_cnt + 2'd1;
                        end
                        2'b01: begin
                            fifo0    <= fifo1;
                            fifo_cnt <= fifo_cnt - 2'd1;
                        end
                        2'b11: begin
                            if (fifo_cnt == 2'd1) fifo0 <= core_rdata;
                            else begin
                                fifo0 <= fifo1;
                                fifo1 <= core_rdata;
                            end
                        end
                        default: ;
                    endcase

                    // AW and W may be accepted in different cycles
                    if (out_wr_acc) begin
                        aw_ok <= 1'b0;
                        w_ok  <= 1'b0;
                    end
                    else if (out_wr_stb) begin
                        aw_ok <= aw_now;
                        w_ok  <= w_now;
                    end

                    if (out_wr_acc) begin
                        done_words <= done_words + 6'd1;
                        if (done_words + 6'd1 == nwords) begin
                            cur_addr   <= cur_addr + {24'b0, chunk};
                            bytes_left <= bytes_left - {24'b0, chunk};
                            if (cmd == CMD_SQUEEZE && bytes_left != {24'b0, chunk} && !err_now)
                                state <= S_PERM_START;
                            else
                                state <= S_DONE;
                        end
                    end
                end

                S_PERM_START: state <= S_PERM_WAIT;
                S_PERM_WAIT:  if (!core_busy) state <= S_CHUNK;

                S_DONE: if (b_out_nxt == 8'd0) begin
                    dma_done <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // CPU read data
    // -------------------------------------------------------------------------
    // core_rdata only changes on a core read; while s_rvalid is high the CPU can't start a
    // command, and rd_inner implies the DMA was idle, so it stays stable until the R handshake
    reg        rd_inner;
    reg [31:0] rdata;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s_bvalid <= 1'b0;
            s_rvalid <= 1'b0;
            rd_inner <= 1'b0;
            rdata    <= 32'b0;
        end
        else begin
            if (wr_go)
                s_bvalid <= 1'b1;
            else if (s_bready)
                s_bvalid <= 1'b0;

            if (rd_go)
                s_rvalid <= 1'b1;
            else if (s_rready)
                s_rvalid <= 1'b0;

            if (rd_go) begin
                rd_inner <= cpu_to_inner;
                case (ofs)
                    DMA_ADDR_OFS:   rdata <= dma_addr;
                    DMA_LEN_OFS:    rdata <= dma_len;
                    DMA_RATE_OFS:   rdata <= {24'b0, dma_rate};
                    DMA_CTRL_OFS:   rdata <= {31'b0, dma_busy};
                    DMA_STATUS_OFS: rdata <= {29'b0, dma_error, dma_busy, dma_done};
                    default:        rdata <= 32'b0;
                endcase
            end
        end
    end

    assign s_rdata = rd_inner ? core_rdata : rdata;

endmodule
