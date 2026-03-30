// ── mem_bus ──────────────────────────────────────────────────
// Unified memory bus interface (OBI-style valid/ready protocol)
//
// Protocol:
//   - Transaction accepted when req && ready on rising clock edge
//   - Reads:  rvalid + rdata appear 1 cycle after acceptance (SRAM timing)
//   - Writes: complete on acceptance, no response needed
//   - ready held low to back-pressure master
//
interface mem_bus;
    logic        req;       // master → slave: transaction request
    logic        ready;     // slave → master: can accept this cycle
    logic        we;        // master → slave: write enable (0=read, 1=write)
    logic [31:0] addr;      // master → slave: byte address
    logic [3:0]  be;        // master → slave: byte enable
    logic [31:0] wdata;     // master → slave: write data
    logic [31:0] rdata;     // slave → master: read data
    logic        rvalid;    // slave → master: read data valid

    modport master (output req, we, addr, be, wdata,
                    input  ready, rdata, rvalid);
    modport slave  (input  req, we, addr, be, wdata,
                    output ready, rdata, rvalid);
endinterface

// ── DebugBus ────────────────────────────────────────────────
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
