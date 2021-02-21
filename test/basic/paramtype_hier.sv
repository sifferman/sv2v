module Module;
    parameter int S;
    parameter type T;
    T x = '1;
    initial $display("Module %0d: %b, %0d", S, Module.x, $bits(T));
endmodule

module top;
    parameter ONE = 1;
    logic [ONE*7:ONE*0] x;
    if (1) begin : blk
        localparam W = ONE * 3;
        typedef logic [W-1:$bits(x)] T;
        T x;
    end
    Module #(1, logic [$bits(x)-1:0]) m1();
    Module #(2, logic [$bits(blk.x)-1:0]) m2();
    Module #(3, logic [top.blk.W-1:0]) m3();
endmodule
