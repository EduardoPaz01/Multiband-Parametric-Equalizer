module delta_sigma #(
    parameter WIDTH = 16
)(
    input  wire                    clk,    // Clock gerado pela PLL (de preferência 12,288 MHz ou 24,576 MHz)
    input  wire                    rst_n,  // Reset ativo em nível baixo (ex.: KEY[0] da DE10-Lite)
    input  wire signed [WIDTH-1:0] din,    // Amostra de áudio 16 bits signed (saída do limitador)
    output reg                     dout    // Saída PDM de 1 bit (pino digital da FPGA para o filtro RC)
);

    // 1. Converte de signed (-32768 a +32767) para unsigned (0 a 65535)
    //    invertendo apenas o bit mais significativo (MSB).
    wire [WIDTH-1:0] din_unsigned;
    assign din_unsigned = {~din[WIDTH-1], din[WIDTH-2:0]};

    // 2. Registrador acumulador do erro de quantização e soma com carry-out
    reg  [WIDTH-1:0] acc;
    wire [WIDTH:0]   sum;

    assign sum = {1'b0, acc} + {1'b0, din_unsigned};

    // 3. A cada ciclo do clock rápido, acumula o resto e envia o overflow (carry) ao pino
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= {WIDTH{1'b0}};
            dout <= 1'b0;
        end else begin
            acc  <= sum[WIDTH-1:0]; // Realimenta o erro de quantização
            dout <= sum[WIDTH];     // Bit de carry-out gera o trem de pulsos de 1 bit
        end
    end

endmodule
