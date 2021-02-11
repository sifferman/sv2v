`define TEST(x, y) $display("{%b, %b} => %b", x, y, {x, y});

module top;
    initial begin
        `TEST('z, 'x);
        `TEST('1, '0);
        `TEST(2'sh3, 32'd0);
        `TEST(3'sh4, 32'd0);
        `TEST(3'sb101, 32'd0);
        `TEST('sh3, 32'd0);
        `TEST('sh4, 32'd0);
        `TEST('b0101, 32'd0);
        `TEST('sh3, 'd0);
        `TEST('sh4, 'd0);
        `TEST('b0101, 'd0);
    end
endmodule
