// ---------------------------------------------------------------------------
// mtf_unit -- Move-To-Front accelerator for bzip2 decoding
//
// Replaces the per-symbol MTF stage that CPython executes as
//
//     def move_to_front(l, c):
//         l[:] = l[c:c+1] + l[0:c] + l[c+1:]
//
// which rebuilds a list of up to 256 entries on every decoded symbol.
// Measured cost in the pyflate profile: 1.798 G instructions per benchmark
// call, 10.74% of the profile.
//
// The unit holds the table in flops and performs the promotion as a
// conditional parallel shift, one symbol per cycle.
//
//   entry[0]        <= table[c]                (the promoted symbol)
//   entry[i], i<=c  <= entry[i-1]              (shift down by one)
//   entry[i], i>c   <= entry[i]                (untouched)
//
// Latency    : 1 cycle (registered outputs)
// Throughput : 1 symbol per cycle, back-to-back
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module mtf_unit #(
    parameter integer N  = 256,   // table entries
    parameter integer DW = 8,     // symbol width
    parameter integer IW = 8      // index width, must satisfy 2**IW >= N
)(
    input  wire            clk,
    input  wire            rst_n,

    // -- table load: written once per bzip2 block ---------------------------
    input  wire            load_en,      // write one entry
    input  wire [IW-1:0]   load_addr,
    input  wire [DW-1:0]   load_data,
    input  wire [IW:0]     load_len,     // number of valid entries, 0..N
    input  wire            load_commit,  // latch load_len, arm the table

    // -- request ------------------------------------------------------------
    input  wire            req_valid,
    input  wire [IW-1:0]   req_index,
    output wire            req_ready,

    // -- response (registered, valid one cycle after an accepted request) ---
    output reg             rsp_valid,
    output reg  [DW-1:0]   rsp_data,
    output reg             rsp_error     // req_index >= load_len
);

    // ---- state -----------------------------------------------------------
    localparam S_LOAD  = 1'b0;   // accepting table writes
    localparam S_READY = 1'b1;   // accepting requests

    reg               state;
    reg  [DW-1:0]     tbl [0:N-1];
    reg  [IW:0]       len;
    integer           i;

    // ---- datapath --------------------------------------------------------
    // 256:1 read mux -- the symbol being promoted
    wire [DW-1:0] sel_data = tbl[req_index];

    // bounds check against the committed table length
    wire          idx_ok   = ({1'b0, req_index} < len);

    // the unit never stalls once armed
    assign req_ready = (state == S_READY);

    // ---- control + sequential logic --------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_LOAD;
            len       <= {(IW+1){1'b0}};
            rsp_valid <= 1'b0;
            rsp_data  <= {DW{1'b0}};
            rsp_error <= 1'b0;
            for (i = 0; i < N; i = i + 1)
                tbl[i] <= {DW{1'b0}};
        end else begin
            // response strobes default low; asserted only on an accepted request
            rsp_valid <= 1'b0;
            rsp_error <= 1'b0;

            case (state)

            S_LOAD: begin
                if (load_en)
                    tbl[load_addr] <= load_data;
                if (load_commit) begin
                    len   <= load_len;
                    state <= S_READY;
                end
            end

            S_READY: begin
                if (load_commit) begin
                    // a new bzip2 block: re-arm with a fresh table
                    len   <= load_len;
                    state <= S_LOAD;
                end else if (req_valid) begin
                    rsp_valid <= 1'b1;
                    if (!idx_ok) begin
                        rsp_error <= 1'b1;        // out of range, table untouched
                    end else begin
                        rsp_data <= sel_data;
                        // conditional parallel shift: N 2:1 muxes
                        for (i = 0; i < N; i = i + 1) begin
                            if (i == 0)
                                tbl[0] <= sel_data;
                            else if (i <= req_index)
                                tbl[i] <= tbl[i-1];
                        end
                    end
                end
            end

            endcase
        end
    end

endmodule
