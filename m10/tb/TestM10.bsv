package TestM10;

import RetxTypes::*;
import RetxReportEngine::*;

(* synthesize *)
module mkTestM10(RetxReportEngineIfc);
    RetxReportEngineIfc dut <- mkRetxReportEngine;
    return dut;
endmodule

endpackage
