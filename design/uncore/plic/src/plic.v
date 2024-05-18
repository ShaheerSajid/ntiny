module plic
#(parameter Number_of_Sources = 5,
  parameter Interrupt_Width   = 3,
  parameter Number_of_Targets = 1)
(
// signals for connecting to the Avalon fabric
input  						clk_i,
input 						resetn_i,
input  						write_i,
input  						read_i,
input  						chipselect_i,
input  			[31:0]   writedata_i,
input  			[1:0]		address_i,

//From Sources
input [((Number_of_Sources)-1):0]         Interrupt,            // interrupt from source
input ED,  
//From Target(Hart  Context)
input       [(Number_of_Targets-1):0]     Interrupt_Claim,
input       [(Number_of_Targets-1):0]     Interrupt_Complete,

//To Target(Hart Context)
output  wire [(Number_of_Targets-1):0]    Interrupt_Notification,
output  reg  [31:0]		                  readdata_o

);



///// memory mapped registers

`define   IE_INTERRUPT  2'h0
`define   THRESHOLD     2'h1
`define   PRIORITY      2'h2
`define   INTERRUPT_ID  2'h3

reg       [((Number_of_Targets * Number_of_Sources)-1):0]     IE_interrupt;
reg       [((Number_of_Targets * Interrupt_Width)-1):0]       Threshold;
reg       [((Interrupt_Width*Number_of_Sources)-1):0]         Priority;
reg       [((Interrupt_Width*Number_of_Targets)-1):0]         Interrupt_ID_r;

wire      [((Interrupt_Width*Number_of_Targets)-1):0]         Interrupt_ID;
reg                                                           ID;

 always@(posedge clk_i or posedge resetn_i)
 begin    
    if (resetn_i)
        begin
         IE_interrupt     <=	0;		
		   Threshold	     <=	0;		
		   Priority	        <=	0;
        end

      else if (write_i & chipselect_i)
		begin 
		case (address_i)
		`IE_INTERRUPT:	 IE_interrupt     <=	writedata_i;		
		`THRESHOLD:	    Threshold        <=	writedata_i;		
		`PRIORITY:	    Priority	      <=	writedata_i;
        
        default :     begin
                         IE_interrupt    <=	0; 
                         Threshold	     <=	0;
                         Priority	     <=	0;
                      end
		endcase
		end

	else if (read_i & chipselect_i)
		begin
		case (address_i)
		`IE_INTERRUPT:	 readdata_o		<=	IE_interrupt;		
		`THRESHOLD:  	 readdata_o		<=	Threshold;		
		`PRIORITY:	    readdata_o		<=	Priority;
      `INTERRUPT_ID:	 readdata_o		<=	Interrupt_ID_r;
      default : 		 readdata_o    <=  32'd0;	
		endcase
        end
end

always@(posedge clk_i or posedge resetn_i)
begin

if(resetn_i)
begin
   Interrupt_ID_r <= 0;
	ID             <= 1'b0;
end

else if(Interrupt_Notification & Interrupt_Claim)
begin
   ID           <= 1'b1;
end

else if(ID)
begin
   Interrupt_ID_r <= Interrupt_ID;
	ID             <= 1'b0;
end

end

PLIC_TOP #(
  .Number_of_Sources(Number_of_Sources)
  )
  plicc(

.clk                       (clk_i),
.reset                     (resetn_i),

//From External Sources(Global Interrupts)
.Priority                  (Priority[((Interrupt_Width*Number_of_Sources)-1):0]),

//For Target1
.IE_interrupt1             (IE_interrupt[((Number_of_Targets * Number_of_Sources)-1):0]),
.Threshold1                (Threshold[((Number_of_Targets * Interrupt_Width)-1):0]),
.ED                        (ED),

//For Gateway
.Interrupt                 (Interrupt),
.Interrupt_Complete        (Interrupt_Complete),

//From Target(Hart  Context)
.Interrupt_Claim           (Interrupt_Claim),

//To Target(Hart Context)
.Interrupt_Notification    (Interrupt_Notification),
.Interrupt_ID              (Interrupt_ID)


);

endmodule