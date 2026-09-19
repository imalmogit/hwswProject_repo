// ---------------------------------------------------------------------------
// tb_mtf_unit -- self-checking testbench for the move-to-front accelerator
//
// Stimulus is captured from a real pyflate bzip2 decode by gen_stimulus.py:
// the initial 'favourites' table and every (index, promoted symbol) pair the
// Python implementation produced. The DUT must reproduce that symbol stream
// exactly, which is what makes it a drop-in replacement for
//
//     l[:] = l[c:c+1] + l[0:c] + l[c+1:]
//
// Also checks reset behaviour, the bounds check, and back-to-back throughput.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "stim_params.vh"

module tb_mtf_unit;

    localparam integer N    = 256;
    localparam integer DW   = 8;
    localparam integer IW   = 8;
    localparam integer TLEN = `STIM_TABLE_LEN;
    localparam integer NVEC = `STIM_NUM_VECTORS;

    reg              clk = 1'b0;
    reg              rst_n = 1'b0;
    reg              load_en = 1'b0;
    reg  [IW-1:0]    load_addr = 0;
    reg  [DW-1:0]    load_data = 0;
    reg  [IW:0]      load_len = 0;
    reg              load_commit = 1'b0;
    reg              req_valid = 1'b0;
    reg  [IW-1:0]    req_index = 0;
    wire             req_ready;
    wire             rsp_valid;
    wire [DW-1:0]    rsp_data;
    wire             rsp_error;

    always #5 clk = ~clk;              // 100 MHz simulation clock

    mtf_unit #(.N(N), .DW(DW), .IW(IW)) dut (
        .clk(clk), .rst_n(rst_n),
        .load_en(load_en), .load_addr(load_addr), .load_data(load_data),
        .load_len(load_len), .load_commit(load_commit),
        .req_valid(req_valid), .req_index(req_index), .req_ready(req_ready),
        .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_error(rsp_error)
    );

    reg [DW-1:0] init_tbl [0:TLEN-1];
    reg [DW-1:0] vectors  [0:2*NVEC-1];   // idx, golden, idx, golden, ...

    integer i;
    integer errors  = 0;
    integer checked = 0;
    integer issued  = 0;

    // ---- scoreboard -------------------------------------------------------
    // exp_value is driven alongside req_index, so it is sampled on the same
    // edge at which the DUT captures the request. One pipeline stage then
    // aligns it with the DUT's registered response.
    reg  [DW-1:0] exp_value = 0;
    reg  [DW-1:0] exp_pipe  = 0;
    reg           exp_pipe_v = 1'b0;
    reg           scoreboard_on = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            exp_pipe_v <= 1'b0;
        end else begin
            exp_pipe   <= exp_value;
            exp_pipe_v <= scoreboard_on & req_valid & req_ready;
        end
    end

    always @(posedge clk) begin
        if (rst_n && exp_pipe_v) begin
            checked = checked + 1;
            if (!rsp_valid) begin
                errors = errors + 1;
                if (errors <= 5) $display("  [%0d] no response", checked);
            end else if (rsp_error) begin
                errors = errors + 1;
                if (errors <= 5) $display("  [%0d] unexpected error flag", checked);
            end else if (rsp_data !== exp_pipe) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("  [%0d] got %02h expected %02h", checked, rsp_data, exp_pipe);
            end
        end
    end

    initial begin
        $readmemh("stim_table.hex",   init_tbl);
        $readmemh("stim_vectors.hex", vectors);

        $display("=====================================================");
        $display(" mtf_unit testbench");
        $display("   table entries : %0d", TLEN);
        $display("   vectors       : %0d  (captured from a real bzip2 decode)", NVEC);
        $display("=====================================================");

        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        if (req_ready !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL: req_ready asserted before the table was armed");
        end else begin
            $display("  reset       : req_ready low until the table is armed");
        end

        // ---- load the captured table ----
        for (i = 0; i < TLEN; i = i + 1) begin
            @(posedge clk);
            load_en   <= 1'b1;
            load_addr <= i[IW-1:0];
            load_data <= init_tbl[i];
        end
        @(posedge clk);
        load_en     <= 1'b0;
        load_len    <= TLEN[IW:0];
        load_commit <= 1'b1;
        @(posedge clk);
        load_commit <= 1'b0;
        @(posedge clk);

        if (req_ready !== 1'b1) begin
            errors = errors + 1;
            $display("FAIL: req_ready low after commit");
        end else begin
            $display("  arm         : req_ready high after load_commit");
        end

        // ---- stream every captured vector, back to back, no bubbles ----
        scoreboard_on <= 1'b1;
        for (i = 0; i < NVEC; i = i + 1) begin
            req_valid <= 1'b1;
            req_index <= vectors[2*i];
            exp_value <= vectors[2*i + 1];
            issued = issued + 1;
            @(posedge clk);
        end
        req_valid     <= 1'b0;
        scoreboard_on <= 1'b0;
        @(posedge clk);
        @(posedge clk);

        // ---- bounds check: an index past the committed length ----
        req_valid <= 1'b1;
        req_index <= TLEN[IW-1:0];          // first invalid index
        @(posedge clk);
        req_valid <= 1'b0;
        @(posedge clk);
        if (!(rsp_valid && rsp_error)) begin
            errors = errors + 1;
            $display("FAIL: out-of-range index did not raise rsp_error");
        end else begin
            $display("  bounds check: index %0d correctly rejected", TLEN);
        end

        $display("-----------------------------------------------------");
        $display("  issued     : %0d", issued);
        $display("  checked    : %0d", checked);
        $display("  mismatches : %0d", errors);
        if (errors == 0 && checked == NVEC)
            $display("  RESULT: PASS -- output stream matches pyflate exactly");
        else
            $display("  RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end

endmodule
