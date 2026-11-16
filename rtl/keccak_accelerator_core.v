// Keccak-f[1600] permutation core (FIPS 202) with a simple register port.
// Shared by keccak_accelerator_axil and keccak_accelerator_dma_axil (HORNET-RV32IMF main).
// Same register map and behaviour as legacy_keccak_accelerator_wb.
//
// One full round (theta, rho, pi, chi, iota) per clock: 24 cycles per permutation.
// The state lives in the accelerator and is directly readable/writable over the bus,
// so software can absorb/squeeze in place instead of copying 200 bytes per permutation.
//
// Register map (offsets, 32-bit words, little-endian lanes):
//   0x000        CTRL    W: bit0 = start permutation, bit1 = clear state (both may be set,
//                           clear happens first). Ignored while busy.
//                        R: bit0 = busy
//   0x010        STATUS  W: bit0 is written into DONE (write 0 to clear it)
//                        R: bit0 = done (sticky, cleared on start), bit1 = busy
//   0x020-0x0E7  STATE   R/W: lane i low word at 0x020 + 8*i, high word at 0x024 + 8*i
//   0x120-0x1E7  XOR     W: data is XORed into the state word (absorb), R: same as STATE
// State/XOR writes are ignored while busy. Unmapped reads return 0, unmapped writes are ignored.
// be_i byte enables are honoured for STATE and XOR writes.
//
// Port: a request (req_i) is taken every cycle it is high. Read data appears on rdata_o in the
// cycle after a read request and holds until the next read request.

