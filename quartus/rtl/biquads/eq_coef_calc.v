// ============================================================================
//  eq_coef_calc  --  converte o vetor de ganhos (dB) nos coeficientes dos
//                    biquads, com transicao suave (slew) para evitar estalos.
//
//  gain_db : NB campos de 5 bits com sinal (complemento de 2), banda 0 nos
//            bits menos significativos. Faixa valida -12..+12 dB (passo 1 dB);
//            valores fora da faixa sao saturados.
//  upd     : pulso de 1 ciclo, uma vez por amostra de audio (use o s_valid).
//            Os ganhos sao capturados nesse ciclo.
//  coef_bus: NB*5 coeficientes Q3.29, banda k em [(5k+i)*CW +: CW],
//            ordem [b0 b1 b2 -a1 -a2]. So muda nos ~17 ciclos seguintes ao
//            upd, longe do instante em que o filtro captura os coeficientes.
//
//  Como funciona: a ROM (eq_coef_rom) entrega o coeficiente ALVO para
//  (banda, ganho). Um varredor serial, 1 coeficiente por ciclo, aproxima o
//  valor atual do alvo:   cur += (alvo - cur) >>> SLEW_SHIFT
//  Constante de tempo = 2^SLEW_SHIFT amostras (9 -> ~10,7 ms a 48 kHz).
//  Na partida os coeficientes sao "transparentes" (b0 = 1, resto 0) e a
//  resposta sobe suavemente ate o ganho pedido.
// ============================================================================
module eq_coef_calc #(
    parameter NB         = 3,     // numero de bandas (<= 4)
    parameter CW         = 32,
    parameter CF         = 29,
    parameter SLEW_SHIFT = 9
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 upd,
    input  wire [NB*5-1:0]      gain_db,
    output wire [NB*5*CW-1:0]   coef_bus
);
    localparam [CW-1:0] ONE = 1 << CF;

    reg [NB*5*CW-1:0] coef_reg;
    reg [NB*5-1:0]    gain_lat;
    reg               run;
    reg [1:0]         b_i;          // banda em varredura
    reg [2:0]         c_i;          // coeficiente em varredura (0..4)
    reg               v_d;          // dados da ROM validos (1 ciclo de atraso)
    reg [1:0]         b_d;
    reg [2:0]         c_d;

    // ganho da banda atual -> indice da ROM (saturado em +-12 dB)
    wire signed [4:0] g_raw = gain_lat[b_i*5 +: 5];
    wire signed [4:0] g_cl  = (g_raw >  5'sd12) ?  5'sd12 :
                              (g_raw < -5'sd12) ? -5'sd12 : g_raw;
    wire        [4:0] gidx  = g_cl + 5'sd12;

    wire [31:0] tgt;
    eq_coef_rom u_rom (.clk(clk), .band(b_i), .gidx(gidx), .cidx(c_i), .q(tgt));

    // um passo de slew
    wire signed [CW-1:0] cur   = coef_reg[(b_d*5 + c_d)*CW +: CW];
    wire signed [CW-1:0] tgt_s = tgt;
    wire signed [CW:0]   diff  = tgt_s - cur;
    wire signed [CW:0]   dlt0  = diff >>> SLEW_SHIFT;
    wire signed [CW:0]   dlt   = (diff > 0 && dlt0 == 0) ? 33'sd1 : dlt0;   // garante chegada exata
    wire signed [CW:0]   nxt   = cur + dlt;

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            run <= 1'b0; v_d <= 1'b0; b_i <= 2'd0; c_i <= 3'd0;
            b_d <= 2'd0; c_d <= 3'd0; gain_lat <= {(NB*5){1'b0}};
            for (k = 0; k < NB; k = k + 1) begin
                coef_reg[(k*5+0)*CW +: CW] <= ONE;
                coef_reg[(k*5+1)*CW +: CW] <= {CW{1'b0}};
                coef_reg[(k*5+2)*CW +: CW] <= {CW{1'b0}};
                coef_reg[(k*5+3)*CW +: CW] <= {CW{1'b0}};
                coef_reg[(k*5+4)*CW +: CW] <= {CW{1'b0}};
            end
        end else begin
            v_d <= run;
            b_d <= b_i;
            c_d <= c_i;

            if (upd) begin
                gain_lat <= gain_db;
                run <= 1'b1; b_i <= 2'd0; c_i <= 3'd0;
            end else if (run) begin
                if (c_i == 3'd4) begin
                    c_i <= 3'd0;
                    if (b_i == NB-1) run <= 1'b0;
                    else             b_i <= b_i + 2'd1;
                end else begin
                    c_i <= c_i + 3'd1;
                end
            end

            if (v_d) coef_reg[(b_d*5 + c_d)*CW +: CW] <= nxt[CW-1:0];
        end
    end

    assign coef_bus = coef_reg;
endmodule
