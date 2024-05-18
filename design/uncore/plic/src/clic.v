module clic
#(parameter Number_of_Sources = 5,
  parameter Interrupt_Width   = 3)
(

input         clk,
input         rst_n,
//From External Sources(Global Interrupts)
//input       [((Interrupt_Width*Number_of_Sources)-1):0] ID_interrupt,
input       [((Interrupt_Width*Number_of_Sources)-1):0] Priority,
input       [(Number_of_Sources-1):0]     IE_interrupt,
input       [(Interrupt_Width-1):0]       Threshold,

//From Gateway
input       [(Number_of_Sources-1):0]     Interrupt_Request,
 
//From Target(Hart  Context)
input                                     Interrupt_Claim,

//To Target(Hart Context)
output  reg                               Interrupt_Notification,
output  reg [(Interrupt_Width-1):0]       Interrupt_ID,

output  reg                                 set_IP,
output  reg                                 clear_IP,
input        [(Number_of_Sources-1):0]      IP_interrupt,
output  wire [7:0]                          Max_ID,
output   reg [7:0]                          Max_ID1



);


reg  [1:0]                          current_state;
reg  [1:0]                          next_state;


wire [(Number_of_Sources-1):0]      zero_interrupt;
wire [(Number_of_Sources-1):0]      Interrupt_En;
wire [((Interrupt_Width*Number_of_Sources)-1):0]  Priority_En;
wire [((Interrupt_Width*Number_of_Sources)-1):0]  Priority_Max;
wire [((Interrupt_Width*Number_of_Sources)-1):0]  ID_Max;
wire                                EIP_interrupt;
wire [(Interrupt_Width-1):0]        Max_Priority;
wire [((Interrupt_Width*Number_of_Sources)-1):0] ID_interrupt;
//wire [(Interrupt_Width-1):0]        Max_ID;



/******************************************************************************
 * Parameters and defines                                                     *
 *****************************************************************************/ 

  parameter    INTERRUPT_NOTIFICATION       = 2'b01; 
  parameter    CLAIM_RESPONSE               = 2'b10;   
  
  
/******************************************************************************
 * Datapath                                                     *
 *****************************************************************************/  
  
  //Enabled Interrupts
  genvar k;
  generate
  for (k = 0; k < Number_of_Sources; k = k + 1)
  begin : Enabled_Interrupts
  
   assign  ID_interrupt [((k*Interrupt_Width)+(Interrupt_Width-1)):(k*Interrupt_Width)] = k + 1;
	assign  zero_interrupt[k]                                                            = (Priority[((k*Interrupt_Width)+(Interrupt_Width-1)):(k*Interrupt_Width)] == 0) | (ID_interrupt[((k*Interrupt_Width)+(Interrupt_Width-1)):(k*Interrupt_Width)] == 0);
   assign  Interrupt_En[k]                                                              = ~zero_interrupt[k] & IE_interrupt[k] & IP_interrupt[k];
   assign  Priority_En  [((k*Interrupt_Width)+(Interrupt_Width-1)):(k*Interrupt_Width)] = Priority[((k*Interrupt_Width)+(Interrupt_Width-1)):(k*Interrupt_Width)] * Interrupt_En[k];
	
  end
 

  endgenerate 
 
  
  //Comparing Priorities
    genvar i;
    generate
    comparator c2(
		          .P1   (Priority_En   [(Interrupt_Width-1):0]),
		          .P2   (0),
					 .ID1  (ID_interrupt  [(Interrupt_Width-1):0]),
					 .ID2  (0),
					 .P    (Priority_Max  [(Interrupt_Width-1):0]),
					 .ID   (ID_Max)
					);		
					
    for (i = 1; i < Number_of_Sources; i = i + 1) 
	 begin :compare_priorities
    comparator c2(
		          .P1   (Priority_En   [((i*Interrupt_Width)+(Interrupt_Width-1)):(i*Interrupt_Width)]),
		          .P2   (Priority_Max  [(((i-1)*Interrupt_Width)+(Interrupt_Width-1)):((i-1)*Interrupt_Width)]),
				  .ID1  (ID_interrupt  [((i*Interrupt_Width)+(Interrupt_Width-1)):(i*Interrupt_Width)]),
				  .ID2  (ID_Max        [(((i-1)*Interrupt_Width)+(Interrupt_Width-1)):((i-1)*Interrupt_Width)]),
				  .P    (Priority_Max  [((i*Interrupt_Width)+(Interrupt_Width-1)):(i*Interrupt_Width)]),
				  .ID   (ID_Max        [((i*Interrupt_Width)+(Interrupt_Width-1)):(i*Interrupt_Width)] )
					);
    end
    endgenerate
  
  
  
  //Maximum Priority
  assign   Max_Priority      = Priority_Max[((Interrupt_Width*Number_of_Sources)-1):((Number_of_Sources*Interrupt_Width)-Interrupt_Width)];
  
  //Maximum ID
  assign   Max_ID            = ID_Max[((Interrupt_Width*Number_of_Sources)-1):((Number_of_Sources*Interrupt_Width)-Interrupt_Width)];
  
  //Sending Interrupt Notification
  assign   EIP_interrupt     = (Max_Priority > Threshold) ? 1'b1 : 1'b0; 
  
  


/******************************************************************************
 * State Machine                                                              *
 *****************************************************************************/ 
  always @(posedge clk or posedge rst_n)
  begin
    if (rst_n)
     current_state     <= INTERRUPT_NOTIFICATION;
    else
     current_state     <= next_state;
  end



  // Next_state block
  always @ (*)
  begin

    case (1'b1)
    INTERRUPT_NOTIFICATION  : begin
                               if(Interrupt_Claim)  //From Target
                               begin
                                 next_state    = CLAIM_RESPONSE;
                               end
										 
								       else
								         next_state    = INTERRUPT_NOTIFICATION;
				
                              end

 
            CLAIM_RESPONSE  : begin
                               next_state    = INTERRUPT_NOTIFICATION;
                              end
									  
								
           default          :  next_state    = INTERRUPT_NOTIFICATION;
    endcase
  end
  
  //Output
  always @(posedge clk or posedge rst_n)
  begin
    if (rst_n)
     Max_ID1     <= 0;
    else if(Interrupt_Claim)
     Max_ID1     <= Max_ID;
  end
  
  always@(current_state or EIP_interrupt)
  begin
  
  case(current_state)
    2'b01:  begin
	         Interrupt_Notification  = EIP_interrupt;
				Interrupt_ID            = 0;
				set_IP                  = 1'b1;
				clear_IP                = 1'b0;
				end             
				
    2'b10:  begin
	         Interrupt_ID            = Max_ID1; //Max ID
	         Interrupt_Notification  = 1'b0;
				set_IP                  = 1'b0;
				clear_IP                = 1'b1;
				end
	 
	 default:
	        begin 
	         Interrupt_Notification  = 1'b0;
            Interrupt_ID            = 0;
				set_IP                  = 1'b0;
				clear_IP                = 1'b0;
	        end
	endcase
	
  end
  

endmodule



 