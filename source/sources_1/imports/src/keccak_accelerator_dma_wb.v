// Keccak-f[1600] accelerator with DMA (FIPS 202), Wishbone slave + Wishbone master.
//
// Wraps keccak_accelerator_wb (unchanged register map at 0x000-0x1E7) and adds a DMA engine
// that moves data between RAM and the state without the CPU touching every word.
//
// DMA registers (offsets from the accelerator base):
//   0x200  DMA_ADDR    R/W  RAM byte address (word aligned)
//   0x204  DMA_LEN     R/W  length in bytes
//   0x208  DMA_RATE    R/W  rate in bytes (multiple of 4, 4..200), used by ABSORB/SQUEEZE
//   0x20C  DMA_CTRL    W: bits[2:0] = command (ignored while busy), R: bit0 = busy
//                         1 ABSORB : XOR LEN bytes from RAM into the state starting at byte 0,
//                                    permuting after every full RATE block. A trailing partial
//                                    block is absorbed but not permuted (padding is left to SW).
//                         2 SQUEEZE: repeat { permute; write min(RATE, left) bytes to RAM }
//                         3 LOAD   : overwrite the first LEN (<= 200) state bytes from RAM
//                         4 STORE  : write the first LEN (<= 200) state bytes to RAM
//   0x210  DMA_STATUS  R: bit0 = done (sticky, cleared on start), bit1 = busy,
//                         bit2 = error (last command rejected: unknown command or bad RATE)
//                      W: bit0 -> done
// Partial words are handled with byte enables, so RAM bytes past LEN are never written.
// While the DMA is busy, CPU accesses to 0x000-0x1FF are acknowledged but ignored (reads 0).
//
// A bus error on the master port aborts the command with DONE and ERROR set.
// The master port is pipelined: one request per cycle while !dma_stall_i, dma_ack_i returns
// one cycle after each accepted read (data on dma_dat_i). Writes complete on acceptance.

