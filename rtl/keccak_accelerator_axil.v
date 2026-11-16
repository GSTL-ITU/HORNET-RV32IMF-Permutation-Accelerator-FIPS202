// Keccak-f[1600] permutation accelerator (FIPS 202), AXI4-Lite slave for HORNET-RV32IMF (main).
//
// AXI4-Lite wrapper around keccak_accelerator_core; the register map is the same as
// legacy_keccak_accelerator_wb (see keccak_accelerator_core.v), only the low 12 address bits are
// decoded (4 KiB window). Every access answers OKAY; unmapped reads return 0.
//
// One transaction at a time: a write needs AW and W together and is accepted when no response is
// pending, a read likewise. Writes win if both arrive in the same cycle. Responses come one cycle
// after acceptance.
//
// irq_o is the sticky DONE bit (level): high from the end of a permutation until the next start
// or until software writes 0 to STATUS.

module keccak_accelerator_axil (
    input  wire        clk_i,
    input  wire        rst_ni,

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

    output wire        irq_o
);
    wire idle  = !s_bvalid && !s_rvalid;
    wire wr_go = idle && s_awvalid && s_wvalid;
    wire rd_go = idle && s_arvalid && !wr_go;

    assign s_awready = wr_go;
    assign s_wready  = wr_go;
    assign s_arready = rd_go;
    assign s_bresp   = 2'b00;
    assign s_rresp   = 2'b00;

    wire [31:0] core_rdata;

    // core_rdata only changes on a read request, and none is taken while s_rvalid is high,
    // so s_rdata stays stable until the R handshake
    keccak_accelerator_core core (
        .clk_i  (clk_i),
        .rst_ni (rst_ni),
        .req_i  (wr_go || rd_go),
        .we_i   (wr_go),
        .addr_i (wr_go ? s_awaddr[11:0] : s_araddr[11:0]),
        .wdata_i(s_wdata),
        .be_i   (s_wstrb),
        .rdata_o(core_rdata),
        .busy_o (),
        .done_o (irq_o)
    );

    assign s_rdata = core_rdata;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            s_bvalid <= 1'b0;
            s_rvalid <= 1'b0;
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
        end
    end

endmodule
