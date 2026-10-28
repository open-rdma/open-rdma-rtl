package TestE2e;

import E2eTop :: *;

(* synthesize *)
module mkTestE2e(E2eTopIfc);
    E2eTopIfc dut <- mkE2eTop;
    return dut;
endmodule

endpackage
