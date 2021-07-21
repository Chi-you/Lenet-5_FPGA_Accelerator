`define DATA_BITS 32
`define INTERNAL_BITS 8
module cnn(clk, 
           rst, 
           start, 
           done, 
           BRAM_IF_ADDR, 
           BRAM_W_ADDR, 
           BRAM_TEMP_ADDR, 
           BRAM_IF_WE, 
           BRAM_W_WE, 
           BRAM_TEMP_WE, 
           BRAM_IF_EN, 
           BRAM_W_EN, 
           BRAM_TEMP_EN, 
           BRAM_IF_RST, 
           BRAM_W_RST, 
           BRAM_TEMP_RST, 
           BRAM_IF_DOUT, 
           BRAM_W_DOUT, 
           BRAM_TEMP_DOUT, 
           BRAM_IF_DIN, 
           BRAM_W_DIN, 
           BRAM_TEMP_DIN
);
  input clk;
  input rst;
  input start;
  output done;
  output [`DATA_BITS-1:0] BRAM_IF_ADDR, BRAM_W_ADDR, BRAM_TEMP_ADDR; // address
  output [3:0] BRAM_IF_WE, BRAM_W_WE, BRAM_TEMP_WE; // write or read
  output BRAM_IF_EN, BRAM_W_EN, BRAM_TEMP_EN; // enable
  output BRAM_IF_RST, BRAM_W_RST, BRAM_TEMP_RST;  // reset
  input  [`DATA_BITS-1:0] BRAM_IF_DOUT, BRAM_W_DOUT, BRAM_TEMP_DOUT; // data out
  output [`DATA_BITS-1:0] BRAM_IF_DIN, BRAM_W_DIN, BRAM_TEMP_DIN; // data in

  integer i, j;
  reg [7:0] PE_in [0:24];

  reg [7:0] i_cache [0:47]; // 8 x 6 => 48 * 8 = 512
  reg [7:0] w_cache [0:199]; // 8 * 200 = 1600 


  reg [5:0] icache_indx; // range: 0 ~ 63

  wire rst_sram_w_indx;
  reg [7:0] wcache_indx;  // 0 ~ 255

  reg [3:0] state, n_state;

  reg [3:0] layer;

  reg w_ready;
  reg [2:0] x, y; // 8 * 8
  reg [2:0] base_addr_r; 
  reg [7:0] base_addr_c;
  // layer
  // parameter conv1 = 1,
  //           conv2 = 2,
  //           conv3 = 3,
  //           fc1   = 4,
  //           fc2   = 5;

  // FSM:
  parameter IDLE        = 0,
            RD_BRTCH1   = 1,    // read bram to cache (16 cycle)
            RD_BRTCH2   = 2,    // read bram to cache (34 cycle) total 50 cycle (weight)
            READ24      = 3,
            READ_TILE1  = 4,
            READ_TILE2  = 5,
            READ_TILE3  = 6,
            READ_TILE4  = 7,
            READ_TILE5  = 8,
            READ_TILE6  = 9,
            READ_TILE7  = 10,
            READ_TILE8  = 11,
            /*
            READ_TILE9  = ,
            READ_TILE10 = ,
            READ_TILE11 = ,
            READ_TILE12 = ,
            READ_TILE13 = ,
            READ_TILE14 = ,
            READ_TILE15 = ,
            READ_TILE16 = ,            
            */
            EXE         = 12,
            MX_PL       = 13,
            WR_BRAM     = 14,
            DONE        = 15;

  assign done = (state == DONE);

/*
  READ TILE:   1  2  3  4 
               5  6  7  8 


  order: 1 2 5 6 -> 3 4 7 8 
*/  

  always @(posedge clk, posedge rst) begin
    if(rst) state <= IDLE;
    else state <= n_state;
  end

 // 1. 沒有跳到 3 4 7 8 
 // 2. write_temp 
  // next state logic
  always @(*) begin
    case (state)
      IDLE:        n_state = (start) ? RD_BRTCH1 : IDLE;
      RD_BRTCH1:   n_state = (counter == 11) ? ((w_ready) ? READ_TILE1 : RD_BRTCH2) : RD_BRTCH1;  
      RD_BRTCH2:   n_state = (counter == 37) ? READ_TILE1 : RD_BRTCH2;
      READ24:      n_state = (counter == 5)  ? READ_TILE1 : READ24;  // repeat 6 times -> RD_BRTCH1
      READ_TILE1:  n_state = READ_TILE2; 
      READ_TILE2:  n_state = READ_TILE5; 
      READ_TILE3:  n_state = READ_TILE4; 
      READ_TILE4:  n_state = READ_TILE7; 
      READ_TILE5:  n_state = READ_TILE6; 
      READ_TILE6:  n_state = EXE;
      READ_TILE7:  n_state = READ_TILE8; 
      READ_TILE8:  n_state = EXE;
      /*
      READ_TILE9:  n_state = READ_TILE10;
      READ_TILE10: n_state = READ_TILE13;
      READ_TILE11: n_state = READ_TILE12;
      READ_TILE12: n_state = READ_TILE15;
      READ_TILE13: n_state = READ_TILE14;
      READ_TILE14: n_state = EXE;
      READ_TILE15: n_state = READ_TILE16;
      READ_TILE16: n_state = EXE;
      */
      EXE:         n_state = (counter == 2) ? MX_PL : EXE;
      MX_PL1:      n_state = (counter == 5) ? READ_TILE3 : MX_PL1;  // repeat 6 times -> RD_BRTCH1
      MX_PL2:      n_state = (counter == 5) ? WRITE_TEMP : MX_PL2;
      WRITE_TEMP:  n_state = (counter == 2) ? ((cnt_rd24 == 6) ? RD_BRTCH1 : READ24) : WRITE_TEMP;
      default:     n_state = IDLE;
    endcase
  end

  always @(posedge clk or posedge rst) begin
    if(rst) w_ready <= 0;
    else begin
      if(state == RD_BRTCH2) w_ready <= 1;
    end
  end


  reg [2:0] cnt_rd24;
  always @(posedge clk or posedge rst) begin
    if(rst) cnt_rd24 <= 0;
    else begin
      if(state == READ24 && counter == 1) cnt_rd24 <= cnt_rd24 + 1;
      else if(state == RD_BRTCH1) cnt_rd24 <= 0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) counter <= 0;
    else begin
      if((state == RD_BRTCH1 && counter <= 10) || (state == RD_BRTCH2 && counter <= 36) || 
         (state == READ24 && counter <= 4) || ((state == MX_PL1 || state == MX_PL2) && counter <= 4)) 
        counter <= counter + 1;
      else counter <= 0; // (state == RD_BRTCH1 && counter == 11) || (state == RD_BRTCH2 && counter == 37)
  end

  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 48; i=i+1) i_cache[i] <= 0;
    end 
    else begin
      if(state == READ24) begin
        if(counter == 0) begin // 上到下
          for(i = 0; i < 41; i=i+8) i_cache[i] <= i_chahe[i+4];
          for(i = 1; i < 42; i=i+8) i_cache[i] <= i_chahe[i+4];
          for(i = 2; i < 43; i=i+8) i_cache[i] <= i_chahe[i+4];
          for(i = 3; i < 44; i=i+8) i_cache[i] <= i_chahe[i+4];
          i_cache[4]  <= BRAM_IF_DOUT[31-:8];
          i_cache[5]  <= BRAM_IF_DOUT[23-:8];
          i_cache[6]  <= BRAM_IF_DOUT[15-:8];
          i_cache[7]  <= BRAM_IF_DOUT[ 7-:8];
        end
        else if(counter == 1) begin
          i_cache[12] <= BRAM_IF_DOUT[31-:8];
          i_cache[13] <= BRAM_IF_DOUT[23-:8];
          i_cache[14] <= BRAM_IF_DOUT[15-:8];
          i_cache[15] <= BRAM_IF_DOUT[ 7-:8];
        end
        else if(counter == 2) begin
          i_cache[20] <= BRAM_IF_DOUT[31-:8];
          i_cache[21] <= BRAM_IF_DOUT[23-:8];
          i_cache[22] <= BRAM_IF_DOUT[15-:8];
          i_cache[23] <= BRAM_IF_DOUT[ 7-:8];
        end
        else if(counter == 3) begin
          i_cache[28] <= BRAM_IF_DOUT[31-:8];
          i_cache[29] <= BRAM_IF_DOUT[23-:8];
          i_cache[30] <= BRAM_IF_DOUT[15-:8];
          i_cache[31] <= BRAM_IF_DOUT[ 7-:8];
        end
        else if(counter == 4) begin
          i_cache[36] <= BRAM_IF_DOUT[31-:8];
          i_cache[37] <= BRAM_IF_DOUT[23-:8];
          i_cache[38] <= BRAM_IF_DOUT[15-:8];
          i_cache[39] <= BRAM_IF_DOUT[ 7-:8];
        end
        else if(counter == 5) begin
          i_cache[44] <= BRAM_IF_DOUT[31-:8];
          i_cache[45] <= BRAM_IF_DOUT[23-:8];
          i_cache[46] <= BRAM_IF_DOUT[15-:8];
          i_cache[47] <= BRAM_IF_DOUT[ 7-:8];
        end                              
      end 
      else if(state == RD_BRTCH1) {i_cache[icache_indx], i_cache[icache_indx+1], i_cache[icache_indx+2], i_cache[icache_indx+3]} <= BRAM_IF_DOUT; // 12 cycle (initial)
    end
  end

  // BRAM_TEMP_ADDR (在mxpl state 就要將data準備好)
  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_TEMP_ADDR <= 0;
    else begin
      if(state == WRITE_TEMP) begin
        BRAM_TEMP_ADDR <= BRAM_TEMP_ADDR + 1;
      end
    end
  end

  // BRAM_IF_ADDR
  always @(posedge clk or posedge rst) begin
    if(rst) begin x <= 0; y <= 0; end
    else begin
      if(state == RD_BRTCH1 || state == READ24) begin
        x <= x + 1;
        if(x == 1) begin
          y <= y + 1;
          x <= 0;
        end
      end
    end
  end


  assign BRAM_IF_ADDR = base_addr_r + base_addr_c + {y, x};

  always @(posedge clk or posedge rst) begin
    if(rst) base_addr_r <= 0;
    else begin
      if(state == READ24 && counter == 0) base_addr_r <= base_addr_r + 1;
      else if(state == READ24 && cnt_rd24 < 6) base_addr_r <= 2;
      else if(state == RD_BRTCH1) base_addr_r <= 0;
    end
  end

  always @(posedge clk or posedge rst) begin
    if(rst) base_addr_c <= 0;
    else begin
      if(state == READ24 && cnt_rd24 == 6) base_addr_c <= base_addr_c + 16;
    end
  end


  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(i = 0; i < 200; i=i+1) w_cache[i] <= 0; 
    end
    else begin
      if(state == RD_BRTCH1 || state == RD_BRTCH2) {w_cache[wcache_indx], w_cache[wcache_indx+1], w_cache[wcache_indx+2], w_cache[wcache_indx+3]} <= BRAM_W_DOUT; // 改為4筆資料一行 => 50 cycle
    end
  end

  // BRAM_W_ADDR: 25 * 8
  always @(posedge clk or posedge rst) begin
    if(rst) BRAM_W_ADDR <= 0;
    else begin
      if(state == RD_BRTCH1 || state == RD_BRTCH2) BRAM_W_ADDR <= BRAM_W_ADDR + 1;
    end
  end

  // wcache_indx
  always @(posedge clk or posedge rst) begin
    if(rst) wcache_indx <= 0;
    else begin
      if(state == RD_BRTCH1 || state == RD_BRTCH2) wcache_indx <= wcache_indx + 4;
    end
  end

  // icache_indx
  always @(posedge clk or posedge rst) begin
    if(rst) icache_indx <= 0;
    else begin
      if(state == RD_BRTCH1) icache_indx <= icache_indx + 4;
    end
  end


  // layer
  // always @(*) begin
  //   case (state)
  //     : layer = 1; // conv1 
  //     : layer = 2; // conv2
  //     : layer = 3; // conv3
  //     : layer = 4; // fc1
  //     : layer = 5; // fc2
  //     default: 
  //   endcase
  // end

/*        
  o o o o o o o o   0  1  2  3  4  5  6  7
  o o o o o o o o   8  9 10 11 12 13 14 15 
  o o o o o o o o  16 17 18 19 20 21 22 23 
  o o o o o o o o  24 25 26 27 28 29 30 31
  o o o o o o o o  32 33 34 35 36 37 38 39
  o o o o o o o o  40 41 42 43 44 45 46 47
  o o o o o o o o  48 49 50 51 52 53 54 55
  o o o o o o o o  56 57 58 59 60 61 62 63
*/

  assign shift_sram_en = (state == READ_TILE6 || state == READ_TILE8 || state == READ_TILE14 || state == READ_TILE16 || state == EXE);

  // PE_in
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 25; i=i+1) PE_in[i] <= 0;
    else begin
      case(state)
        READ_TILE1: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j];
            end
          end
        end
        READ_TILE2: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+1];
            end
          end
        end
        READ_TILE3: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+2];
            end
          end        
        end
        READ_TILE4: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+3];
            end
          end
        end
        READ_TILE5: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+8];
            end
          end
        end
        READ_TILE6: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+9];
            end
          end
        end
        READ_TILE7: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+10];
            end
          end
        end
        READ_TILE8: begin
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+11];
            end
          end
        end
        /*
        READ_TILE9: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+16];
            end
          end
        READ_TILE10: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+17];
            end
          end
        READ_TILE11: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+18];
            end
          end
        READ_TILE12: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+19];
            end
          end
        READ_TILE13: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+24];
            end
          end
        READ_TILE14: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+25];
            end
          end
        READ_TILE15: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+26];
            end
          end
        READ_TILE16: 
          for(j = 0; j < 5; j=j+1) begin
            for(i = 0; i < 5; i=i+1) begin
              PE_in[i+5*j] <= i_cache[i+8*j+27];
            end
          end          
        */                                                      
        default: for(i = 0; i < 25; i=i+1) PE_in[i] = 0;
      endcase
    end
  end

  reg [31:0] pe_out  [0:7];

  reg [31:0] pe_sram [0:7][0:3]; // 32 * 32 = 1024
  


  always @(posedge clk or posedge rst) begin
    if(rst) begin
      for(j = 0; j < 8; j=j+1) begin
        for(i = 0; i < 4; i=i+1) begin
          pe_sram[j][i] <= 0;
        end
      end
    end
    else begin
      if(shift_sram_en) begin
        for(j = 0; j < 8; j=j+1) pe_sram[j][0] <= pe_out[j];
        for(j = 0; j < 8; j=j+1) begin
          for(i = 0; i < 3; i=i+1) begin
            pe_sram[j][i+1] <= pe_sram[j][i];
          end
        end
      end // if-end
    end
  end
  // ======================================== PE =====================================================================
  genvar a; 
	generate 
    for (a = 0; a < 8; a = a + 1) begin: pe_array 										
      PE PE_Array(.in_IF1 (PE_in[0] ), 
                  .in_IF2 (PE_in[1] ), 
                  .in_IF3 (PE_in[2] ), 
                  .in_IF4 (PE_in[3] ), 
                  .in_IF5 (PE_in[4] ), 
                  .in_IF6 (PE_in[5] ), 
                  .in_IF7 (PE_in[6] ), 
                  .in_IF8 (PE_in[7] ), 
                  .in_IF9 (PE_in[8] ), 
                  .in_IF10(PE_in[9] ), 
                  .in_IF11(PE_in[10]), 
                  .in_IF12(PE_in[11]), 
                  .in_IF13(PE_in[12]), 
                  .in_IF14(PE_in[13]), 
                  .in_IF15(PE_in[14]), 
                  .in_IF16(PE_in[15]), 
                  .in_IF17(PE_in[16]), 
                  .in_IF18(PE_in[17]), 
                  .in_IF19(PE_in[18]), 
                  .in_IF20(PE_in[19]), 
                  .in_IF21(PE_in[20]), 
                  .in_IF22(PE_in[21]), 
                  .in_IF23(PE_in[22]), 
                  .in_IF24(PE_in[23]), 
                  .in_IF25(PE_in[24]), 

                  .in_W1 (w_cache[a*25+0 ]), 
                  .in_W2 (w_cache[a*25+1 ]), 
                  .in_W3 (w_cache[a*25+2 ]), 
                  .in_W4 (w_cache[a*25+3 ]), 
                  .in_W5 (w_cache[a*25+4 ]), 
                  .in_W6 (w_cache[a*25+5 ]), 
                  .in_W7 (w_cache[a*25+6 ]), 
                  .in_W8 (w_cache[a*25+7 ]), 
                  .in_W9 (w_cache[a*25+8 ]), 
                  .in_W10(w_cache[a*25+9 ]), 
                  .in_W11(w_cache[a*25+10]), 
                  .in_W12(w_cache[a*25+11]), 
                  .in_W13(w_cache[a*25+12]), 
                  .in_W14(w_cache[a*25+13]), 
                  .in_W15(w_cache[a*25+14]), 
                  .in_W16(w_cache[a*25+15]), 
                  .in_W17(w_cache[a*25+16]), 
                  .in_W18(w_cache[a*25+17]), 
                  .in_W19(w_cache[a*25+18]), 
                  .in_W20(w_cache[a*25+19]), 
                  .in_W21(w_cache[a*25+20]), 
                  .in_W22(w_cache[a*25+21]), 
                  .in_W23(w_cache[a*25+22]), 
                  .in_W24(w_cache[a*25+23]), 
                  .in_W25(w_cache[a*25+24]),
                  .rst(rst), 
                  .clk(clk),
                  .relu_en(relu_en),
                  .quan_en(quan_en),
                  .pe_out(pe_out[a]),
                  .en(pe_en)
                );	
    end
	endgenerate
// ============================================================================================
  assign relu_en = 1;
  assign quan_en = 1;
  assign sft_mx_pl_reg = (state == MX_PL1 || state == MX_PL2);

  reg [7:0] temp1, temp2, mx_pl_out;
// maxpooling
  always @(*) begin // 1 cycle
    temp1     = (pe_sram[pe_sram_indx_j][0] > pe_sram[pe_sram_indx_j][1]) ? pe_sram[pe_sram_indx_j][0] : pe_sram[pe_sram_indx_j][1];
    temp2     = (pe_sram[pe_sram_indx_j][2] > temp1)         ? pe_sram[pe_sram_indx_j][2] : temp1;
    mx_pl_out = (pe_sram[pe_sram_indx_j][3] > temp2)         ? pe_sram[pe_sram_indx_j][3] : temp2;
  end

  reg [7:0] mx_pl_reg [0:11];
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 8; i=i+1) mx_pl_reg[i] <= 0;
    else begin
      if(sft_mx_pl_reg) begin
        mx_pl_reg[0] <= mx_pl_out;
        for(i = 0; i < 11; i=i+1) begin
          mx_pl_reg[i+1] <= mx_pl_reg[i]; 
        end
      end
    end
  end 

  always @(posedge clk or posedge rst) begin
    if(rst) pe_sram_indx_j <= 0;
    else begin
      if(state == MX_PL1 || state == MX_PL2) pe_sram_indx_j <= pe_sram_indx_j + 1;
    end
  end

  assgin pe_en = (state == READ_TILE1 || state == READ_TILE2 || state == READ_TILE3 || state == READ_TILE4 || 
                  state == READ_TILE5 || state == READ_TILE6 || state == READ_TILE7 || state == READ_TILE8 || state == EXE);


  // BR AM_TEMP_DIN
  // assign  BRAM_TEMP_DIN = mx_pl_out; (4 個一組)




endmodule

// pe_en**
// 2 cycle
module PE(rst,
          clk,
          en,
          pe_out,
          relu_en,
          quan_en,
          in_IF1,
          in_IF2,
          in_IF3,
          in_IF4,
          in_IF5,
          in_IF6,
          in_IF7,
          in_IF8,
          in_IF9,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF1,
          in_IF2,
          in_IF2,
          in_IF2,
          in_IF2,
          in_IF2,
          in_IF2,
          in_W1,
          in_W2,
          in_W3,
          in_W4,
          in_W5,
          in_W6,
          in_W7,
          in_W8,
          in_W9,
          in_W10,
          in_W11,
          in_W12,
          in_W13,
          in_W14,
          in_W15,
          in_W16,
          in_W17,
          in_W18,
          in_W19,
          in_W20,
          in_W21,
          in_W22,
          in_W23,
          in_W24,
          in_W25
);

  input rst;
  input clk;
  input relu_en;
  input quan_en;
  output [31:0] pe_out; // if quantize, pe_out will be 8 bits ([14:7]) or 32 bits
  input [7:0] in_IF1;
  input [7:0] in_IF2;
  input [7:0] in_IF3;
  input [7:0] in_IF4;
  input [7:0] in_IF5;
  input [7:0] in_IF6;
  input [7:0] in_IF7;
  input [7:0] in_IF8;
  input [7:0] in_IF9;
  input [7:0] in_IF10;
  input [7:0] in_IF11;
  input [7:0] in_IF12;
  input [7:0] in_IF13;
  input [7:0] in_IF14;
  input [7:0] in_IF15;
  input [7:0] in_IF16;
  input [7:0] in_IF17;
  input [7:0] in_IF18;
  input [7:0] in_IF19;
  input [7:0] in_IF20;
  input [7:0] in_IF21;
  input [7:0] in_IF22;
  input [7:0] in_IF23;
  input [7:0] in_IF24;
  input [7:0] in_IF25;

  input [7:0] in_W1;
  input [7:0] in_W2;
  input [7:0] in_W3;
  input [7:0] in_W4;
  input [7:0] in_W5;
  input [7:0] in_W6;
  input [7:0] in_W7;
  input [7:0] in_W8;
  input [7:0] in_W9;
  input [7:0] in_W10;
  input [7:0] in_W11;
  input [7:0] in_W12;
  input [7:0] in_W13;
  input [7:0] in_W14;
  input [7:0] in_W15;
  input [7:0] in_W16;
  input [7:0] in_W17;
  input [7:0] in_W18;
  input [7:0] in_W19;
  input [7:0] in_W20;
  input [7:0] in_W21;
  input [7:0] in_W22;
  input [7:0] in_W23;
  input [7:0] in_W24;
  input [7:0] in_W25;

  reg signed [7:0] mul_if [0:24];  // 25 * 8 = 200
  reg signed [7:0] mul_w [0:24]; 
  integer i;

  reg signed [31:0] sum;
  reg signed [31:0] mul [0:24]; // 25 * 32 = 800

  // 乘法器
  always @(posedge clk or posedge rst) begin
    if(rst) for(i = 0; i < 25; i=i+1) mul[i] <= 0;
    else begin
      mul[0]  <= in_IF1  * in_W1;
      mul[1]  <= in_IF2  * in_W2;
      mul[2]  <= in_IF3  * in_W3;
      mul[3]  <= in_IF4  * in_W4;
      mul[4]  <= in_IF5  * in_W5;
      mul[5]  <= in_IF6  * in_W6;
      mul[6]  <= in_IF7  * in_W7;
      mul[7]  <= in_IF8  * in_W8;
      mul[8]  <= in_IF9  * in_W9;
      mul[9]  <= in_IF10 * in_W10;
      mul[10] <= in_IF11 * in_W11;
      mul[11] <= in_IF12 * in_W12;
      mul[12] <= in_IF13 * in_W13;
      mul[13] <= in_IF14 * in_W14;
      mul[14] <= in_IF15 * in_W15;
      mul[15] <= in_IF16 * in_W16;
      mul[16] <= in_IF17 * in_W17;
      mul[17] <= in_IF18 * in_W18;
      mul[18] <= in_IF19 * in_W19;
      mul[19] <= in_IF20 * in_W20;
      mul[20] <= in_IF21 * in_W21;
      mul[21] <= in_IF22 * in_W22;
      mul[22] <= in_IF23 * in_W23;
      mul[23] <= in_IF24 * in_W24;
      mul[24] <= in_IF25 * in_W25;
    end
  end

  // 加法器
  always @(posedge clk) begin
    sum <= ((mul[1]  + mul[2])  + (mul[3]  + mul[4]) ) + 
           ((mul[5]  + mul[6])  + (mul[7]  + mul[8]) ) +
           ((mul[9]  + mul[10]) + (mul[11] + mul[12])) +
           ((mul[13] + mul[14]) + (mul[15] + mul[16])) +
           ((mul[17] + mul[18]) + (mul[19] + mul[20])) +
           ((mul[21] + mul[22]) + (mul[23] + mul[24])) +
           (mul[25]);
  end

  assign relu_out = (relu_en) ? ((sum < 0) ? 0 : sum) : sum;
  assign pe_out = (quan_en) ? (relu_out[14:7] + relu_out[6]) : relu_out; 

endmodule