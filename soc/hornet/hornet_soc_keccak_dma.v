// HORNET-RV32IMF SoC with the DMA-capable Keccak accelerator (keccak_accelerator_dma_axil).
// Drop-in replacement for hornet_soc (same parameters and ports), built on hornet_soc_dma.
//
// The accelerator's slave sits in the external AXI4-Lite range at KECCAK_BASE (4 KiB window,
// default 0x6000_0000); the rest of 0x4000_0000 - 0x7FFF_FFFF still goes to m_axi_*.
// Its DMA master reaches IMEM and DMEM through hornet_soc_dma's s_dma_* port; the core has
// priority there, so core timing is unchanged.
// The accelerator's DMA DONE is ORed into irq_i[0] (fast interrupt 2).
module hornet_soc_keccak_dma #(parameter IMEM_SIZE   = 65536,
                           parameter DMEM_SIZE   = 65536,
                           parameter IMEM_INIT   = "",
                           parameter DMEM_INIT   = "",
                           parameter CLK_FREQ    = 50000000,
                           parameter BAUD        = 115200,
                           parameter BOOT_ADDR   = 32'h0000_0000,
                           parameter RV_M        = 1,
                           parameter RV_F        = 1,
                           parameter KECCAK_BASE = 32'h6000_0000)  //4 KiB aligned, inside 0x4000_0000 - 0x7FFF_FFFF
(input         clk_i,
 input         rst_ni,

 input         uart_rx_i,
 output        uart_tx_o,

 input  [31:0] gpio_i,
 output [31:0] gpio_o,
 output [31:0] gpio_oe_o,

 input         meip_i,
 input  [13:0] irq_i,

 output [31:0] m_axi_awaddr,
 output [2:0]  m_axi_awprot,
 output        m_axi_awvalid,
 input         m_axi_awready,
 output [31:0] m_axi_wdata,
 output [3:0]  m_axi_wstrb,
 output        m_axi_wvalid,
 input         m_axi_wready,
 input  [1:0]  m_axi_bresp,
 input         m_axi_bvalid,
 output        m_axi_bready,
 output [31:0] m_axi_araddr,
 output [2:0]  m_axi_arprot,
 output        m_axi_arvalid,
 input         m_axi_arready,
 input  [31:0] m_axi_rdata,
 input  [1:0]  m_axi_rresp,
 input         m_axi_rvalid,
 output        m_axi_rready);

wire keccak_irq;

//DMA master -> SoC memories
wire [31:0] d_awaddr, d_wdata, d_araddr, d_rdata;
wire [3:0]  d_wstrb;
wire [1:0]  d_bresp, d_rresp;
wire        d_awvalid, d_awready, d_wvalid, d_wready, d_bvalid, d_bready;
wire        d_arvalid, d_arready, d_rvalid, d_rready;

//SoC external port
wire [31:0] e_awaddr, e_wdata, e_araddr, e_rdata;
wire [2:0]  e_awprot, e_arprot;
wire [3:0]  e_wstrb;
wire [1:0]  e_bresp, e_rresp;
wire        e_awvalid, e_awready, e_wvalid, e_wready, e_bvalid, e_bready;
wire        e_arvalid, e_arready, e_rvalid, e_rready;

