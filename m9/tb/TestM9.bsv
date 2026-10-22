package TestM9;

import RetxTypes::*;
import RetxStateManager::*;

(* synthesize *)
module mkTestM9(RetxStateManagerIfc);
    RetxStateManagerIfc dut <- mkRetxStateManager;
    return dut;
endmodule

endpackage