module keccak_accelerator_dma_wb (
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire        wb_we_i,
    input  wire [31:0] wb_adr_i,
    input  wire [31:0] wb_dat_i,
    input  wire [ 3:0] wb_sel_i,
    output wire        wb_stall_o,
    output wire        wb_ack_o,
    output wire [31:0] wb_dat_o,
    output wire        wb_err_o,
    input  wire        wb_rst_i,
    input  wire        wb_clk_i,

    output wire        dma_cyc_o,
    output wire        dma_stb_o,
    output wire        dma_we_o,
    output wire [31:0] dma_adr_o,
    output wire [31:0] dma_dat_o,
    output wire [ 3:0] dma_sel_o,
    input  wire        dma_stall_i,
    input  wire        dma_ack_i,
    input  wire [31:0] dma_dat_i,
    input  wire        dma_err_i
);
    localparam ACC_CTRL_OFS   = 12'h000;
    localparam ACC_STATUS_OFS = 12'h010;
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
    localparam S_IN         = 3'd2;   // RAM -> state
    localparam S_OUT        = 3'd3;   // state -> RAM
    localparam S_PERM_START = 3'd4;
    localparam S_PERM_POLL  = 3'd5;
    localparam S_PERM_CHECK = 3'd6;
    localparam S_DONE       = 3'd7;

    assign wb_stall_o = 1'b0;
    assign wb_err_o   = 1'b0;

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

    reg [31:0] cur_addr;      // RAM address of the current block
    reg [31:0] bytes_left;    // bytes not yet transferred
    reg [ 7:0] chunk;         // bytes in the current block
    reg [ 5:0] nwords;        // words in the current block
    reg [ 5:0] issued;        // requests issued (RAM reads in S_IN, state reads in S_OUT)
    reg [ 5:0] done_words;    // words completed (state writes in S_IN, RAM writes in S_OUT)
    reg        rd_pend;       // a state read was issued last cycle (S_OUT)
    reg [31:0] fifo0, fifo1;  // S_OUT skid buffer, fifo0 is the head
    reg [ 1:0] fifo_cnt;

    wire dma_busy = (state != S_IDLE);

    // -------------------------------------------------------------------------
    // CPU slave decoding
    // -------------------------------------------------------------------------
    wire [11:0] ofs       = wb_adr_i[11:0];
    wire        cpu_req   = wb_cyc_i && wb_stb_i;
    wire        cpu_wr    = cpu_req && wb_we_i;
    wire        is_inner  = (ofs < 12'h200);
    wire        is_dma    = !is_inner;

    // -------------------------------------------------------------------------
    // Inner accelerator, shared between the CPU (idle) and the DMA engine (busy)
    // -------------------------------------------------------------------------
    reg         eng_stb;
    reg         eng_we;
    reg  [31:0] eng_adr;
    reg  [31:0] eng_dat;
    reg  [ 3:0] eng_sel;

    wire        cpu_to_inner = cpu_req && is_inner && !dma_busy;
    wire        acc_cyc = dma_busy ? eng_stb : cpu_to_inner;
    wire        acc_stb = acc_cyc;
    wire        acc_we  = dma_busy ? eng_we  : wb_we_i;
    wire [31:0] acc_adr = dma_busy ? eng_adr : wb_adr_i;
    wire [31:0] acc_dat = dma_busy ? eng_dat : wb_dat_i;
    wire [ 3:0] acc_sel = dma_busy ? eng_sel : wb_sel_i;
    wire        acc_ack;
    wire [31:0] acc_rdata;

    keccak_accelerator_wb acc (
        .wb_cyc_i(acc_cyc),
        .wb_stb_i(acc_stb),
        .wb_we_i(acc_we),
        .wb_adr_i(acc_adr),
        .wb_dat_i(acc_dat),
        .wb_sel_i(acc_sel),
        .wb_stall_o(),
        .wb_ack_o(acc_ack),
        .wb_dat_o(acc_rdata),
        .wb_err_o(),
        .wb_rst_i(wb_rst_i),
        .wb_clk_i(wb_clk_i)
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

    wire        is_stream = (cmd == CMD_ABSORB) || (cmd == CMD_SQUEEZE);
    wire [ 7:0] blk_max   = is_stream ? dma_rate : 8'd200;
    wire [ 7:0] next_chunk = (bytes_left < {24'b0, blk_max}) ? bytes_left[7:0] : blk_max;

    // S_IN: RAM reads
    wire        in_rd_stb  = (state == S_IN) && (issued < nwords);
    wire        in_rd_acc  = in_rd_stb && !dma_stall_i;

    // S_OUT: state reads into the skid buffer, RAM writes out of it
    wire        out_wr_stb = (state == S_OUT) && (fifo_cnt != 2'd0);
    wire        out_wr_acc = out_wr_stb && !dma_stall_i;
    wire        out_rd_go  = (state == S_OUT) && (issued < nwords) &&
                             ({1'b0, fifo_cnt} + {2'b0, rd_pend} - {2'b0, out_wr_acc} < 3'd2);

    assign dma_cyc_o = in_rd_stb || out_wr_stb;
    assign dma_stb_o = dma_cyc_o;
    assign dma_we_o  = out_wr_stb;
    assign dma_adr_o = cur_addr + {24'b0, (state == S_OUT) ? done_words : issued, 2'b00};
    assign dma_dat_o = fifo0;
    assign dma_sel_o = (state == S_OUT) ? byte_mask(chunk, done_words) : 4'b1111;

    // Engine requests to the inner accelerator
    always @(*) begin
        eng_stb = 1'b0;
        eng_we  = 1'b0;
        eng_adr = 32'b0;
        eng_dat = 32'b0;
        eng_sel = 4'b1111;
        case (state)
            S_IN: if (dma_ack_i) begin
                eng_stb = 1'b1;
                eng_we  = 1'b1;
                eng_adr = {20'b0, (cmd == CMD_LOAD) ? ACC_STATE_OFS : ACC_XOR_OFS} + {24'b0, done_words, 2'b00};
                eng_dat = dma_dat_i;
                eng_sel = byte_mask(chunk, done_words);
            end
            S_OUT: if (out_rd_go) begin
                eng_stb = 1'b1;
                eng_adr = {20'b0, ACC_STATE_OFS} + {24'b0, issued, 2'b00};
            end
            S_PERM_START: begin
                eng_stb = 1'b1;
                eng_we  = 1'b1;
                eng_adr = {20'b0, ACC_CTRL_OFS};
                eng_dat = 32'h1;
            end
            S_PERM_POLL: begin
                eng_stb = 1'b1;
                eng_adr = {20'b0, ACC_STATUS_OFS};
            end
            default: ;
        endcase
    end

    // -------------------------------------------------------------------------
    // DMA engine
    // -------------------------------------------------------------------------
    wire       cmd_wr    = cpu_wr && (ofs == DMA_CTRL_OFS) && !dma_busy;
    wire [2:0] cmd_new   = wb_dat_i[2:0];
    wire       rate_ok   = (dma_rate != 8'd0) && (dma_rate[1:0] == 2'b00) && (dma_rate <= 8'd200);
    wire       cmd_ok    = ((cmd_new == CMD_ABSORB || cmd_new == CMD_SQUEEZE) && rate_ok) ||
                           cmd_new == CMD_LOAD || cmd_new == CMD_STORE;
    wire       start_cmd = cmd_wr && cmd_ok;

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
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
        end
        else begin
            // CPU register writes (configuration is ignored while busy)
            if (cpu_wr && is_dma && !dma_busy) begin
                case (ofs)
                    DMA_ADDR_OFS:   dma_addr <= wb_dat_i;
                    DMA_LEN_OFS:    dma_len  <= wb_dat_i;
                    DMA_RATE_OFS:   dma_rate <= wb_dat_i[7:0];
                    DMA_STATUS_OFS: dma_done <= wb_dat_i[0];
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
                    state      <= (wb_dat_i[2:0] == CMD_SQUEEZE) ? S_PERM_START : S_CHUNK;
                end

                S_CHUNK: begin
                    if (bytes_left == 32'b0) begin
                        state <= S_DONE;
                    end
                    else begin
                        chunk      <= next_chunk;
                        nwords     <= next_chunk[7:2] + {5'b0, |next_chunk[1:0]};
                        issued     <= 6'd0;
                        done_words <= 6'd0;
                        rd_pend    <= 1'b0;
                        fifo_cnt   <= 2'd0;
                        state      <= (cmd == CMD_ABSORB || cmd == CMD_LOAD) ? S_IN : S_OUT;
                    end
                end

                S_IN: begin
                    if (in_rd_acc)
                        issued <= issued + 6'd1;
                    if (dma_ack_i) begin
                        done_words <= done_words + 6'd1;
                        if (done_words + 6'd1 == nwords) begin
                            cur_addr   <= cur_addr + {24'b0, chunk};
                            bytes_left <= bytes_left - {24'b0, chunk};
                            if (cmd == CMD_ABSORB && chunk == dma_rate)
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

                    // skid buffer: push the state word read last cycle, pop on RAM write
                    case ({rd_pend, out_wr_acc})
                        2'b10: begin
                            if (fifo_cnt == 2'd0) fifo0 <= acc_rdata;
                            else                  fifo1 <= acc_rdata;
                            fifo_cnt <= fifo_cnt + 2'd1;
                        end
                        2'b01: begin
                            fifo0    <= fifo1;
                            fifo_cnt <= fifo_cnt - 2'd1;
                        end
                        2'b11: begin
                            if (fifo_cnt == 2'd1) fifo0 <= acc_rdata;
                            else begin
                                fifo0 <= fifo1;
                                fifo1 <= acc_rdata;
                            end
                        end
                        default: ;
                    endcase

                    if (out_wr_acc) begin
                        done_words <= done_words + 6'd1;
                        if (done_words + 6'd1 == nwords) begin
                            cur_addr   <= cur_addr + {24'b0, chunk};
                            bytes_left <= bytes_left - {24'b0, chunk};
                            if (cmd == CMD_SQUEEZE && bytes_left != {24'b0, chunk})
                                state <= S_PERM_START;
                            else
                                state <= S_DONE;
                        end
                    end
                end

                S_PERM_START: state <= S_PERM_POLL;
                S_PERM_POLL:  state <= S_PERM_CHECK;
                S_PERM_CHECK: if (acc_ack) begin
                    if (acc_rdata[0])
                        state <= S_CHUNK;
                    else
                        state <= S_PERM_POLL;
                end

                S_DONE: begin
                    dma_done <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase

            if (dma_err_i && (state == S_IN || state == S_OUT)) begin
                dma_error <= 1'b1;
                state     <= S_DONE;
            end
        end
    end

    // -------------------------------------------------------------------------
    // CPU response: ack and read data one cycle after the request
    // -------------------------------------------------------------------------
    reg        ack;
    reg        rd_inner;
    reg [31:0] rdata;

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            ack      <= 1'b0;
            rd_inner <= 1'b0;
            rdata    <= 32'b0;
        end
        else begin
            ack      <= cpu_req;
            rd_inner <= cpu_to_inner;
            if (cpu_req && !wb_we_i) begin
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

    assign wb_ack_o = ack;
    assign wb_dat_o = rd_inner ? acc_rdata : rdata;

endmodule
