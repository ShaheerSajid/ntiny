`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01/01/2023 08:40:58 PM
// Design Name: 
// Module Name: PLIC_TOP
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


module PLIC_TOP
#(parameter Number_of_Sources = 5,
  parameter Interrupt_Width   = 3,
  parameter Number_of_Targets = 1)(
  
input clk,
input reset,

input [((Number_of_Sources)-1):0]Interrupt,            // interrupt from source
input ED,                   //input for selecting level triggered or edge triggeerd interrupt
////////////////////////////////////////////////////////////////////////////////////////////////////
input [((Interrupt_Width*Number_of_Sources)-1):0]Priority,            
//input [((Interrupt_Width*Number_of_Sources)-1):0]ID_interrupt,
//For Target1
input       [(Number_of_Targets * Number_of_Sources-1):0]     IE_interrupt1,
input       [(Number_of_Targets * Interrupt_Width-1):0]       Threshold1,


//From Target(Hart  Context)
input       [(Number_of_Targets-1):0]     Interrupt_Claim,
input       [(Number_of_Targets-1):0]     Interrupt_Complete,

//To Target(Hart Context)
output  wire [(Number_of_Targets-1):0]     Interrupt_Notification,
output  wire [((Interrupt_Width*Number_of_Targets)-1):0]       Interrupt_ID

    );


wire  [(Number_of_Sources-1):0]Interrupt_Request;             //   interrupt request to core

    wire [(Number_of_Targets-1):0] int_complete_1[0:(Number_of_Sources-1)] ;
  wire  [(Number_of_Targets-1):0] claim [0:(Number_of_Sources-1)] ;
 ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
 ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////


wire [((Interrupt_Width*Number_of_Targets)-1):0]       Max_ID;
reg   [((Interrupt_Width*Number_of_Sources)-1):0] ID_interrupt;
wire   [(Number_of_Sources-1):0]      IP_interrupt;
wire   claim_target;
wire [((Interrupt_Width*Number_of_Targets)-1):0] Max_ID1;
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////





//Gateways instantiate for parametrized no of sources
genvar i;
generate
for(i=0 ; i<Number_of_Sources; i=i+1)begin:gatewayy

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
gateway #( .Number_of_Sources(Number_of_Sources),
  .Interrupt_Width(Interrupt_Width))
 /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////  
  Interupt_Source(
  
. clk(clk),
.reset(reset),
// from target for proceeding to next interrupt
//.interrupt_complete((Interrupt_Complete[0] & (Max_ID[7:0] == (i + 1)) )| (Interrupt_Complete[1] &(Max_ID[15:8] == (i + 1)))),
.interrupt_complete(|int_complete_1[i]),

// Interrupt from interrupt sources
.interrupt(Interrupt[i]), 

// Interrupt request generated by gateway to core
.interrupt_request(Interrupt_Request[i]),

// Edge triggeerd or leevl triggerd mode selection
.ED(ED)
);
end
endgenerate
///////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

//Interrupt Core for paramertized no of Targets
genvar t;
generate
for(t=0 ; t<Number_of_Targets; t=t+1)begin:clicc

// Clic Core
  clic #( .Number_of_Sources(Number_of_Sources),
  .Interrupt_Width(Interrupt_Width))
  ///////////////////////////////////////////////////////////////////////////////////////////////////////////
   Core_Targets
  (

  .clk                      (clk),
  .rst_n                    (reset),
  //From External Sources(Global Interrupts)
 // .ID_interrupt             (ID_interrupt),
  .Priority                 (Priority),
  .IE_interrupt             (IE_interrupt1[((t*Number_of_Sources)+(Number_of_Sources-1)):(t*Number_of_Sources)]),
  .Threshold                (Threshold1[((t*Interrupt_Width)+(Interrupt_Width-1)):(t*Interrupt_Width)]),

  //From PLIC
  .IP_interrupt             (IP_interrupt),

  //From Target(Hart  Context)
  .Interrupt_Claim          (Interrupt_Claim[t]),

  //To Target(Hart Context)
  .Interrupt_Notification   (Interrupt_Notification[t]),
  .Interrupt_ID             (Interrupt_ID[((t*Interrupt_Width)+(Interrupt_Width-1)):(t*Interrupt_Width)]),
  
//  .set_IP                   (set_IP1),
//  .clear_IP                 (clear_IP1),
  .Max_ID                   (Max_ID[((t*Interrupt_Width)+(Interrupt_Width-1)):(t*Interrupt_Width)]),
  .Max_ID1                   (Max_ID1[((t*Interrupt_Width)+(Interrupt_Width-1)):(t*Interrupt_Width)])

  );
  end
endgenerate
/////////////////////////////////////////////////////////////////////////////////////////////////////
/////////////////////////////////////////////////////////////////////////////////////////////////////


  genvar k;
  generate
  for (k = 0; k < Number_of_Sources; k = k + 1)
   begin : Set_Clear_IP
   
 // IP handling for parameterized no of sources and no of targets  
       IP_Handling  IP_Handlle
		 (
 
       .clk             (clk),
       .rst_n           (reset),
       .IR              (Interrupt_Request[k]),
//       .claim           ((Interrupt_Claim[0] & (Max_ID[7:0] == (k + 1)) )| (Interrupt_Claim[1] &(Max_ID[15:8] == (k + 1)))),
       .claim           (|claim[k]),
       .IP              (IP_interrupt[k])
        );
		  
	end	
  endgenerate  
 ////////////////////////////////////////////////////////////////////////////////////////////////////  
   
  genvar s;
  genvar c;
  
  generate
  
  for (s = 0; s < Number_of_Sources; s = s + 1)
   begin : set_claim1
   
  for (c = 0; c < Number_of_Targets; c = c + 1)
   begin : set_claim2
	   assign claim[s][c] = Interrupt_Claim[c] & (Max_ID[((c*Interrupt_Width)+(Interrupt_Width-1)):(c*Interrupt_Width)] == (s + 1));	
	   assign int_complete_1[s][c] = Interrupt_Complete[c] & (Max_ID1[((c*Interrupt_Width)+(Interrupt_Width-1)):(c*Interrupt_Width)] == (s + 1));	 
	end

   end	
	
  endgenerate




endmodule



 
