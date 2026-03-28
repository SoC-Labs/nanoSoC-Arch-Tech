//-----------------------------------------------------------------------------
// Structural OR-reduction — reduces WIDTH-bit input to 1-bit output.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module soc_glue_or_reduce #(
    parameter WIDTH = 1
) (
    input  wire [WIDTH-1:0] in,
    output wire             out
);

    assign out = |in;

endmodule
