import CommonTypes :: *;
import DoorbellIngress :: *;
import TxMvpTypes :: *;

interface TestDoorbellDecoder;
    interface PipeIn#(GdrpDoorbellWrite) doorbellPipeIn;
    interface PipeOut#(DecodedGdrpSubmission) decodedPipeOut;
endinterface

(* synthesize *)
module mkTestDoorbellDecoder(TestDoorbellDecoder);
    DoorbellDecoderIfc dut <- mkDoorbellDecoder(64'h0000_0000_0000_1000);

    interface doorbellPipeIn = dut.doorbellIn;
    interface decodedPipeOut = dut.decodedOut;
endmodule
