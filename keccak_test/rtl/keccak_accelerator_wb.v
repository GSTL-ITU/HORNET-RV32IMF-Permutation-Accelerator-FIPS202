`timescale 1ns/1ps

module keccak_accelerator_wb (
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
    input  wire        wb_clk_i
);
    parameter EN_ADDR = 32'h1000_9000;
    parameter DN_ADDR = 32'h1000_9010;
    parameter ST_ADDR = 32'h1000_9020;

    reg en;
    reg done;
    reg load;
    reg ack;

    assign wb_stall_o = 1'b0;
    assign wb_err_o = 1'b0;

    reg  [  31:0] sbuf [0:63];
    wire [  31:0] sbuf_idx;
    wire [  31:0] sbuf_offset;
    reg  [   4:0] scnt;
    reg  [   4:0] srnd;

    assign sbuf_offset = wb_adr_i - ST_ADDR;
    assign sbuf_idx = {2'b0, sbuf_offset[31:2]};

    reg signed [63:0] round_constant [23:0];

    reg signed [63:0] Aba;
    reg signed [63:0] Abe;
    reg signed [63:0] Abi;
    reg signed [63:0] Abo;
    reg signed [63:0] Abu;
    reg signed [63:0] Aga;
    reg signed [63:0] Age;
    reg signed [63:0] Agi;
    reg signed [63:0] Ago;
    reg signed [63:0] Agu;
    reg signed [63:0] Aka;
    reg signed [63:0] Ake;
    reg signed [63:0] Aki;
    reg signed [63:0] Ako;
    reg signed [63:0] Aku;
    reg signed [63:0] Ama;
    reg signed [63:0] Ame;
    reg signed [63:0] Ami;
    reg signed [63:0] Amo;
    reg signed [63:0] Amu;
    reg signed [63:0] Asa;
    reg signed [63:0] Ase;
    reg signed [63:0] Asi;
    reg signed [63:0] Aso;
    reg signed [63:0] Asu;

    reg signed [63:0] BCa,  BCe,  BCi,  BCo,  BCu;
    reg signed [63:0] Da,   De,   Di,   DoDo, Du;
    reg signed [63:0] Eba,  Ebe,  Ebi,  Ebo,  Ebu;
    reg signed [63:0] Ega,  Ege,  Egi,  Ego,  Egu;
    reg signed [63:0] Eka,  Eke,  Eki,  Eko,  Eku;
    reg signed [63:0] Ema,  Eme,  Emi,  Emo,  Emu;
    reg signed [63:0] Esa,  Ese,  Esi,  Eso,  Esu;

    assign round_constant[ 0] = 64'h0000_0000_0000_0001;
    assign round_constant[ 1] = 64'h0000_0000_0000_8082;              
    assign round_constant[ 2] = 64'h8000_0000_0000_808a;              
    assign round_constant[ 3] = 64'h8000_0000_8000_8000;              
    assign round_constant[ 4] = 64'h0000_0000_0000_808b;              
    assign round_constant[ 5] = 64'h0000_0000_8000_0001;              
    assign round_constant[ 6] = 64'h8000_0000_8000_8081;              
    assign round_constant[ 7] = 64'h8000_0000_0000_8009;              
    assign round_constant[ 8] = 64'h0000_0000_0000_008a;              
    assign round_constant[ 9] = 64'h0000_0000_0000_0088;              
    assign round_constant[10] = 64'h0000_0000_8000_8009;              
    assign round_constant[11] = 64'h0000_0000_8000_000a;              
    assign round_constant[12] = 64'h0000_0000_8000_808b;              
    assign round_constant[13] = 64'h8000_0000_0000_008b;              
    assign round_constant[14] = 64'h8000_0000_0000_8089;              
    assign round_constant[15] = 64'h8000_0000_0000_8003;              
    assign round_constant[16] = 64'h8000_0000_0000_8002;              
    assign round_constant[17] = 64'h8000_0000_0000_0080;              
    assign round_constant[18] = 64'h0000_0000_0000_800a;              
    assign round_constant[19] = 64'h8000_0000_8000_000a;              
    assign round_constant[20] = 64'h8000_0000_8000_8081;              
    assign round_constant[21] = 64'h8000_0000_0000_8080;              
    assign round_constant[22] = 64'h0000_0000_8000_0001;              
    assign round_constant[23] = 64'h8000_0000_8000_8008;

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i)
            ack <= 1'b0;
        else
            ack <= wb_stb_i;  
    end
    assign wb_ack_o = ack;

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            en <= 1'b0;
            done <= 1'b0;
            load <= 1'b0; 
        end
        else begin
            if (wb_cyc_i && wb_stb_i && wb_we_i) begin
                if (wb_adr_i == EN_ADDR)
                    en <= wb_dat_i[0];
                else if (wb_adr_i == DN_ADDR)
                    done <= wb_dat_i[0];
                else if (wb_adr_i >= ST_ADDR)
                    sbuf[sbuf_idx[5:0]] <= wb_dat_i;
                //$display("SBUF INDEX: %d, DATA: %d", sbuf_idx[5:0], wb_dat_i);
            end
        end
    end

    assign wb_dat_o = (wb_adr_i == DN_ADDR) ? {31'b0, done} : sbuf[sbuf_idx[5:0]];

    always @(posedge wb_clk_i or posedge wb_rst_i) begin
        if (wb_rst_i) begin
            scnt <= 5'b0;
            srnd <= 5'b0;
        end
        else begin
            if (en) begin
                done <= 1'b0;
                case (scnt)
                    5'd0 : begin
                        Aba <= {sbuf[ 1], sbuf[ 0]};
                        Abe <= {sbuf[ 3], sbuf[ 2]};
                        Abi <= {sbuf[ 5], sbuf[ 4]};
                        Abo <= {sbuf[ 7], sbuf[ 6]};
                        Abu <= {sbuf[ 9], sbuf[ 8]};
                        Aga <= {sbuf[11], sbuf[10]};
                        Age <= {sbuf[13], sbuf[12]};
                        Agi <= {sbuf[15], sbuf[14]};
                        Ago <= {sbuf[17], sbuf[16]};
                        Agu <= {sbuf[19], sbuf[18]};
                        Aka <= {sbuf[21], sbuf[20]};  
                        Ake <= {sbuf[23], sbuf[22]};  
                        Aki <= {sbuf[25], sbuf[24]};  
                        Ako <= {sbuf[27], sbuf[26]};  
                        Aku <= {sbuf[29], sbuf[28]};  
                        Ama <= {sbuf[31], sbuf[30]};  
                        Ame <= {sbuf[33], sbuf[32]};  
                        Ami <= {sbuf[35], sbuf[34]};  
                        Amo <= {sbuf[37], sbuf[36]};  
                        Amu <= {sbuf[39], sbuf[38]};  
                        Asa <= {sbuf[41], sbuf[40]};  
                        Ase <= {sbuf[43], sbuf[42]};  
                        Asi <= {sbuf[45], sbuf[44]}; 
                        Aso <= {sbuf[47], sbuf[46]};  
                        Asu <= {sbuf[49], sbuf[48]};
                        scnt <= 5'd1;
                    end
                    5'd1 : begin
                        BCa <= Aba ^ Aga ^ Aka ^ Ama ^ Asa;
                        BCe <= Abe ^ Age ^ Ake ^ Ame ^ Ase;
                        BCi <= Abi ^ Agi ^ Aki ^ Ami ^ Asi;
                        BCo <= Abo ^ Ago ^ Ako ^ Amo ^ Aso;
                        BCu <= Abu ^ Agu ^ Aku ^ Amu ^ Asu;
                        scnt <= 5'd2;
                    end
                    5'd2 : begin
                        Da   <= BCu ^ (BCe << 1) ^ (BCe >> (64-1));
                        De   <= BCa ^ (BCi << 1) ^ (BCi >> (64-1));   
                        Di   <= BCe ^ (BCo << 1) ^ (BCo >> (64-1));     
                        DoDo <= BCi ^ (BCu << 1) ^ (BCu >> (64-1));    
                        Du   <= BCo ^ (BCa << 1) ^ (BCa >> (64-1));
                        scnt <= 5'd3;  
                    end
                    5'd3 : begin
                        Aba <= Aba ^ Da;
                        Age <= Age ^ De;
                        Aki <= Aki ^ Di;
                        Amo <= Amo ^ DoDo;
                        Asu <= Asu ^ Du;  
                        Abo <= Abo ^ DoDo;
                        Agu <= Agu ^ Du;
                        Aka <= Aka ^ Da;
                        Ame <= Ame ^ De;
                        Asi <= Asi ^ Di;
                        Abe <= Abe ^ De;  
                        Agi <= Agi ^ Di;   
                        Ako <= Ako ^ DoDo; 
                        Amu <= Amu ^ Du;
                        Asa <= Asa ^ Da;
                        Abu <= Abu ^ Du;
                        Aga <= Aga ^ Da;
                        Ake <= Ake ^ De;
                        Ami <= Ami ^ Di;
                        Aso <= Aso ^ DoDo;
                        Abi <= Abi ^ Di;
                        Ago <= Ago ^ DoDo;
                        Aku <= Aku ^ Du;
                        Ama <= Ama ^ Da;
                        Ase <= Ase ^ De;
                        scnt <= 5'd4;
                    end
                    5'd4 : begin
                        BCa <= Aba;
                        BCe <= (Age << 44) ^ (Age >> (64-44));
                        BCi <= (Aki << 43) ^ (Aki >> (64-43));  
                        BCo <= (Amo << 21) ^ (Amo >> (64-21));
                        BCu <= (Asu << 14) ^ (Asu >> (64-14));
                        scnt <= 5'd5;
                    end
                    5'd5 : begin
                        Eba <= (BCa ^ ((~BCe) & BCi)) ^ round_constant[srnd];
                        Ebe <= BCe ^ ((~BCi) & BCo);
                        Ebi <= BCi ^ ((~BCo) & BCu);
                        Ebo <= BCo ^ ((~BCu) & BCa);
                        Ebu <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Abo << 28) ^ (Abo >> (64-28));     
                        BCe <= (Agu << 20) ^ (Agu >> (64-20));     
                        BCi <= (Aka <<  3) ^ (Aka >> (64-3 ));      
                        BCo <= (Ame << 45) ^ (Ame >> (64-45));    
                        BCu <= (Asi << 61) ^ (Asi >> (64-61));
                        scnt <= 5'd6;
                    end 
                    5'd6 : begin
                        Ega <= BCa ^ ((~BCe) & BCi);
                        Ege <= BCe ^ ((~BCi) & BCo);
                        Egi <= BCi ^ ((~BCo) & BCu);
                        Ego <= BCo ^ ((~BCu) & BCa);
                        Egu <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Abe << 1 ) ^ (Abe >> (64-1 ));
                        BCe <= (Agi << 6 ) ^ (Agi >> (64-6 ));
                        BCi <= (Ako << 25) ^ (Ako >> (64-25));
                        BCo <= (Amu << 8 ) ^ (Amu >> (64-8 ));
                        BCu <= (Asa << 18) ^ (Asa >> (64-18));
                        scnt <= 5'd7;    
                    end
                    5'd7 : begin
                        Eka <= BCa ^ ((~BCe) & BCi);
                        Eke <= BCe ^ ((~BCi) & BCo);
                        Eki <= BCi ^ ((~BCo) & BCu);
                        Eko <= BCo ^ ((~BCu) & BCa);
                        Eku <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Abu << 27) ^ (Abu >> (64-27));
                        BCe <= (Aga << 36) ^ (Aga >> (64-36));
                        BCi <= (Ake << 10) ^ (Ake >> (64-10));
                        BCo <= (Ami << 15) ^ (Ami >> (64-15));
                        BCu <= (Aso << 56) ^ (Aso >> (64-56));  
                        scnt <= 5'd8;
                    end
                    5'd8 : begin
                        Ema <= BCa ^ ((~BCe) & BCi);
                        Eme <= BCe ^ ((~BCi) & BCo);
                        Emi <= BCi ^ ((~BCo) & BCu);
                        Emo <= BCo ^ ((~BCu) & BCa);
                        Emu <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Abi << 62) ^ (Abi >> (64-62));     
                        BCe <= (Ago << 55) ^ (Ago >> (64-55));     
                        BCi <= (Aku << 39) ^ (Aku >> (64-39));     
                        BCo <= (Ama << 41) ^ (Ama >> (64-41));     
                        BCu <= (Ase << 2 ) ^ (Ase >> (64-2 )); 
                        scnt <= 5'd9;
                    end
                    5'd9 : begin
                        Esa <= BCa ^ ((~BCe) & BCi); 
                        Ese <= BCe ^ ((~BCi) & BCo);
                        Esi <= BCi ^ ((~BCo) & BCu);
                        Eso <= BCo ^ ((~BCu) & BCa);
                        Esu <= BCu ^ ((~BCa) & BCe);
                        scnt <= 5'd10;
                    end
                    5'd10 : begin
                        BCa <= Eba ^ Ega ^ Eka ^ Ema ^ Esa;
                        BCe <= Ebe ^ Ege ^ Eke ^ Eme ^ Ese;
                        BCi <= Ebi ^ Egi ^ Eki ^ Emi ^ Esi;
                        BCo <= Ebo ^ Ego ^ Eko ^ Emo ^ Eso;
                        BCu <= Ebu ^ Egu ^ Eku ^ Emu ^ Esu;
                        scnt <= 5'd11;
                    end
                    5'd11 : begin
                        Da   <= BCu ^ (BCe << 1) ^ (BCe >> (64-1));    
                        De   <= BCa ^ (BCi << 1) ^ (BCi >> (64-1));    
                        Di   <= BCe ^ (BCo << 1) ^ (BCo >> (64-1));    
                        DoDo <= BCi ^ (BCu << 1) ^ (BCu >> (64-1));  
                        Du   <= BCo ^ (BCa << 1) ^ (BCa >> (64-1)); 
                        scnt <= 5'd12;
                    end
                    5'd12 : begin
                        Eba <= Eba ^ Da;
                        Ege <= Ege ^ De;
                        Eki <= Eki ^ Di;
                        Emo <= Emo ^ DoDo;
                        Esu <= Esu ^ Du;
                        Ebo <= Ebo ^ DoDo;
                        Egu <= Egu ^ Du;
                        Eka <= Eka ^ Da;
                        Eme <= Eme ^ De;
                        Esi <= Esi ^ Di;
                        Ebe <= Ebe ^ De;    
                        Egi <= Egi ^ Di;    
                        Eko <= Eko ^ DoDo;  
                        Emu <= Emu ^ Du;    
                        Esa <= Esa ^ Da;
                        Ebu <= Ebu ^ Du;
                        Ega <= Ega ^ Da;
                        Eke <= Eke ^ De;
                        Emi <= Emi ^ Di;
                        Eso <= Eso ^ DoDo;
                        Ebi <= Ebi ^ Di;
                        Ego <= Ego ^ DoDo;
                        Eku <= Eku^ Du;
                        Ema <= Ema ^ Da;
                        Ese <= Ese ^ De;
                        scnt <= 5'd13;
                    end
                    5'd13 : begin
                        BCa <= Eba;
                        BCe <= (Ege << 44) ^ (Ege >> (64-44));   
                        BCi <= (Eki << 43) ^ (Eki >> (64-43));   
                        BCo <= (Emo << 21) ^ (Emo >> (64-21));   
                        BCu <= (Esu << 14) ^ (Esu >> (64-14));
                        scnt <= 5'd14;   
                    end
                    5'd14 : begin
                        Aba <= (BCa ^ ((~BCe) & BCi)) ^ round_constant[srnd+1];
                        Abe <=  BCe ^ ((~BCi) & BCo);
                        Abi <=  BCi ^ ((~BCo) & BCu);
                        Abo <=  BCo ^ ((~BCu) & BCa);
                        Abu <=  BCu ^ ((~BCa) & BCe);
                        BCa <= (Ebo << 28) ^ (Ebo >> (64-28));   
                        BCe <= (Egu << 20) ^ (Egu >> (64-20));   
                        BCi <= (Eka << 3 ) ^ (Eka >> (64-3 ));     
                        BCo <= (Eme << 45) ^ (Eme >> (64-45));   
                        BCu <= (Esi << 61) ^ (Esi >> (64-61));  
                        scnt <= 5'd15;
                    end
                    5'd15 : begin
                        Aga <= BCa ^ ((~BCe) & BCi);
                        Age <= BCe ^ ((~BCi) & BCo);
                        Agi <= BCi ^ ((~BCo) & BCu);
                        Ago <= BCo ^ ((~BCu) & BCa);
                        Agu <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Ebe << 1 ) ^ (Ebe >> (64-1 ));    
                        BCe <= (Egi << 6 ) ^ (Egi >> (64-6 ));    
                        BCi <= (Eko << 25) ^ (Eko >> (64-25));  
                        BCo <= (Emu << 8 ) ^ (Emu >> (64-8 ));    
                        BCu <= (Esa << 18) ^ (Esa >> (64-18));
                        scnt <= 5'd16;  
                    end
                    5'd16 : begin
                        Aka <= BCa ^ ((~BCe) & BCi);
                        Ake <= BCe ^ ((~BCi) & BCo);
                        Aki <= BCi ^ ((~BCo) & BCu);
                        Ako <= BCo ^ ((~BCu) & BCa);
                        Aku <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Ebu << 27) ^ (Ebu >> (64-27));  
                        BCe <= (Ega << 36) ^ (Ega >> (64-36));  
                        BCi <= (Eke << 10) ^ (Eke >> (64-10));  
                        BCo <= (Emi << 15) ^ (Emi >> (64-15)); 
                        BCu <= (Eso << 56) ^ (Eso >> (64-56));
                        scnt <= 5'd17;
                    end
                    5'd17 : begin            
                        Ama <= BCa ^ ((~BCe) & BCi);
                        Ame <= BCe ^ ((~BCi) & BCo);
                        Ami <= BCi ^ ((~BCo) & BCu);
                        Amo <= BCo ^ ((~BCu) & BCa);
                        Amu <= BCu ^ ((~BCa) & BCe);
                        BCa <= (Ebi << 62) ^ (Ebi >> (64-62));
                        BCe <= (Ego << 55) ^ (Ego >> (64-55)); 
                        BCi <= (Eku << 39) ^ (Eku >> (64-39));  
                        BCo <= (Ema << 41) ^ (Ema >> (64-41));
                        BCu <= (Ese << 2 ) ^ (Ese >> (64-2 ));
                        scnt <= 5'd18;
                    end
                    5'd18 : begin
                        Asa <= BCa ^ ((~BCe) & BCi);
                        Ase <= BCe ^ ((~BCi) & BCo);
                        Asi <= BCi ^ ((~BCo) & BCu);
                        Aso <= BCo ^ ((~BCu) & BCa);
                        Asu <= BCu ^ ((~BCa) & BCe);
                        srnd <= srnd + 2;
                        scnt <= 5'd19;
                    end
                    5'd19 : begin
                        if (srnd == 5'd24) begin
                            en <= 1'b0;
                            srnd <= 5'd0;
                            scnt <= 5'd0;
                            load <= 1'b1;
                        end
                        else begin
                            scnt <= 5'd1;   // Skip step 0 (loading into regs)
                        end
                    end
                    default : scnt <= 5'd0;
                endcase
            end
            else if (load) begin
                {sbuf[ 1], sbuf[ 0]} <= Aba;
                {sbuf[ 3], sbuf[ 2]} <= Abe;
                {sbuf[ 5], sbuf[ 4]} <= Abi;
                {sbuf[ 7], sbuf[ 6]} <= Abo;
                {sbuf[ 9], sbuf[ 8]} <= Abu;
                {sbuf[11], sbuf[10]} <= Aga;
                {sbuf[13], sbuf[12]} <= Age;
                {sbuf[15], sbuf[14]} <= Agi;
                {sbuf[17], sbuf[16]} <= Ago;
                {sbuf[19], sbuf[18]} <= Agu;
                {sbuf[21], sbuf[20]} <= Aka;  
                {sbuf[23], sbuf[22]} <= Ake;  
                {sbuf[25], sbuf[24]} <= Aki;  
                {sbuf[27], sbuf[26]} <= Ako;  
                {sbuf[29], sbuf[28]} <= Aku;  
                {sbuf[31], sbuf[30]} <= Ama;  
                {sbuf[33], sbuf[32]} <= Ame;  
                {sbuf[35], sbuf[34]} <= Ami;  
                {sbuf[37], sbuf[36]} <= Amo;  
                {sbuf[39], sbuf[38]} <= Amu;  
                {sbuf[41], sbuf[40]} <= Asa;  
                {sbuf[43], sbuf[42]} <= Ase;  
                {sbuf[45], sbuf[44]} <= Asi; 
                {sbuf[47], sbuf[46]} <= Aso;  
                {sbuf[49], sbuf[48]} <= Asu;
                load <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule