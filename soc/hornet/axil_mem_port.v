// AXI4-Lite slave into the HORNET-RV32IMF memories (IMEM port B and DMEM), for a DMA master.
// Sits between data_router and the two memories (see hornet_soc_dma.v).
//
// The core always has priority: a DMA request is only taken in a cycle in which the core does
// not access IMEM port B or DMEM, so core timing is unchanged (the core is never stalled).
// Responses to the core are gated so a DMA access never looks like a core response to
// data_router.
//
// One read or one write is taken per cycle (reads first). Read data is returned the cycle after
// acceptance and held in a skid register under rready backpressure; B comes the cycle after a
// write. Addresses outside IMEM/DMEM answer DECERR and touch no memory.

module axil_mem_port #(parameter IMEM_BASE = 32'h0000_0000,
                       parameter IMEM_SIZE = 65536,
                       parameter DMEM_BASE = 32'h1000_0000,
                       parameter DMEM_SIZE = 65536)
(input             clk_i,
 input             rst_ni,

 // core side (from data_router)
 input             c_imem_req_i,
 input             c_dmem_req_i,
 input      [31:0] c_addr_i,
 input             c_we_i,
 input      [3:0]  c_be_i,
 input      [31:0] c_wdata_i,
 output            c_imem_rvalid_o,
 output            c_dmem_rvalid_o,

 // memories (shared request signals, like data_router)
 output            imem_req_o,
 output            dmem_req_o,
 output     [31:0] addr_o,
 output            we_o,
 output     [3:0]  be_o,
 output     [31:0] wdata_o,
 input             imem_rvalid_i,
 input      [31:0] imem_rdata_i,
 input             dmem_rvalid_i,
 input      [31:0] dmem_rdata_i,

 // DMA (AXI4-Lite slave)
 input      [31:0] s_awaddr,
 input             s_awvalid,
 output            s_awready,
 input      [31:0] s_wdata,
 input      [3:0]  s_wstrb,
 input             s_wvalid,
 output            s_wready,
 output reg [1:0]  s_bresp,
 output reg        s_bvalid,
 input             s_bready,
 input      [31:0] s_araddr,
 input             s_arvalid,
 output            s_arready,
 output     [31:0] s_rdata,
 output     [1:0]  s_rresp,
 output            s_rvalid,
 input             s_rready);

localparam NONE = 2'd0, IMEM = 2'd1, DMEM = 2'd2;

function [1:0] decode;
    input [31:0] a;
    decode = a >= IMEM_BASE && a - IMEM_BASE < IMEM_SIZE ? IMEM
           : a >= DMEM_BASE && a - DMEM_BASE < DMEM_SIZE ? DMEM
           : NONE;
endfunction

wire [1:0] ar_sel = decode(s_araddr);
wire [1:0] aw_sel = decode(s_awaddr);

wire core_req = c_imem_req_i || c_dmem_req_i;

reg        rd_q;        //a DMA read was accepted last cycle, its data is on the memory outputs now
reg [1:0]  rd_sel_q;
reg        hold_v;      //R skid register
reg [31:0] hold_d;
reg [1:0]  hold_r;

//a new read must not collide with an R response that is still waiting
wire rd_go = s_arvalid && !core_req && !hold_v && (!rd_q || s_rready);
wire wr_go = s_awvalid && s_wvalid && !core_req && !rd_go && (!s_bvalid || s_bready);

assign s_arready = rd_go;
assign s_awready = wr_go;
assign s_wready  = wr_go;

assign imem_req_o = c_imem_req_i || (rd_go && ar_sel == IMEM) || (wr_go && aw_sel == IMEM);
assign dmem_req_o = c_dmem_req_i || (rd_go && ar_sel == DMEM) || (wr_go && aw_sel == DMEM);
assign addr_o     = core_req ? c_addr_i  : rd_go ? s_araddr : s_awaddr;
assign we_o       = core_req ? c_we_i    : wr_go;
assign be_o       = core_req ? c_be_i    : s_wstrb;
assign wdata_o    = core_req ? c_wdata_i : s_wdata;

//responses to the core only for the core's own requests
reg c_imem_q, c_dmem_q;
assign c_imem_rvalid_o = imem_rvalid_i && c_imem_q;
assign c_dmem_rvalid_o = dmem_rvalid_i && c_dmem_q;

wire [31:0] rd_data = rd_sel_q == IMEM ? imem_rdata_i : rd_sel_q == DMEM ? dmem_rdata_i : 32'b0;
wire [1:0]  rd_resp = rd_sel_q == NONE ? 2'b11 : 2'b00;

assign s_rvalid = hold_v || rd_q;
assign s_rdata  = hold_v ? hold_d : rd_data;
assign s_rresp  = hold_v ? hold_r : rd_resp;

always @(posedge clk_i or negedge rst_ni)
begin
    if(!rst_ni)
    begin
        c_imem_q <= 1'b0;
        c_dmem_q <= 1'b0;
        rd_q     <= 1'b0;
        rd_sel_q <= NONE;
        hold_v   <= 1'b0;
        hold_d   <= 32'b0;
        hold_r   <= 2'b00;
        s_bvalid <= 1'b0;
        s_bresp  <= 2'b00;
    end
    else
    begin
        c_imem_q <= c_imem_req_i;
        c_dmem_q <= c_dmem_req_i;

        rd_q <= rd_go;
        if(rd_go)
            rd_sel_q <= ar_sel;

        if(rd_q && !s_rready)
        begin
            hold_v <= 1'b1;
            hold_d <= rd_data;
            hold_r <= rd_resp;
        end
        else if(hold_v && s_rready)
            hold_v <= 1'b0;

        if(wr_go)
        begin
            s_bvalid <= 1'b1;
            s_bresp  <= aw_sel == NONE ? 2'b11 : 2'b00;
        end
        else if(s_bready)
            s_bvalid <= 1'b0;
    end
end

endmodule
