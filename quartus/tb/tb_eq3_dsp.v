`timescale 1ns/1ps
// Le vectors.hex (linhas de 40 bits: {gain16, sample24}) e grava out.txt
// com "m_data clip" por amostra processada.
module tb_eq3_dsp;
    parameter NS     = 6000;   // numero de amostras
    parameter PERIOD = 120;    // ciclos de clock entre amostras (>= ~60)
    parameter GB     = 4;
    parameter SLEW   = 4;
    localparam DW    = 24;

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;                     // 50 MHz

    reg                     s_valid = 1'b0;
    reg  signed [DW-1:0]    s_data  = 0;
    reg  [14:0]             gain_db = 0;
    wire                    m_valid, busy, clip, overrun;
    wire signed [DW+GB-1:0] m_data;

    eq3_dsp #(.DW(DW), .GB(GB), .SLEW_SHIFT(SLEW)) dut (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_data(s_data),
        .gain_db(gain_db), .m_valid(m_valid), .m_data(m_data),
        .busy(busy), .clip(clip), .overrun(overrun)
    );

    reg [39:0] vec [0:NS-1];
    integer n, fd, n_out, n_over;

    always @(posedge clk) begin
        if (m_valid) begin
            $fdisplay(fd, "%0d %0d", m_data, clip);
            n_out = n_out + 1;
        end
        if (overrun) n_over = n_over + 1;
    end

    initial begin
        n_out = 0; n_over = 0;
        $readmemh("vectors.hex", vec);
        fd = $fopen("out.txt", "w");
        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (5) @(posedge clk);

        for (n = 0; n < NS; n = n + 1) begin
            #1;
            gain_db = vec[n][38:24];
            s_data  = vec[n][23:0];
            @(posedge clk); #1 s_valid = 1'b1;
            @(posedge clk); #1 s_valid = 1'b0;
            repeat (PERIOD-2) @(posedge clk);
        end
        repeat (PERIOD) @(posedge clk);
        $fclose(fd);
        $display("FIM: %0d saidas, %0d overruns", n_out, n_over);
        $finish;
    end
endmodule
