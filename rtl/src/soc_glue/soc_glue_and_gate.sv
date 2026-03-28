//-----------------------------------------------------------------------------
// Structural 2-input AND gate — AND-combines two WIDTH-bit inputs.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module soc_glue_and_gate #(
    parameter WIDTH = 1
) (
    input  wire [WIDTH-1:0] in_a,
    input  wire [WIDTH-1:0] in_b,
    output wire [WIDTH-1:0] out
);

    assign out = in_a & in_b;

endmodule
