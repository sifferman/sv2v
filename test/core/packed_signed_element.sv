module sink #(parameter integer V = 0) (
    output logic signed [3:0] x,
    output logic [7:0] y
);
    assign x = -1;
    assign y = V;
endmodule

module top;
    typedef logic signed [3:0] elem_t;
    typedef logic signed [7:0] wide_t;
    typedef logic signed [1:0][3:0] pair_t;
    typedef logic signed bit_t;
    typedef elem_t unpacked_t [2];
    elem_t [1:0] a;
    elem_t [1:0][1:0] b = '1;
    logic signed [1:0][3:0] c = '1;
    pair_t [1:0] d = '1;
    struct packed signed { logic [3:0] f; } [1:0] e = '1;
    logic signed [3:0] f [2] = '{-1, -1};
    localparam unpacked_t P = '{-1, -1};
    wide_t [1:0] w = '0;
    var type(a[0]) g = -1;
    bit_t [3:0] m = '1;
    var type(m[0]) n = '1;
    elem_t [1:0] p;
    logic [7:0] v;
    sink #(P[0]) s(p[0], v);
    task automatic set(output elem_t o, input elem_t i);
        o = i;
    endtask
    initial begin
        a[0] = -1;
        set(a[1], $signed(c[0]));
        w[0] += a[0];
        #1;
        $display("%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
            a[0], a[1], a, b[1][0], b[1], c[0], d[1][0], d[1], e[0], f[0],
            P[0], w[0], g, v, m[0], m, n);
    end
endmodule
