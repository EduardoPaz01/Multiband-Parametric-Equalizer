// ============================================================================
//  eq3_dsp  --  equalizador de 3 bandas (mono) para a DE10-Lite
//
//    audio (Q1.23) + ganhos em dB por banda  -->  audio equalizado
//
//  banda 0: low-shelf  150 Hz | banda 1: peaking 1 kHz | banda 2: high-shelf 6 kHz
//  (frequencias/Q definidos em model/gen_coef_rom.py)
//
//  gain_db = {g2[4:0], g1[4:0], g0[4:0]}, cada g em complemento de 2, -12..+12 dB.
//  A saida m_data tem GB bits de guarda: o ganho master + limitador devem
//  vir depois (bloco 06) para reduzir a Q1.23 sem corte duro.
//
//  Sub-blocos:
//    eq_coef_calc       : ganhos (dB) -> coeficientes (ROM + slew)
//    eq_biquad_cascade  : aplica os coeficientes ao audio (DF1, MAC serial)

// O equalizador entrega o áudio já filtrado com folga interna de 4 bits para cálculos seguros (4 bits de guarda), 
// avisa quando o dado na saída é válido (m_valid), sinaliza se o volume estourou o limite e foi cortado (clip), 
// mostra se o módulo está em processamento (busy) e alerta se houve perda de dados por excesso/atraso no fluxo (overrun)
// ============================================================================
module eq3_dsp #(
    parameter DW         = 24,
    parameter GB         = 4,
    parameter SLEW_SHIFT = 9
)(
    input  wire                    clk,        // 50 MHz
    input  wire                    rst_n,

    input  wire                    s_valid,    // 1 pulso por amostra (48 kHz)
    input  wire signed [DW-1:0]    s_data,
    input  wire [14:0]             gain_db,

    output wire                    m_valid,
    output wire signed [DW+GB-1:0] m_data,
    output wire                    busy,
    output wire                    clip,
    output wire                    overrun
);
    localparam NB = 3;
    localparam CW = 32;

    wire [NB*5*CW-1:0] coef_bus;

    eq_coef_calc #(.NB(NB), .CW(CW), .CF(29), .SLEW_SHIFT(SLEW_SHIFT)) u_calc (
        .clk      (clk),
        .rst_n    (rst_n),
        .upd      (s_valid),
        .gain_db  (gain_db),
        .coef_bus (coef_bus)
    );

    eq_biquad_cascade #(.NSEC(NB), .DW(DW), .GB(GB), .CW(CW), .CF(29), .SX(12)) u_eq (
        .clk      (clk),
        .rst_n    (rst_n),
        .s_valid  (s_valid),
        .s_data   (s_data),
        .coef_bus (coef_bus),
        .m_valid  (m_valid),
        .m_data   (m_data),
        .busy     (busy),
        .clip     (clip),
        .overrun  (overrun)
    );
endmodule
