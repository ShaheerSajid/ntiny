//abstract access
import common_pkg::*;
import debug_pkg::*;

module dm(
  input         rst_i,
  input         clk_i,

  // DMI
  input onebit_sig_e dmi_wr_i,
  input onebit_sig_e dmi_rd_i,
  input dm_addresses_e dmi_ad_i,
  input [31:0]  dmi_di_i,
  output logic[31:0] dmi_do_o,

  // Debug Module Status
  input onebit_sig_e resumeack_i,
  input onebit_sig_e running_i,
  input onebit_sig_e halted_i,

  output onebit_sig_e haltreq_o,
  output onebit_sig_e resumereq_o,
  output onebit_sig_e ndmreset_o,

  output onebit_sig_e ar_en_o,
  output onebit_sig_e ar_wr_o,
  output logic[15:0] ar_ad_o,
  input  onebit_sig_e ar_done_i,
  input [31:0]  ar_di_i,
  output logic[31:0] ar_do_o,

  output onebit_sig_e am_en_o,
  output onebit_sig_e am_wr_o,
  output logic[3:0] am_st_o,
  output logic[31:0] am_ad_o,
  input [31:0]  am_di_i,
  output logic[31:0] am_do_o,
  input  onebit_sig_e am_done_i
);

//registers
logic [31:0] dmstatus;
logic [31:0] dmcontrol;
logic [31:0] abstractcs;
logic [31:0] command;
logic [31:0] abstractauto;
logic [31:0] data0;
logic [31:0] data1;

logic ackhavereset;
logic dmactive;
logic busy;
logic [7:0] cmdtype;
logic [15:0] regno;
logic write;
logic transfer;
logic aapostincrement;
logic [2:0]aasize;
enum logic [1:0] {IDLE, DECODE, POST} pstate, nstate;
logic autoexeccmd;

// ── System Bus Access (Spec 1.0 §3.11) ────────────────────────────
// SBA gives the debugger memory access "without involving a hart".
// On this implementation the bus master is shared with the
// abstract memaccess (cmdtype=2) path: SBA drives the same
// am_*_o outputs the abstract command FSM uses, and only one of
// them is active at a time. Practical consequence: SBA operations
// only complete while the hart is halted (the am_* path requires
// dbg_mem_override in core_top). The OpenOCD-visible register
// interface is fully spec-compliant; SBA-while-running needs a
// dedicated bus master + arbiter in soc_top, deferred for now.
logic [31:0] sbaddress0;
logic [31:0] sbdata0;
logic [2:0]  sbcs_sbaccess;       // 0=8b, 1=16b, 2=32b
logic        sbcs_sbautoincrement;
logic        sbcs_sbreadonaddr;
logic        sbcs_sbreadondata;
logic [2:0]  sbcs_sberror;        // R/W1C
logic        sbcs_sbbusyerror;    // R/W1C
logic        sbbusy;
logic        sba_wr;              // direction of in-flight access
logic        sba_complete;        // SBA op finished this cycle
logic        sba_trigger_read;
logic        sba_trigger_write;
enum logic [0:0] {SBA_IDLE, SBA_REQ} sba_state, sba_nstate;


always_ff@(posedge clk_i)
begin : dmstatus_reg
  //ndmreset logic and clear
  if(ndmreset_o)
  begin
    dmstatus[19] <= 1'b1;
    dmstatus[18] <= 1'b1;
  end
  else if(ackhavereset)
  begin
    dmstatus[19] <= 1'b0;
    dmstatus[18] <= 1'b0;
  end
  dmstatus[17] <= resumeack_i;
  dmstatus[16] <= resumeack_i;
  dmstatus[11] <= running_i;
  dmstatus[10] <= running_i;
  dmstatus[9] <= halted_i;
  dmstatus[8] <= halted_i;
end : dmstatus_reg


//dmcontrol logic
assign haltreq_o = onebit_sig_e'(dmcontrol[31]);
assign resumereq_o = onebit_sig_e'(dmcontrol[30]);
assign ackhavereset = dmcontrol[28];
assign ndmreset_o = onebit_sig_e'(dmcontrol[1]);
assign dmactive = dmcontrol[0];

