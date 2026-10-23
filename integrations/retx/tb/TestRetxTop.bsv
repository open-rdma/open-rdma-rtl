package TestRetxTop;

import RetxTop::*;

(* synthesize *)
module mkTestRetxTop(RetxTopIfc);
    RetxTopIfc dut <- mkRetxTop;
    return dut;
endmodule

endpackage
