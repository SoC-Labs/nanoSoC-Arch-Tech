//-----------------------------------------------------------------------------
// Structural passthrough — connects input directly to output.
// Synthesis-transparent: optimized to a wire by all tools.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module soc_glue_passthrough #(
    parameter WIDTH = 1
) (
    input  wire [WIDTH-1:0] in,
    output wire [WIDTH-1:0] out
);

    assign out = in;

endmodule