module keccak_accelerator_core (
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        req_i,
    input  wire        we_i,
    input  wire [11:0] addr_i,
    input  wire [31:0] wdata_i,
    input  wire [ 3:0] be_i,
    output reg  [31:0] rdata_o,

    output wire        busy_o,
    output wire        done_o
);
    localparam CTRL_OFS   = 12'h000;
    localparam STATUS_OFS = 12'h010;
    localparam STATE_OFS  = 12'h020;
    localparam XOR_OFS    = 12'h120;
    localparam NWORDS     = 50;

    reg [31:0] st [0:NWORDS-1];
    reg        busy;
    reg        done;
    reg [ 4:0] rnd;

    assign busy_o = busy;
    assign done_o = done;

    // -------------------------------------------------------------------------
    // Address decoding
    // -------------------------------------------------------------------------
    wire [11:0] ofs       = addr_i;
    wire [11:0] st_ofs    = ofs - STATE_OFS;
    wire [11:0] xor_ofs   = ofs - XOR_OFS;
    wire        is_ctrl   = (ofs[11:2] == CTRL_OFS[11:2]);
    wire        is_status = (ofs[11:2] == STATUS_OFS[11:2]);
    wire        is_state  = (ofs >= STATE_OFS) && (ofs < STATE_OFS + 4*NWORDS);
    wire        is_xor    = (ofs >= XOR_OFS)   && (ofs < XOR_OFS   + 4*NWORDS);
    wire [ 5:0] word_idx  = is_xor ? xor_ofs[7:2] : st_ofs[7:2];

    wire        bus_wr    = req_i && we_i;
    wire        bus_rd    = req_i && !we_i;
    wire        start     = bus_wr && is_ctrl && wdata_i[0] && !busy;
    wire        clear     = bus_wr && is_ctrl && wdata_i[1] && !busy;
    wire        st_wr     = bus_wr && (is_state || is_xor) && !busy;

    wire [31:0] sel_mask  = {{8{be_i[3]}}, {8{be_i[2]}}, {8{be_i[1]}}, {8{be_i[0]}}};

    // -------------------------------------------------------------------------
    // Round function: lane (x, y) is index x + 5*y, i.e. {st[2i+1], st[2i]}
    // -------------------------------------------------------------------------
    function [63:0] rol64;
        input [63:0] v;
        input integer n;
        rol64 = (n == 0) ? v : ((v << n) | (v >> (64 - n)));
    endfunction

    function integer rho;
        input integer i;
        case (i)
             0: rho =  0;   1: rho =  1;   2: rho = 62;   3: rho = 28;   4: rho = 27;
             5: rho = 36;   6: rho = 44;   7: rho =  6;   8: rho = 55;   9: rho = 20;
            10: rho =  3;  11: rho = 10;  12: rho = 43;  13: rho = 25;  14: rho = 39;
            15: rho = 41;  16: rho = 45;  17: rho = 15;  18: rho = 21;  19: rho =  8;
            20: rho = 18;  21: rho =  2;  22: rho = 61;  23: rho = 56;  default: rho = 14;
        endcase
    endfunction

    reg [63:0] rc;
    always @(*) begin
        case (rnd)
            5'd0 : rc = 64'h0000_0000_0000_0001;
            5'd1 : rc = 64'h0000_0000_0000_8082;
            5'd2 : rc = 64'h8000_0000_0000_808a;
            5'd3 : rc = 64'h8000_0000_8000_8000;
            5'd4 : rc = 64'h0000_0000_0000_808b;
            5'd5 : rc = 64'h0000_0000_8000_0001;
            5'd6 : rc = 64'h8000_0000_8000_8081;
            5'd7 : rc = 64'h8000_0000_0000_8009;
            5'd8 : rc = 64'h0000_0000_0000_008a;
            5'd9 : rc = 64'h0000_0000_0000_0088;
            5'd10: rc = 64'h0000_0000_8000_8009;
            5'd11: rc = 64'h0000_0000_8000_000a;
            5'd12: rc = 64'h0000_0000_8000_808b;
            5'd13: rc = 64'h8000_0000_0000_008b;
            5'd14: rc = 64'h8000_0000_0000_8089;
            5'd15: rc = 64'h8000_0000_0000_8003;
            5'd16: rc = 64'h8000_0000_0000_8002;
            5'd17: rc = 64'h8000_0000_0000_0080;
            5'd18: rc = 64'h0000_0000_0000_800a;
            5'd19: rc = 64'h8000_0000_8000_000a;
            5'd20: rc = 64'h8000_0000_8000_8081;
            5'd21: rc = 64'h8000_0000_0000_8080;
            5'd22: rc = 64'h0000_0000_8000_0001;
            5'd23: rc = 64'h8000_0000_8000_8008;
            default: rc = 64'h0;
        endcase
    end

    wire [63:0] a     [0:24];   // current state
    wire [63:0] c     [0:4];    // theta column parities
    wire [63:0] d     [0:4];    // theta effect
    wire [63:0] b     [0:24];   // after theta, rho, pi
    wire [63:0] a_nxt [0:24];   // after chi, iota

    genvar x, y;
    generate
        for (x = 0; x < 5; x = x + 1) begin : g_theta
            for (y = 0; y < 5; y = y + 1) begin : g_lane
                assign a[x + 5*y] = {st[2*(x + 5*y) + 1], st[2*(x + 5*y)]};
            end
            assign c[x] = a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20];
        end
        for (x = 0; x < 5; x = x + 1) begin : g_d
            assign d[x] = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1);
        end
        for (x = 0; x < 5; x = x + 1) begin : g_rho_pi
            for (y = 0; y < 5; y = y + 1) begin : g_lane
                assign b[y + 5*((2*x + 3*y) % 5)] = rol64(a[x + 5*y] ^ d[x], rho(x + 5*y));
            end
        end
        for (x = 0; x < 5; x = x + 1) begin : g_chi
            for (y = 0; y < 5; y = y + 1) begin : g_lane
                if (x == 0 && y == 0) begin : g_iota
                    assign a_nxt[0] = b[0] ^ (~b[1] & b[2]) ^ rc;
                end
                else begin : g_plain
                    assign a_nxt[x + 5*y] = b[x + 5*y] ^ (~b[(x + 1) % 5 + 5*y] & b[(x + 2) % 5 + 5*y]);
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Control and state registers
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy <= 1'b0;
            done <= 1'b0;
            rnd  <= 5'd0;
            for (i = 0; i < NWORDS; i = i + 1)
                st[i] <= 32'b0;
        end
        else if (busy) begin
            for (i = 0; i < 25; i = i + 1)
                {st[2*i + 1], st[2*i]} <= a_nxt[i];
            rnd <= rnd + 5'd1;
            if (rnd == 5'd23) begin
                busy <= 1'b0;
                done <= 1'b1;
                rnd  <= 5'd0;
            end
        end
        else begin
            if (clear)
                for (i = 0; i < NWORDS; i = i + 1)
                    st[i] <= 32'b0;
            else if (st_wr)
                st[word_idx] <= is_xor ? st[word_idx] ^ (wdata_i & sel_mask)
                                       : (st[word_idx] & ~sel_mask) | (wdata_i & sel_mask);

            if (start) begin
                busy <= 1'b1;
                done <= 1'b0;
            end
            else if (bus_wr && is_status)
                done <= wdata_i[0];
        end
    end

    // -------------------------------------------------------------------------
    // Read data, one cycle after the request
    // -------------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            rdata_o <= 32'b0;
        else if (bus_rd) begin
            if (is_ctrl)
                rdata_o <= {31'b0, busy};
            else if (is_status)
                rdata_o <= {30'b0, busy, done};
            else if (is_state || is_xor)
                rdata_o <= st[word_idx];
            else
                rdata_o <= 32'b0;
        end
    end

endmodule
