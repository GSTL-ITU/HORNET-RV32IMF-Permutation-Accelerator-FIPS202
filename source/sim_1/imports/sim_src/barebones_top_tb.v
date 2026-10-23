`timescale 1ns/1ps

module barebones_top_tb();

reg rst_ni, clk_i;
wire irq_ack_o;
reg meip_i;
reg [15:0] fast_irq_i;
integer i;

barebones_wb_top uut(
    .rst_ni(rst_ni), 
    .clk_i(clk_i), 
    .meip_i(meip_i), 
    .fast_irq_i(fast_irq_i), 
    .irq_ack_o(irq_ack_o)
);

// 100 MHz clock
always begin
    clk_i = 1'b0; #12.5; clk_i = 1'b1; #12.5;
end

initial begin
    rst_ni = 1'b0; fast_irq_i = 16'b0; meip_i = 1'b0;
    
    // Changed for Vivado_2025.2++: memory_2rw_wb -> memory_inst
    for (i = 0; i < uut.memory_inst.RAM_DEPTH; i = i + 1) begin
        uut.memory_inst.mem[i] = {uut.memory_inst.DATA_WIDTH{1'b0}};  // Initialize to 0
    end
    
    #200;
    // Changed for Vivado_2025.2++: memory_2rw_wb -> memory_inst
    $readmemh("memory_init_tb.mem", uut.memory_inst.mem); // read data after reset, because reset initializes memory to 0
    
    #25;
    rst_ni = 1'b1; // Wait a cycle so that the instruction memory is ready
end

// Cycle counter + debug-interface monitor: prints the cycle of every debug write and
// ends the simulation on 'P' (pass) / 'F' (fail) from the firmware.
reg [63:0] cycle;
always @(posedge clk_i) begin
    if (!rst_ni)
        cycle <= 64'd0;
    else
        cycle <= cycle + 64'd1;
end

wire debug_wr = uut.debug_if_inst.wb_cyc_i && uut.debug_if_inst.wb_stb_i && uut.debug_if_inst.wb_we_i;
wire [31:0] debug_dat = uut.debug_if_inst.wb_dat_i;

always @(posedge clk_i) begin
    if (rst_ni && debug_wr) begin
        $display("    cycle %0d : %0d", cycle, debug_dat);
        if (debug_dat == "P") begin
            $display("TEST PASSED");
            $finish;
        end
        else if (debug_dat == "F") begin
            $display("TEST FAILED");
            $finish;
        end
    end
end

endmodule