always_ff@(posedge clk_i or posedge rst_i)
begin : dmcontrol_reg
  if(rst_i)
  begin
    dmcontrol[31] <= 1'b0;
    dmcontrol[30] <= 1'b0;
    dmcontrol[28] <= 1'b0;
    dmcontrol[1] <= 1'b0;
    dmcontrol[0] <= 1'b0;
  end
  else if(dmi_wr_i && dmi_ad_i == DMCONTROL)
    begin
      dmcontrol[31] <= dmi_di_i[31];
      dmcontrol[30] <= dmi_di_i[30];
      dmcontrol[28] <= dmi_di_i[28];
      dmcontrol[1] <= dmi_di_i[1];
      dmcontrol[0] <= dmi_di_i[0];
    end
end : dmcontrol_reg

//abstractcs
logic aaccess;
assign aaccess = (dmi_wr_i && (dmi_ad_i == ABSTRACTCS || dmi_ad_i == COMMAND || dmi_ad_i == DATA0 || dmi_ad_i == DATA1 || dmi_ad_i == ABSTRACTAUTO)) ||
                 (dmi_rd_i && (dmi_ad_i == DATA0 || dmi_ad_i == DATA1));
always_ff@(posedge clk_i or posedge rst_i)
begin : abstractcs_reg
  if(rst_i)
    abstractcs[10:8] <= 3'd0;
  else if(!abstractcs[12] && dmi_wr_i && dmi_ad_i == ABSTRACTCS)
    abstractcs[10:8] <= (~dmi_di_i[10:8]) & abstractcs[10:8];
  else if(abstractcs[12] && abstractcs[10:8] == 3'd0 && aaccess)
    abstractcs[10:8] <= 3'd1;
  else if(ar_en_o && aasize != 3'd2)
    abstractcs[10:8] <= 3'd2;
  /*else
    abstractcs[10:8] <= 3'd0;*/
end : abstractcs_reg
always_ff@(posedge clk_i or posedge rst_i)
begin
  if(rst_i)
    abstractcs[12]  <= 1'b0;
  else
    abstractcs[12] <= busy;
end

//command
assign cmdtype = command[31:24];
assign regno = command[15:0];
assign write = command[16];
assign transfer = command[17];
assign aapostincrement = command[19];
assign aasize = command[22:20];

always_ff@(posedge clk_i or posedge rst_i)
begin : command_reg
  if(rst_i)
    command <= 0;
  // Spec 1.0 §3.15.7: writes to command are ignored if cmderr is non-zero.
  // The busy gate is also still required so a write during command
  // execution doesn't clobber the in-flight command.
  else if(!abstractcs[12] && abstractcs[10:8] == 3'd0 &&
          dmi_wr_i && dmi_ad_i == COMMAND)
    command <= dmi_di_i;
  else if(pstate == POST && aapostincrement && cmdtype == 8'd0)
    if(aasize == 3'd2)
      command[15:0] <= command[15:0] + 16'd1;
end : command_reg

//fsm
always_ff@(posedge clk_i or posedge rst_i)
begin
  if(rst_i)
    pstate <= IDLE;
  else
    pstate <= nstate;
end
always_comb
begin
  case(pstate)
    IDLE: begin
            if(dmi_wr_i && dmi_ad_i == COMMAND || autoexeccmd)
              nstate = DECODE;
            else
              nstate = IDLE;
            ar_en_o = FALSE;
            ar_wr_o = FALSE;
            ar_ad_o = 16'd0;
            ar_do_o = 0;
            am_en_o = FALSE;
            am_wr_o = FALSE;
            am_st_o = 4'd0;
            am_ad_o = 0;
            am_do_o = 0;
            busy = 1'b0;
          end
    DECODE: begin
              ar_en_o = onebit_sig_e'((cmdtype == 8'd0) & transfer);
              ar_wr_o = onebit_sig_e'(transfer & write);
              ar_ad_o = regno;
              ar_do_o = data0;  
              am_en_o = onebit_sig_e'((cmdtype == 8'd2) && !am_done_i);//may want this or not doesnt matter
              am_wr_o = onebit_sig_e'(write);
              am_st_o = aasize;
              am_ad_o = data1;
              am_do_o = data0;
              nstate = ((cmdtype == 8'd2) && !am_done_i)? DECODE : POST;
              busy = 1'b1;
            end
    POST: begin
            ar_en_o = FALSE;
            ar_wr_o = FALSE;
            ar_ad_o = 16'd0;
            ar_do_o = 0;
            am_en_o = FALSE;
            am_wr_o = FALSE;
            am_st_o = 4'd0;
            am_ad_o = 0;
            am_do_o = 0;
            busy = 1'b0;
            nstate = (dmi_wr_i && !aapostincrement)? POST : IDLE;
          end
    default:begin
              nstate = IDLE;
              ar_en_o = FALSE;
              ar_wr_o = FALSE;
              ar_ad_o = 16'd0;
              ar_do_o = 0;
              am_en_o = FALSE;
              am_wr_o = FALSE;
              am_st_o = 4'd0;
              am_ad_o = 0;
              am_do_o = 0;
              busy = 1'b0;
            end
  endcase

  // SBA override: when the SBA bus master has an in-flight access,
  // drive the am_* interface from the SBA state. Last-assignment-
  // wins in always_comb cleanly preempts the abstract-command path.
  if (sba_state == SBA_REQ) begin
    am_en_o = onebit_sig_e'(!am_done_i);
    am_wr_o = onebit_sig_e'(sba_wr);
    am_st_o = {1'b0, sbcs_sbaccess};
    am_ad_o = sbaddress0;
    am_do_o = sbdata0;
  end
end

//data0
always_ff@(posedge clk_i or posedge rst_i)
begin : data0_reg
  if(rst_i)
    data0 <= 0;
  else if(!abstractcs[12] && dmi_wr_i && dmi_ad_i == DATA0)
    data0 <= dmi_di_i;
  else if(ar_done_i)
    data0 <= ar_di_i;
  // Only capture am_di_i into data0 when the abstract-command FSM
  // owns the bus master (cmdtype=2). When SBA owns it (sba_state ==
  // SBA_REQ), the read result lands in sbdata0 instead.
  else if(am_done_i && pstate == DECODE)
    data0 <= am_di_i;
end : data0_reg

//data1
always_ff@(posedge clk_i or posedge rst_i)
begin : data1_reg
  if(rst_i)
    data1 <= 0;
  else if(!abstractcs[12] && dmi_wr_i && dmi_ad_i == DATA1)
    data1 <= dmi_di_i;
  else if(pstate == POST && aapostincrement && cmdtype == 8'd2)
    if(aasize == 3'd1)
      data1 <= data1 + 2;
    else if(aasize == 3'd2)
      data1 <= data1 + 4;
end : data1_reg

//abstarctauto
always_ff@(posedge clk_i or posedge rst_i)
begin : abstarctauto_reg
  if(rst_i)
    abstractauto[1:0] <= 0;
  else if(!abstractcs[12] && dmi_wr_i && dmi_ad_i == ABSTRACTAUTO)
    abstractauto[1:0] <= dmi_di_i;
end : abstarctauto_reg

assign autoexeccmd = (dmi_wr_i || dmi_rd_i) &&  ((abstractauto[0] && dmi_ad_i == DATA0) ||
                                                 (abstractauto[1] && dmi_ad_i == DATA1));

// ═══════════════════════════════════════════════════════════════════════════
// System Bus Access (SBA) — Spec 1.0 §3.11, §3.15.22-30
// ═══════════════════════════════════════════════════════════════════════════
// Triggers per spec:
//   - Write to sbdata0 with sberror==0, sbbusyerror==0, sbbusy==0 → SBA write
//   - Write to sbaddress0 with sbreadonaddr=1 (and same idle conds) → SBA read
//   - Read of sbdata0 with sbreadondata=1 (and same idle conds)   → SBA read
//                                                                   (after current read returns)
// access size: 0=8b, 1=16b, 2=32b. Larger values set sberror=4 (size).
// Aligned-only here (sberror=3 on misalign).

// Implementation limitation: am_* is shared with the abstract memaccess
// path which only routes to dmem_bus when dbg_mem_override is high
// (= HALTED). So SBA also requires halted_i. A full SBA-while-running
// implementation needs a dedicated bus master + arbiter in soc_top.
wire sba_can_start = (sbcs_sberror == 3'd0) && !sbcs_sbbusyerror &&
                     !sbbusy && (halted_i == TRUE);

assign sba_trigger_write = sba_can_start && dmi_wr_i && dmi_ad_i == SBDATA0;
assign sba_trigger_read  = sba_can_start &&
                           ((dmi_wr_i && dmi_ad_i == SBADDRESS0 && sbcs_sbreadonaddr) ||
                            (dmi_rd_i && dmi_ad_i == SBDATA0   && sbcs_sbreadondata));

// Access size legality + alignment legality (compute at trigger time).
wire sba_size_ok = (sbcs_sbaccess <= 3'd2);
wire sba_align_ok = (sbcs_sbaccess == 3'd0) ? 1'b1 :
                    (sbcs_sbaccess == 3'd1) ? (sbaddress0[0] == 1'b0) :
                    (sbcs_sbaccess == 3'd2) ? (sbaddress0[1:0] == 2'd0) : 1'b0;

// SBA state machine.
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        sba_state <= SBA_IDLE;
    else
        sba_state <= sba_nstate;
end

always_comb begin
    sba_nstate = sba_state;
    case (sba_state)
        SBA_IDLE: begin
            if ((sba_trigger_read || sba_trigger_write) && sba_size_ok && sba_align_ok)
                sba_nstate = SBA_REQ;
        end
        SBA_REQ: begin
            // Hold am_en high until am_done_i fires (matches the
            // DECODE-state convention for cmdtype=2 abstract memaccess).
            if (am_done_i)
                sba_nstate = SBA_IDLE;
        end
        default: sba_nstate = SBA_IDLE;
    endcase
end

// sba_complete pulses for one cycle when the bus access actually
// finishes — captured while still in SBA_REQ so am_di_i / readdata_i
// reflect the read result before core2avl's mode_iwb gets clobbered
// by the next cycle's idle inputs.
assign sba_complete = (sba_state == SBA_REQ) && am_done_i;

// sbbusy reflects the SBA bus-master busy state (spec §3.15.22). Goes
// high immediately on a triggered access, low after the access fully
// completes.
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        sbbusy <= 1'b0;
    else if (sba_complete)
        sbbusy <= 1'b0;
    else if (sba_state == SBA_IDLE && (sba_trigger_read || sba_trigger_write))
        sbbusy <= sba_size_ok && sba_align_ok;
end

// sba_wr captures direction at start of access so am_wr_o stays
// stable across the multi-cycle access.
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        sba_wr <= 1'b0;
    else if (sba_state == SBA_IDLE && (sba_trigger_read || sba_trigger_write))
        sba_wr <= sba_trigger_write;
end

// sbaddress0: writable from DMI (when not busy); auto-incremented on
// SBA_DONE if sbautoincrement is set.
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        sbaddress0 <= 32'd0;
    else if (!sbbusy && dmi_wr_i && dmi_ad_i == SBADDRESS0)
        sbaddress0 <= dmi_di_i;
    else if (sba_complete && sbcs_sbautoincrement) begin
        case (sbcs_sbaccess)
            3'd0: sbaddress0 <= sbaddress0 + 32'd1;
            3'd1: sbaddress0 <= sbaddress0 + 32'd2;
            3'd2: sbaddress0 <= sbaddress0 + 32'd4;
            default: ;
        endcase
    end
end

// sbdata0: writable from DMI (when not busy, triggers a write); on
// SBA read completion captured from am_di_i. Width-narrowing for
// 8/16-bit accesses zero-extends (spec leaves upper bits unspecified).
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        sbdata0 <= 32'd0;
    else if (!sbbusy && dmi_wr_i && dmi_ad_i == SBDATA0)
        sbdata0 <= dmi_di_i;
    else if (sba_complete && !sba_wr) begin
        case (sbcs_sbaccess)
            3'd0:    sbdata0 <= {24'd0, am_di_i[7:0]};
            3'd1:    sbdata0 <= {16'd0, am_di_i[15:0]};
            default: sbdata0 <= am_di_i;
        endcase
    end
end

// sbcs control bits — sbreadonaddr/sbreadondata/sbautoincrement/sbaccess.
// Errors (sberror, sbbusyerror) are R/W1C: writing 1 to a bit clears
// it. They cannot be cleared while busy (spec is explicit only for
// sbbusyerror in the data write path; we apply the same rule to
// avoid races).
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        sbcs_sbreadonaddr    <= 1'b0;
        sbcs_sbreadondata    <= 1'b0;
        sbcs_sbautoincrement <= 1'b0;
        sbcs_sbaccess        <= 3'd2;  // default 32-bit
        sbcs_sberror         <= 3'd0;
        sbcs_sbbusyerror     <= 1'b0;
    end else begin
        // Trigger-time error capture
        if (sba_state == SBA_IDLE && (sba_trigger_read || sba_trigger_write)) begin
            if (!sba_size_ok)
                sbcs_sberror <= 3'd4;     // size
            else if (!sba_align_ok)
                sbcs_sberror <= 3'd3;     // alignment
        end
        // Busy-error: a write to sbcs / sbaddress / sbdata while busy.
        // Detect any DMI access targeting an SBA register while sbbusy.
        if (sbbusy && (dmi_wr_i || dmi_rd_i) &&
            (dmi_ad_i == SBCS || dmi_ad_i == SBADDRESS0 ||
             dmi_ad_i == SBDATA0))
            sbcs_sbbusyerror <= 1'b1;

        // DMI write to sbcs: control bits are R/W; error bits are
        // W1C. Don't apply control writes while busy (spec: "writes
        // to sbcs while sbbusy is high result in undefined behavior").
        if (!sbbusy && dmi_wr_i && dmi_ad_i == SBCS) begin
            sbcs_sbreadonaddr    <= dmi_di_i[20];
            sbcs_sbreadondata    <= dmi_di_i[15];
            sbcs_sbautoincrement <= dmi_di_i[16];
            sbcs_sbaccess        <= dmi_di_i[19:17];
            sbcs_sberror         <= sbcs_sberror     & ~dmi_di_i[14:12];
            sbcs_sbbusyerror     <= sbcs_sbbusyerror & ~dmi_di_i[22];
        end
    end
end

// ═══════════════════════════════════════════════════════════════════════════

//readlogic
always_ff@(posedge clk_i or posedge rst_i)
begin : dm_readlogic
  if(rst_i)
    dmi_do_o <= 0;
  else if(dmi_rd_i)
    case(dmi_ad_i)
      DATA0:        dmi_do_o <= data0;
      DATA1:        dmi_do_o <= data1;
      // dmcontrol per RISC-V Debug Spec 1.0 §3.15.2.
      //   [31] haltreq        — WARZ, read 0
      //   [30] resumereq      — W1, read 0
      //   [29] hartreset      — WARL, not implemented (read 0)
      //   [28] ackhavereset   — W1, read 0
      //   [27] ackunavail     — W1, read 0
      //   [26] hasel          — WARL, single hart (read 0)
      //   [25:6] hartsel{lo,hi} — WARL, single hart (read 0)
      //   [5:2] keepalive/resethaltreq controls — W1, read 0
      //   [1] ndmreset        — R/W
      //   [0] dmactive        — R/W
      DMCONTROL:    dmi_do_o <= {30'd0, dmcontrol[1:0]};
      // dmstatus per RISC-V Debug Spec 1.0 §3.15.1.
      //   [31:25] reserved 0
      //   [24] ndmresetpending = 0 (synchronous ndmreset, never pending)
      //   [23] stickyunavail   = 0
      //   [22] impebreak       = 0 (progbufsize=0)
      //   [21:20] reserved 0
      //   [19:18] all/anyhavereset
      //   [17:16] all/anyresumeack
      //   [15:14] all/anynonexistent = 0 (hart 0 exists)
      //   [13:12] all/anyunavail     = 0
      //   [11:8]  all/anyrunning, all/anyhalted
      //   [7] authenticated = 1 (no auth)
      //   [6] authbusy      = 0
      //   [5] hasresethaltreq = 0
      //   [4] confstrptrvalid = 0
      //   [3:0] version = 3 (= 1.0)
      DMSTATUS:     dmi_do_o <= {7'd0, 1'b0, 1'b0, 1'b0, 2'd0,
                                 dmstatus[19:16],
                                 4'd0,
                                 dmstatus[11:8],
                                 1'b1, 1'b0, 1'b0, 1'b0,
                                 4'd3};
      // hartinfo (0x12) — optional, read all-zero is spec-legal for
      // implementations that don't expose data CSR shadows or dscratch.
      HARTINFO:     dmi_do_o <= 32'd0;
      // {progbufsize[28:24]=0, reserved[23:13]=0, busy[12], reserved[11],
      //  cmderr[10:8], reserved[7:4]=0, datacount[3:0]=2}.
      // datacount=2 advertises both data0 and data1; OpenOCD uses
      // data1 as the address register for cmdtype=2 memaccess.
      ABSTRACTCS:   dmi_do_o <= {3'd0, 5'd0, 11'd0, abstractcs[12], 1'b0, abstractcs[10:8], 4'd0, 4'd2};
      COMMAND:      dmi_do_o <= command;
      ABSTRACTAUTO: dmi_do_o <= {30'd0, abstractauto[1:0]};
      // sbcs per Spec 1.0 §3.15.22.
      //   [31:29] sbversion   = 1 (1.0)
      //   [28:23] reserved 0
      //   [22] sbbusyerror   (R/W1C)
      //   [21] sbbusy        (R)
      //   [20] sbreadonaddr  (R/W)
      //   [19:17] sbaccess    (R/W) — 0=8b, 1=16b, 2=32b
      //   [16] sbautoincrement (R/W)
      //   [15] sbreadondata  (R/W)
      //   [14:12] sberror    (R/W1C)
      //   [11:5] sbasize     = 32 (system address bus is 32 bits)
      //   [4] sbaccess128    = 0
      //   [3] sbaccess64     = 0
      //   [2] sbaccess32     = 1
      //   [1] sbaccess16     = 1
      //   [0] sbaccess8      = 1
      SBCS:         dmi_do_o <= {3'd1, 6'd0,
                                 sbcs_sbbusyerror,
                                 sbbusy,
                                 sbcs_sbreadonaddr,
                                 sbcs_sbaccess,
                                 sbcs_sbautoincrement,
                                 sbcs_sbreadondata,
                                 sbcs_sberror,
                                 7'd32,
                                 5'b00111};
      SBADDRESS0:   dmi_do_o <= sbaddress0;
      // sbaddress1/2/3 not present (sbasize=32).
      SBADDRESS1:   dmi_do_o <= 32'd0;
      SBADDRESS2:   dmi_do_o <= 32'd0;
      SBADDRESS3:   dmi_do_o <= 32'd0;
      SBDATA0:      dmi_do_o <= sbdata0;
      // sbdata1/2/3 not present (no 64/128-bit access).
      SBDATA1:      dmi_do_o <= 32'd0;
      SBDATA2:      dmi_do_o <= 32'd0;
      SBDATA3:      dmi_do_o <= 32'd0;
      default:      dmi_do_o <= 0;
    endcase
end : dm_readlogic

endmodule
