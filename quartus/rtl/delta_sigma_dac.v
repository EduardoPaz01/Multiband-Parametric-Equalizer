module delta_sigma_dac (
	input 				reset,
	input 				clk,
	input 	signed 	[15:0] x, //entrada de 16 bits para o modulador
	output 	reg 		y
);
	wire [15:0] x_unsigned;
	wire [16:0] sum;
	reg  [15:0] acc;

	// Converte signed [-32768, +32767] para unsigned [0, 65535]
	assign x_unsigned = {~x[15], x[14:0]};
	assign sum        = {1'b0, acc} + {1'b0, x_unsigned};
	
endmodule
