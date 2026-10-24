module sink #(parameter integer V = 0) (
    output wire signed [3:0] x,
    output wire [7:0] y
);
    assign x = -1;
    assign y = V;
endmodule

module top;
    reg [7:0] a;
    reg [15:0] b = -1;
    reg signed [7:0] c = -1;
    reg [15:0] d = -1;
    reg [7:0] e = -1;
    reg [7:0] f = -1;
    localparam [7:0] P = -1;
    reg [15:0] w = 0;
    reg signed [3:0] g = -1;
    wire [7:0] p;
    wire [7:0] v;
    sink #($signed(P[3:0])) s(p[3:0], v);
    task automatic set(output reg signed [3:0] o, input reg signed [3:0] i);
        o = i;
    endtask
    initial begin
        a[3:0] = -1;
        set(a[7:4], $signed(c[3:0]));
        w[7:0] = $signed(w[7:0]) + $signed(a[3:0]);
        #1;
        $display("%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
            $signed(a[3:0]), $signed(a[7:4]), a, $signed(b[11:8]), b[15:8],
            c[3:0], d[11:8], $signed(e[3:0]), $signed(f[3:0]),
            $signed(P[3:0]), $signed(w[7:0]), g, v);
    end
endmodule
