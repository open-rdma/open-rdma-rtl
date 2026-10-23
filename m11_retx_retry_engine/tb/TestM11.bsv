package TestM11;

import RetxTypes::*;
import RetxRetryEngine::*;

(* synthesize *)
module mkTestM11(RetxRetryEngineIfc);
    RetxRetryEngineIfc dut <- mkRetxRetryEngine;
    return dut;
endmodule

endpackage
