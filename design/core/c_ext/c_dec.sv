module c_dec
			(
                input[15:0] ins_16,
			    output reg [31:0] ins_32
			);

always_comb
begin
	ins_32 = 0;
	case({ins_16[15:13],ins_16[1:0]})
/////************************************************  Q1 *******************************//.				
	5'b000_00: begin	//C.addi4sp  checked
				ins_32[6:0] = 7'b0010011; //opcode
				ins_32[11:7] = {2'b01,ins_16[4:2]}; //rd
				ins_32[14:12] = 3'b000; //funct3
				ins_32[19:15]  = 5'h2; //rs
				ins_32[31:20] = {ins_16[10:7],ins_16[12:11],ins_16[5],ins_16[6],2'b00}; //imm[11:0]
				end	
	5'b010_00: begin //C.lw checked
				ins_32[6:0] = 7'b0000011; 			//opcode
				ins_32[11:7] = {2'b01,ins_16[4:2]}; //rd
				ins_32[14:12] = 3'b010; 			//funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rd
				ins_32[31:20] = {5'h0,ins_16[5],ins_16[12:10],ins_16[6],2'b0}; //imm
				end
	5'b011_00: begin //C.flw 
				ins_32[6:0] = 7'b0000111; 			//opcode
				ins_32[11:7] = {2'b01,ins_16[4:2]}; //rd
				ins_32[14:12] = 3'b010; 			//funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs
				ins_32[31:20] = {5'h0,ins_16[5],ins_16[12:10],ins_16[6],2'b0}; //imm
				end
	5'b110_00: begin //C.sw checked
				ins_32[6:0] = 7'b0100011; //opcode
				ins_32[11:7] = {ins_16[11:10],ins_16[6],2'b00}; //imm 4:0
				ins_32[14:12] = 3'b010; //funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
				ins_32[24:20] =  {2'b01,ins_16[4:2]}; //rs2
				ins_32[31:25] =  {5'h0,ins_16[5],ins_16[12]};	//imm 11:5
				end
	5'b111_00: begin //C.fsw 
				ins_32[6:0] = 7'b0100111 ; //opcode
				ins_32[11:7] = {ins_16[11:10],ins_16[6],2'b0}; //imm 4:0
				ins_32[14:12] = 3'b010; //funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
				ins_32[24:20] =  {2'b01,ins_16[4:2]}; //rs2
				ins_32[31:25] =  {5'h0,ins_16[5],ins_16[12]};	//imm 11:5
				end
/////************************************************  Q1 *******************************//.				
				
	5'b000_01: begin //C.addi	checked
				ins_32[6:0] = 7'b0010011; //opcode
				ins_32[11:7] = ins_16[11:7]; //rd
				ins_32[14:12] = 3'b000; //funct3
				ins_32[19:15]  = ins_16[11:7]; //rs
				ins_32[31:20] = {{6{ins_16[12]}},ins_16[12],ins_16[6:2]}; //imm[11:0]
				end
	5'b001_01: begin //C.JAL --> checked
				ins_32[6:0] = 7'b1101111; //opcode
				ins_32[11:7] = 5'h1; //rd
				ins_32[19:12] = {8{ins_16[12]}};	//imm[19:12]
				ins_32[20]= {ins_16[12]}; //imm[11]
				ins_32[30:21] = {ins_16[8],ins_16[10:9],ins_16[6],ins_16[7],ins_16[2],ins_16[11],ins_16[5:3]};
				ins_32[31] = ins_16[12];
				end
	5'b010_01: begin //C.LI --> checked
				ins_32[6:0] = 7'b0010011; //opcode
				ins_32[11:7] = ins_16[11:7]; //rd
				ins_32[14:12] = 3'b000; //funct3
				ins_32[19:15]  = 5'h0; //rs
				ins_32[31:20] = {{6{ins_16[12]}},ins_16[12],ins_16[6:2]}; //imm[11:0]			
				end
	5'b011_01: begin 
					if(ins_16[11:7] == 2)
							begin	//ADDI16Sp checked
								ins_32[6:0] = 7'b0010011; //opcode
								ins_32[11:7] = 2; //rd
								ins_32[14:12] = 3'b000; //funct3
								ins_32[19:15]  = 2; //rs
								ins_32[31:20] = {{3{ins_16[12]}},ins_16[4:3],ins_16[5],ins_16[2],ins_16[6],4'b0000}; //imm[11:0]
							end
							else begin //C.LUI 		checked
								ins_32[6:0] = 7'b0110111; //opcode
								ins_32[11:7] = ins_16[11:7]; //rd
								ins_32[31:12] = {{14{ins_16[12]}},ins_16[12],ins_16[6:2]};//imm[] 
							end
				end
	5'b100_01: begin //MISC ALU
					case(ins_16[11:10])
					2'b00: begin //SRLI checked
								ins_32[6:0] = 7'b0010011; //opcode
								ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
								ins_32[14:12] = 3'b101; //funct3
								ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs
								ins_32[31:20] = {6'h0,ins_16[12],ins_16[6:2]}; //imm[11:0]
							 end
					2'b01: begin //SRAI checked
								ins_32[6:0] = 7'b0010011; //opcode
								ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
								ins_32[14:12] = 3'b101; //funct3
								ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs
								ins_32[25:20] = {ins_16[12],ins_16[6:2]}; //shamt
								ins_32[31:26] = {6'h10}; //
							 end
					2'b10: begin //ANDI checked
								ins_32[6:0] = 7'b0010011; //opcode
								ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
								ins_32[14:12] = 3'b111; //funct3
								ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs
								ins_32[31:20] = {{6{ins_16[12]}},ins_16[12],ins_16[6:2]}; //imm[11:0]
							 end
					2'b11: begin	//inception
								case(ins_16[6:5])
								2'b00: begin //C.SUB  checked
										 	ins_32[6:0] = 7'b0110011; //opcode
											ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
											ins_32[14:12] = 3'b000; //funct3
											ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
											ins_32[24:20]  = {2'b01,ins_16[4:2]}; //rs2
											ins_32[31:25] = 7'h20;//imm[11:0]
										 end
								2'b01: begin //C.XOR checked
										 	ins_32[6:0] = 7'b0110011; //opcode
											ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
											ins_32[14:12] = 3'b100; //funct3
											ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
											ins_32[24:20]  = {2'b01,ins_16[4:2]}; //rs2
											ins_32[31:24] = 7'h00;//imm[11:0]
										 end
								2'b10: begin //C.OR checked
										 	ins_32[6:0] = 7'b0110011; //opcode
											ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
											ins_32[14:12] = 3'b110 ; //funct3
											ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
											ins_32[24:20]  = {2'b01,ins_16[4:2]}; //rs2
											ins_32[31:24] = 7'h00;//imm[11:0]
										 end
								2'b11: begin //C.AND checked
										 	ins_32[6:0] = 7'b0110011; //opcode
											ins_32[11:7] = {2'b01,ins_16[9:7]}; //rd
											ins_32[14:12] = 3'b111 ; //funct3
											ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
											ins_32[24:20]  = {2'b01,ins_16[4:2]}; //rs2
											ins_32[31:24] = 7'h00;//imm[11:0]
										 end
								endcase
							 end
					endcase
				end
	5'b101_01: begin //C.J 			checked
				ins_32[6:0] = 7'b1101111; //opcode
				ins_32[11:7] = 5'h0; //rd
				ins_32[19:12] = {8{ins_16[12]}};	//imm[19:12]
				ins_32[20]= {ins_16[12]}; //imm[11]
				ins_32[30:21] = {ins_16[8],ins_16[10:9],ins_16[6],ins_16[7],ins_16[2],ins_16[11],ins_16[5:3]}; //imm[10:1]
				ins_32[31] = ins_16[12];//imm[20]
				end
	5'b110_01: begin //C.BEQZ  checked
				ins_32[6:0] = 7'b1100011; //opcode
				ins_32[11:7] = {ins_16[11:10],ins_16[4:3],ins_16[12]}; //imm4:1 , 11
				ins_32[14:12] = 3'b000; //funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
				ins_32[24:20]  = 0;//rs2
				ins_32[31:25] = {{3{ins_16[12]}},ins_16[12],ins_16[6:5],ins_16[2]}; //imm12 , 10:5
				end
	5'b111_01: begin //C.BNEZ checked
				ins_32[6:0] = 7'b1100011; //opcode
				ins_32[11:7] = {ins_16[11:10],ins_16[4:3],ins_16[12]}; //imm4:1 , 11
				ins_32[14:12] = 3'b001; //funct3
				ins_32[19:15]  = {2'b01,ins_16[9:7]}; //rs1
				ins_32[24:20]  = 0; //rs2
				ins_32[31:25] = {{3{ins_16[12]}},ins_16[12],ins_16[6:5],ins_16[2]}; //imm12 , 10:5
				end
/////************************************************  Q2 *******************************//.				
	5'b000_10: begin //C.SLLI			checked
				ins_32[6:0] = 7'b0010011; //opcode
				ins_32[11:7] = ins_16[11:7]; //rd
				ins_32[14:12] = 3'b001; //funct3
				ins_32[19:15]  = ins_16[11:7]; //rs
				ins_32[31:20] = {6'h0,ins_16[12],ins_16[6:2]}; //imm[11:0]
				end
	5'b010_10: begin //C.lwsp	checked
				ins_32[6:0] = 7'b0000011; 			//opcode
				ins_32[11:7] = ins_16[11:7]; 		//rd
				ins_32[14:12] = 3'b010; 			//funct3
				ins_32[19:15]  = 5'h2;				//rs1
				ins_32[31:20] = {4'h0,ins_16[3:2],ins_16[12],ins_16[6:4],2'b0}; //imm
				end
	5'b011_10: begin //C.flwsp	
				ins_32[6:0] = 7'b0000111; 			//opcode
				ins_32[11:7] =ins_16[11:7]; 		//rd
				ins_32[14:12] = 3'b010; 			//funct3
				ins_32[19:15]  = 5'h2;				//sp
				ins_32[31:20] = {4'h0,ins_16[3:2],ins_16[12],ins_16[6:4],2'b0}; //imm
				end
	5'b100_10: begin //C.Jr ....	
				case(ins_16[12])
				0:begin
					if(ins_16[6:2] == 0) begin	//C.JR checked
						ins_32[6:0] = 7'b1100111; //opcode
						ins_32[11:7] = 0; //rd = 0
						ins_32[14:12] = 3'b000; //func3
						ins_32[19:15] = ins_16[11:7]; //rs1
						ins_32[31:20] = 11'h0; //imm = 0
					end else begin //C.mv checked
						ins_32[6:0] = 7'b0110011; //opcode
						ins_32[11:7] = ins_16[11:7]; //rd
						ins_32[14:12] = 3'b000 ; //funct3
						ins_32[19:15]  = 0; //rs1 = 0
						ins_32[24:20]  =  ins_16[6:2]; //rs2
						ins_32[31:25] = 7'h00;//imm[11:0]
					end
				end
				1:if((ins_16[11:7] | ins_16[6:2]) == 0) 
				begin//C.Ebreak
					ins_32[6:0] = 7'b1110011; //opcode
					ins_32[19:7] = 0;
					ins_32[31:20] = 12'd1;
				end else begin
					if( ins_16[6:2] == 0) begin //C.jalr checked
					ins_32[6:0] = 7'b1100111; //opcode
					ins_32[11:7] = 5'h1; //rd = x1
					ins_32[14:12] = 2'b00;	//func3
					ins_32[19:15] = ins_16[11:7];	//rs1
					ins_32[31:20] = 11'b0; //imm = 0 
					end else begin 	//C.add	checked
					ins_32[6:0] = 7'b0110011; //opcode
					ins_32[11:7] = ins_16[11:7]; //rd
					ins_32[14:12] = 3'b000 ; //funct3
					ins_32[19:15]  =  ins_16[11:7]; //rs1 = rd
					ins_32[24:20]  =  ins_16[6:2]; //rs2
					ins_32[31:25] = 7'h00;//imm[11:0]							
					end
				end

				endcase
				end
	5'b110_10: begin //C.swsp checked
				ins_32[6:0] = 7'b0100011; //opcode
				ins_32[11:7] = {ins_16[11:9],2'b0}; //imm 4:0
				ins_32[14:12] = 3'b010; //funct3
				ins_32[19:15]  = 2'h2; //rs1 = sp
				ins_32[24:20] =  ins_16[6:2]; //rs2
				ins_32[31:25] =  {4'h0,ins_16[8:7],ins_16[12]};	//imm 11:5
				end
	5'b111_10: begin //C.fswsp 
				ins_32[6:0] = 7'b0100111; //opcode
				ins_32[11:7] = {ins_16[11:9],2'b0}; //imm 4:0
				ins_32[14:12] = 3'b010; //funct3
				ins_32[19:15]  = 2'h2; //rs1 = sp
				ins_32[24:20] =  ins_16[6:2]; //rs2
				ins_32[31:25] =  {4'h0,ins_16[8:7],ins_16[12]};	//imm 11:5
				end
	endcase
end
endmodule 

