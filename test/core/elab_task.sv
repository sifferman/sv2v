module top;
    $info;
    $info("%b", 1);
    $warning;
    $warning("%b", 2);
    $error;
    $error("%b", 3);
    $fatal;
    $fatal(0);
    $fatal(1, "%b", 4);
endmodule
