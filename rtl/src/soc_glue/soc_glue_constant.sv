//-----------------------------------------------------------------------------
// Structural constant driver — drives a WIDTH-bit output to VALUE.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module soc_glue_constant #(
    parameter WIDTH = 1,
    parameter [WIDTH-1:0] VALUE = {WIDTH{1'b0}}
) (
    output wire [WIDTH-1:0] out
);

    assign out = VALUE;

endmodule
