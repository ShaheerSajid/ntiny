module IP_Handling
(
 input         clk,
 input         rst_n,
 input         IR,
 input         claim,
 
 output        IP
);


reg  [1:0]                          current_state_IP;
reg  [1:0]                          next_state_IP;

/******************************************************************************
 * Parameters and defines                                                     *
 *****************************************************************************/ 

  parameter    IDLE       = 2'b00;
  parameter    SET_IP     = 2'b01; 
  parameter    CLAIM      = 2'b10;  
  
/******************************************************************************
 * State Machine                                                              *
 *****************************************************************************/ 
  always @(posedge clk or posedge rst_n)
  begin
    if (rst_n)
     current_state_IP     <= IDLE;
    else
     current_state_IP     <= next_state_IP;
  end



  // Next_state block
  always @ (*)
  begin
									  
    case (current_state_IP)
                    IDLE    : begin
						  
										  if(IR)
										  begin
										    next_state_IP    = SET_IP;
										  end
										  
										  else
										  begin
										    next_state_IP    = IDLE;
										  end
										  
										end
										  
						  SET_IP  : begin
						  
                               if(claim)  //From Target
                               begin
                                 next_state_IP    = CLAIM;
                               end
											
										 else
										 begin
										   next_state_IP    = SET_IP;
										 end
				
                              end

 
                     CLAIM  : begin
                                 next_state_IP    = IDLE;											
                              end
										
									  
								
           default          :  next_state_IP    = IDLE;
			  
    endcase
	 
  end
	
  assign   IP = (current_state_IP == SET_IP) ? 1'b1 : 1'b0; 




endmodule