`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: Muhammad Faizan 
// 
// Create Date: 12/02/2022 06:28:55 PM
// Design Name: PLIC
// Module Name: PILC gateway
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module gateway #(parameter Number_of_Sources = 5,
  parameter Interrupt_Width   = 3)(
input clk,
input reset,
input interrupt_complete,
input interrupt,
input ED,
output reg interrupt_request
    );
     /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
       ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////// 
       
    // state registers   
    reg [2:0]N_STATE;
    reg [2:0]P_STATE;
    reg [2:0]state;
     reg [2:0]state_1;
    ///flags 
//    reg int_req;
    reg interrupt_flg;
    reg interrupt_flg1;
    reg interrupt_flg2;
    reg int_cmpl_flg1;
    reg int_cmpl_flg2;
    reg int_cmpl_flg3;
    reg [7:0]pending;
    wire IP;
//    wire [7:0]pending_int; 
    parameter [2:0]IDLE=3'd0;
    parameter [2:0]INT_DETECTED=3'd1;
    parameter [2:0] INT_LEVEL=3'd2;
    parameter [2:0] INT_EDGE=3'd3;
    parameter [2:0] INT_PENDING=3'd4;
    parameter [2:0]INT_CLAIMED=3'd5;
    parameter [2:0]S0=3'd0;
    parameter [2:0]S1=3'd1;
    parameter [2:0]S2=3'd2;
    parameter [2:0]S3=3'd3;
        parameter [2:0]C0=3'd0;
    parameter [2:0]C1=3'd1;
    parameter [2:0]C2=3'd2;
    parameter [2:0]C3=3'd3;
    always @(posedge clk, posedge reset) begin
            if(reset)begin
                    P_STATE<=3'd0;
            end
            else begin
                    P_STATE<=N_STATE;
            end
    end
      /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////////////////////////////////////////////////////
    // interuupt edge detecction
    always @(posedge clk, posedge reset) begin
            if(reset)begin
                    interrupt_flg<=0;
                    interrupt_flg1<=0;
                    interrupt_flg2<=0;
                    int_cmpl_flg1<=0;
                    int_cmpl_flg2<=0;
                    int_cmpl_flg3<=0;
            end
            
            else begin
    		interrupt_flg1 	<= interrupt;
			interrupt_flg2 	<= interrupt_flg1;
			interrupt_flg <= interrupt_flg1 && ~interrupt_flg2;
            
            int_cmpl_flg1 	<= interrupt_complete;
			int_cmpl_flg2 	<= int_cmpl_flg1;
			int_cmpl_flg3 <= int_cmpl_flg1 && ~int_cmpl_flg2;
    end
    end
    /////////////////////////////////////////////////////////////////////////////
      /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
      
      
    always @(*) begin
            
            case(P_STATE)
                        IDLE:begin
                               N_STATE=INT_DETECTED; 
                        end
                        
                        INT_DETECTED: begin
                                if(interrupt && ED==0)begin                       // ED==0 for level triggered interrupt
                                    N_STATE=INT_LEVEL;
                                end
                                else if(interrupt_flg && ED==1)begin             // ED==1 for edge triggered interrupt
                                    N_STATE=INT_EDGE;
                                end
                                else begin
                                    N_STATE=INT_DETECTED;
                                end        
                        end
                        
                        INT_LEVEL: begin
                                if(int_cmpl_flg3==1)begin
                                        N_STATE=IDLE;
                                end
                                else begin
                                        N_STATE=INT_LEVEL;
                                end
                        end    
                    
                    
                       INT_EDGE: begin
                                if(int_cmpl_flg3==1 && pending==0)begin
                                        N_STATE=IDLE;
                                end
                                else if ((int_cmpl_flg3==1) && ~(pending==0))begin
                                        N_STATE=INT_PENDING;
                                end   
                                else if (interrupt_flg) begin
                                        N_STATE=INT_PENDING;
                                end
 
                                else begin
                                        N_STATE=INT_EDGE;
                                end
                        end
                        
                       INT_PENDING: begin
                               
                                if(int_cmpl_flg3)begin
//                                    pending<=pending-1;
                                    N_STATE=INT_CLAIMED;
                                end
                                else if (interrupt_flg ) begin
                                        N_STATE=INT_EDGE;
//                                        pending<=pending+1;
                                end      
                                
                                else begin
                                        N_STATE=INT_PENDING;
                                end
                        end

                        INT_CLAIMED: begin
                                if(pending==0)begin
                                         N_STATE=IDLE;
                                end
                                else begin
                                        N_STATE=INT_PENDING;
                                end
                        end 
				            default:    	N_STATE=IDLE;			
            endcase
    end
  /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    //fsm for handling pendin interrupts for edge triggered interrupts
always @ (posedge clk or posedge reset)begin
  if(reset)begin
                    state<=S0;
                    pending<=8'd0;
            end
            else begin 
case(state)
S0 : begin
if( P_STATE==IDLE) begin
pending<=8'd0;
state<=S0;
end
else if(( P_STATE==INT_EDGE ||P_STATE==INT_PENDING) && interrupt_flg)begin
pending<=pending+8'd1;
state<=S1;
end
else if( (P_STATE==INT_PENDING ||P_STATE==INT_EDGE ) && int_cmpl_flg3 && pending!=0)begin
pending<=pending-8'd1;
state<=S1;
end
end

S1 : begin
state<=S2;
pending<=pending;
end

S2 :begin
state<=S0;
pending<=pending;
end
S3 : begin
state<=S0;
pending<=pending;
end

endcase
end
end
////////////////////////////////////////////////////////////////////////////////////////////////////////
//fsm for ahndling interrupt request for core
always @ (posedge clk or posedge reset)begin
  if(reset)begin
                    state_1<=C0;
                    interrupt_request<=0;
            end
    else begin
case(state_1)
C0 : begin
            if( P_STATE==INT_DETECTED  && interrupt && ED==0) begin
                    interrupt_request<=1;
                    state_1<=C1;
            end
            
            else if( P_STATE==INT_DETECTED  &&  ED==1 && interrupt_flg) begin
                    interrupt_request<=1;
                    state_1<=C1;
            end
            else if( pending>0 &&  int_cmpl_flg3 && ED==1)begin
                    interrupt_request<=1;
                    state_1<=C1;
            end
            else begin
            state_1<=C0;
            end
end

C1 : begin
state_1<=C2;
interrupt_request<=1;
end

C2 :begin
state_1<=C3;
interrupt_request<=1;
end
C3 : begin
state_1<=C0;
interrupt_request<=0;
end

endcase
end


end


endmodule