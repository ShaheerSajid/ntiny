interface IBus;
    logic [31:0] instruction;
    logic [31:0] address;
    bit enable;
    bit stall;

    modport m (input  instruction, stall, output address, enable);
endinterface



interface DBus;
    logic [31:0] address;
    logic [3:0] byteenable; 
    bit read;
    logic[31:0] readdata;  
    bit write;
    logic [31:0] writedata;
    bit stall;

    modport m (input  readdata, stall, output address, byteenable , read, write, writedata);
endinterface

interface DebugBus;
    bit core_resume_req;
    bit	core_halt_req;
    bit core_halt;
    bit core_resume;
    bit	core_running;
    bit	ar_en;
    bit	ar_wr;
    logic[15:0]  ar_ad;
    logic[31:0]  ar_di;
    logic[31:0]  ar_do;

    modport m (input  ar_di, core_halt, core_resume, core_running, output ar_en, ar_wr, ar_ad, ar_do, core_resume_req, core_halt_req);
endinterface