hornet_soc_dma #(.IMEM_SIZE(IMEM_SIZE), .DMEM_SIZE(DMEM_SIZE), .IMEM_INIT(IMEM_INIT), .DMEM_INIT(DMEM_INIT),
             .CLK_FREQ(CLK_FREQ), .BAUD(BAUD), .BOOT_ADDR(BOOT_ADDR), .RV_M(RV_M), .RV_F(RV_F)) SOC
    (.clk_i(clk_i),
     .rst_ni(rst_ni),
     .uart_rx_i(uart_rx_i),
     .uart_tx_o(uart_tx_o),
     .gpio_i(gpio_i),
     .gpio_o(gpio_o),
     .gpio_oe_o(gpio_oe_o),
     .meip_i(meip_i),
     .irq_i(irq_i | {13'b0, keccak_irq}),
     .m_axi_awaddr(e_awaddr),
     .m_axi_awprot(e_awprot),
     .m_axi_awvalid(e_awvalid),
     .m_axi_awready(e_awready),
     .m_axi_wdata(e_wdata),
     .m_axi_wstrb(e_wstrb),
     .m_axi_wvalid(e_wvalid),
     .m_axi_wready(e_wready),
     .m_axi_bresp(e_bresp),
     .m_axi_bvalid(e_bvalid),
     .m_axi_bready(e_bready),
     .m_axi_araddr(e_araddr),
     .m_axi_arprot(e_arprot),
     .m_axi_arvalid(e_arvalid),
     .m_axi_arready(e_arready),
     .m_axi_rdata(e_rdata),
     .m_axi_rresp(e_rresp),
     .m_axi_rvalid(e_rvalid),
     .m_axi_rready(e_rready),
     .s_dma_awaddr(d_awaddr),
     .s_dma_awvalid(d_awvalid),
     .s_dma_awready(d_awready),
     .s_dma_wdata(d_wdata),
     .s_dma_wstrb(d_wstrb),
     .s_dma_wvalid(d_wvalid),
     .s_dma_wready(d_wready),
     .s_dma_bresp(d_bresp),
     .s_dma_bvalid(d_bvalid),
     .s_dma_bready(d_bready),
     .s_dma_araddr(d_araddr),
     .s_dma_arvalid(d_arvalid),
     .s_dma_arready(d_arready),
     .s_dma_rdata(d_rdata),
     .s_dma_rresp(d_rresp),
     .s_dma_rvalid(d_rvalid),
     .s_dma_rready(d_rready));

//external range: 0 accelerator (4 KiB at KECCAK_BASE, wins), 1 the rest -> m_axi_*
wire [63:0] x_awaddr, x_wdata, x_araddr, x_rdata;
wire [5:0]  x_awprot, x_arprot;
wire [7:0]  x_wstrb;
wire [3:0]  x_bresp, x_rresp;
wire [1:0]  x_awvalid, x_awready, x_wvalid, x_wready, x_bvalid, x_bready;
wire [1:0]  x_arvalid, x_arready, x_rvalid, x_rready;

axil_xbar #(.N(2),
            .BASE({32'h4000_0000, KECCAK_BASE}),
            .MASK({32'hC000_0000, 32'hFFFF_F000})) EXT_XBAR
    (.clk_i(clk_i),
     .rst_ni(rst_ni),
     .s_awaddr(e_awaddr),
     .s_awprot(e_awprot),
     .s_awvalid(e_awvalid),
     .s_awready(e_awready),
     .s_wdata(e_wdata),
     .s_wstrb(e_wstrb),
     .s_wvalid(e_wvalid),
     .s_wready(e_wready),
     .s_bresp(e_bresp),
     .s_bvalid(e_bvalid),
     .s_bready(e_bready),
     .s_araddr(e_araddr),
     .s_arprot(e_arprot),
     .s_arvalid(e_arvalid),
     .s_arready(e_arready),
     .s_rdata(e_rdata),
     .s_rresp(e_rresp),
     .s_rvalid(e_rvalid),
     .s_rready(e_rready),
     .m_awaddr(x_awaddr),
     .m_awprot(x_awprot),
     .m_awvalid(x_awvalid),
     .m_awready(x_awready),
     .m_wdata(x_wdata),
     .m_wstrb(x_wstrb),
     .m_wvalid(x_wvalid),
     .m_wready(x_wready),
     .m_bresp(x_bresp),
     .m_bvalid(x_bvalid),
     .m_bready(x_bready),
     .m_araddr(x_araddr),
     .m_arprot(x_arprot),
     .m_arvalid(x_arvalid),
     .m_arready(x_arready),
     .m_rdata(x_rdata),
     .m_rresp(x_rresp),
     .m_rvalid(x_rvalid),
     .m_rready(x_rready));

keccak_accelerator_dma_axil KECCAK
    (.clk_i(clk_i),
     .rst_ni(rst_ni),
     .s_awaddr(x_awaddr[31:0]),
     .s_awvalid(x_awvalid[0]),
     .s_awready(x_awready[0]),
     .s_wdata(x_wdata[31:0]),
     .s_wstrb(x_wstrb[3:0]),
     .s_wvalid(x_wvalid[0]),
     .s_wready(x_wready[0]),
     .s_bresp(x_bresp[1:0]),
     .s_bvalid(x_bvalid[0]),
     .s_bready(x_bready[0]),
     .s_araddr(x_araddr[31:0]),
     .s_arvalid(x_arvalid[0]),
     .s_arready(x_arready[0]),
     .s_rdata(x_rdata[31:0]),
     .s_rresp(x_rresp[1:0]),
     .s_rvalid(x_rvalid[0]),
     .s_rready(x_rready[0]),
     .m_awaddr(d_awaddr),
     .m_awvalid(d_awvalid),
     .m_awready(d_awready),
     .m_wdata(d_wdata),
     .m_wstrb(d_wstrb),
     .m_wvalid(d_wvalid),
     .m_wready(d_wready),
     .m_bresp(d_bresp),
     .m_bvalid(d_bvalid),
     .m_bready(d_bready),
     .m_araddr(d_araddr),
     .m_arvalid(d_arvalid),
     .m_arready(d_arready),
     .m_rdata(d_rdata),
     .m_rresp(d_rresp),
     .m_rvalid(d_rvalid),
     .m_rready(d_rready),
     .irq_o(keccak_irq));

assign m_axi_awaddr  = x_awaddr[63:32];
assign m_axi_awprot  = x_awprot[5:3];
assign m_axi_awvalid = x_awvalid[1];
assign x_awready[1]  = m_axi_awready;
assign m_axi_wdata   = x_wdata[63:32];
assign m_axi_wstrb   = x_wstrb[7:4];
assign m_axi_wvalid  = x_wvalid[1];
assign x_wready[1]   = m_axi_wready;
assign x_bresp[3:2]  = m_axi_bresp;
assign x_bvalid[1]   = m_axi_bvalid;
assign m_axi_bready  = x_bready[1];
assign m_axi_araddr  = x_araddr[63:32];
assign m_axi_arprot  = x_arprot[5:3];
assign m_axi_arvalid = x_arvalid[1];
assign x_arready[1]  = m_axi_arready;
assign x_rdata[63:32] = m_axi_rdata;
assign x_rresp[3:2]  = m_axi_rresp;
assign x_rvalid[1]   = m_axi_rvalid;
assign m_axi_rready  = x_rready[1];

endmodule
