module comparator
#(parameter Interrupt_Width   = 3)
(
input      [(Interrupt_Width-1):0] P1,
input      [(Interrupt_Width-1):0] P2,
input      [(Interrupt_Width-1):0] ID1,
input      [(Interrupt_Width-1):0] ID2,
output reg [(Interrupt_Width-1):0] P,
output reg [(Interrupt_Width-1):0] ID

);

always @(*)
    begin
        if (P1 > P2) 
		  begin
            P   = P1;
				ID  = ID1;
        end
		  
        else if (P1 < P2) 
		  begin
            P   = P2;
				ID  = ID2;
        end
		  
		  else
		  begin
		  
		   if (ID1 < ID2) 
		   begin
            P   = P1;
				ID  = ID1;
         end
		  
         else
		   begin
            P   = P1;
				ID  = ID2;
         end
		  	  
		  end
    end


endmodule