// ============================================================================
//  eq_biquad_cascade  --  cascata de NSEC biquads IIR (Direct Form I), mono
//
//  Recebe os coeficientes ja calculados (eq_coef_calc) e aplica ao audio.
//  Um unico multiplicador 40x32 (dividido em dois 40x16 pipelinados) e um
//  acumulador largo sao reutilizados no tempo por todas as secoes.
//
//  y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] + (-a1)*y[n-1] + (-a2)*y[n-2]
//
//  Formatos:
//    s_data  : Q1.(DW-1)           (ex.: Q1.23, 24 bits)
//    coef    : Q3.CF   (CW bits)   ordem por secao [b0 b1 b2 -a1 -a2]
//    estado  : Q(1+GB).(DW-1+SX)   (YW = DW+GB+SX bits; ex.: 40 bits)
//    m_data  : Q(1+GB).(DW-1)      (DW+GB bits, com bits de guarda)
//
//  Protocolo: s_valid = pulso de 1 ciclo com amostra nova (ex.: 48 kHz).
//             m_valid = pulso de 1 ciclo; m_data fica estavel ate o proximo.
//  Os coeficientes sao capturados (latch) no ciclo do s_valid, entao o
//  conjunto usado em uma amostra e sempre coerente.
//  Latencia medida: 28 ciclos de clock para 3 secoes (~0,56 us a 50 MHz).
// ============================================================================
module eq_biquad_cascade #(
    parameter NSEC = 3,     // numero de secoes (bandas)
    parameter DW   = 24,    // largura da amostra de entrada
    parameter GB   = 4,     // bits de guarda (headroom) na saida e no estado
    parameter CW   = 32,    // largura dos coeficientes
    parameter CF   = 29,    // bits fracionarios dos coeficientes (Q3.29)
    parameter SX   = 12     // bits fracionarios extras no estado
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     s_valid,
    input  wire signed [DW-1:0]     s_data,
    input  wire [NSEC*5*CW-1:0]     coef_bus,   // secao k: bits [(5k+i)*CW +: CW]

    output reg                      m_valid,
    output reg  signed [DW+GB-1:0]  m_data,
    output reg                      busy,
    output reg                      clip,       // houve saturacao nesta amostra
    output reg                      overrun     // s_valid chegou com o bloco ocupado
);
    localparam XW   = DW + GB;
    localparam YW   = XW + SX;
    localparam HC   = CW / 2;
    localparam ACCW = YW + CW + 4;

    localparam signed [YW-1:0]   YMAX = {1'b0, {(YW-1){1'b1}}};
    localparam signed [YW-1:0]   YMIN = {1'b1, {(YW-1){1'b0}}};
    localparam signed [XW-1:0]   OMAX = {1'b0, {(XW-1){1'b1}}};
    localparam signed [XW-1:0]   OMIN = {1'b1, {(XW-1){1'b0}}};
    localparam signed [ACCW-1:0] HALF = 1 <<< (CF-1);

    // ------------------------------------------------------------------ estado
    (* ramstyle = "logic" *) reg signed [YW-1:0] x1 [0:NSEC-1];
    (* ramstyle = "logic" *) reg signed [YW-1:0] x2 [0:NSEC-1];
    (* ramstyle = "logic" *) reg signed [YW-1:0] y1 [0:NSEC-1];
    (* ramstyle = "logic" *) reg signed [YW-1:0] y2 [0:NSEC-1];

    reg [NSEC*5*CW-1:0] coef_lat;

    localparam [1:0] S_IDLE = 2'd0, S_ISSUE = 2'd1, S_WAIT = 2'd2;
    reg [1:0]           st;
    reg [3:0]           sec;
    reg [2:0]           ti;
    reg signed [YW-1:0] x_cur;
    reg                 clip_acc;

    // ----------------------------------------------- selecao dos 5 termos/secao
    reg signed [YW-1:0] term_a;
    always @(*) begin
        case (ti)
            3'd0:    term_a = x_cur;
            3'd1:    term_a = x1[sec];
            3'd2:    term_a = x2[sec];
            3'd3:    term_a = y1[sec];
            default: term_a = y2[sec];
        endcase
    end
    wire [CW-1:0] term_b = coef_lat[(sec*5 + ti)*CW +: CW];

    // --------------------------------------------------------- pipeline do MAC
    // estagio 0: registradores de operandos
    reg signed [YW-1:0] op_a;
    reg        [CW-1:0] op_b;
    reg                 v0, f0, l0;
    // estagio 1: dois produtos parciais  A*Bhi e A*Blo (Blo sem sinal)
    wire signed [HC:0]   b_lo = {1'b0, op_b[HC-1:0]};
    wire signed [HC-1:0] b_hi = op_b[CW-1:HC];
    reg  signed [YW+HC:0]   p_lo;
    reg  signed [YW+HC-1:0] p_hi;
    reg                 v1, f1, l1;
    // estagio 2: soma dos parciais
    wire signed [ACCW-1:0] p_lo_x = p_lo;
    wire signed [ACCW-1:0] p_hi_x = p_hi;
    reg  signed [ACCW-1:0] sum_r;
    reg                 v2, f2, l2;
    // estagio 3: acumulador
    reg  signed [ACCW-1:0] acc;
    reg                 v3, l3;

    always @(posedge clk) begin
        p_lo  <= op_a * b_lo;
        p_hi  <= op_a * b_hi;
        sum_r <= (p_hi_x <<< HC) + p_lo_x;
        if (v2) acc <= (f2 ? {ACCW{1'b0}} : acc) + sum_r;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            f1 <= 1'b0; f2 <= 1'b0; l1 <= 1'b0; l2 <= 1'b0; l3 <= 1'b0;
        end else begin
            v1 <= v0; f1 <= f0; l1 <= l0;
            v2 <= v1; f2 <= f1; l2 <= l1;
            v3 <= v2;           l3 <= l2;
        end
    end

    // ---------------------------------- arredondamento e saturacao do resultado
    wire done = v3 & l3;                                   // acc final valido

    wire signed [ACCW-1:0]    acc_rnd = acc + HALF;        // round-half-up
    wire signed [ACCW-CF-1:0] y_full  = acc_rnd >>> CF;
    wire y_pos = (y_full > YMAX);
    wire y_neg = (y_full < YMIN);
    wire signed [YW-1:0] y_new = y_pos ? YMAX : (y_neg ? YMIN : y_full[YW-1:0]);

    // saida: remove os SX bits extras (arredonda) e satura em XW bits
    wire signed [YW:0]    y_o1 = y_new + (1 <<< (SX-1));
    wire signed [YW-SX:0] y_o  = y_o1 >>> SX;
    wire o_pos = (y_o > OMAX);
    wire o_neg = (y_o < OMIN);
    wire signed [XW-1:0] m_nxt = o_pos ? OMAX : (o_neg ? OMIN : y_o[XW-1:0]);

    // ---------------------------------------------------------------------- FSM
    integer i;
    always @(posedge clk) begin
        m_valid <= 1'b0;
        overrun <= 1'b0;
        v0      <= 1'b0;

        if (!rst_n) begin
            st <= S_IDLE; busy <= 1'b0; clip <= 1'b0; clip_acc <= 1'b0;
            m_data <= {XW{1'b0}}; sec <= 4'd0; ti <= 3'd0;
            for (i = 0; i < NSEC; i = i + 1) begin
                x1[i] <= {YW{1'b0}}; x2[i] <= {YW{1'b0}};
                y1[i] <= {YW{1'b0}}; y2[i] <= {YW{1'b0}};
            end
        end else begin
            if (s_valid && busy) overrun <= 1'b1;

            case (st)
                S_IDLE: if (s_valid) begin
                    coef_lat <= coef_bus;
                    x_cur    <= {{GB{s_data[DW-1]}}, s_data, {SX{1'b0}}};
                    sec      <= 4'd0;
                    ti       <= 3'd0;
                    clip_acc <= 1'b0;
                    busy     <= 1'b1;
                    st       <= S_ISSUE;
                end

                S_ISSUE: begin                      // 1 termo (A*B) por ciclo
                    op_a <= term_a;
                    op_b <= term_b;
                    v0   <= 1'b1;
                    f0   <= (ti == 3'd0);
                    l0   <= (ti == 3'd4);
                    ti   <= ti + 3'd1;
                    if (ti == 3'd4) st <= S_WAIT;
                end

                S_WAIT: if (done) begin             // pipeline esvaziou
                    x2[sec] <= x1[sec];
                    x1[sec] <= x_cur;
                    y2[sec] <= y1[sec];
                    y1[sec] <= y_new;
                    if (y_pos | y_neg) clip_acc <= 1'b1;

                    if (sec == NSEC-1) begin
                        m_data  <= m_nxt;
                        m_valid <= 1'b1;
                        clip    <= clip_acc | y_pos | y_neg | o_pos | o_neg;
                        busy    <= 1'b0;
                        st      <= S_IDLE;
                    end else begin
                        sec   <= sec + 4'd1;
                        x_cur <= y_new;
                        ti    <= 3'd0;
                        st    <= S_ISSUE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
