package DoorbellIngress;

import Assert :: *;
import Connectable :: *;
import FIFOF :: *;

import CommonTypes :: *;
import TxMvp :: *;
import TxMvpTypes :: *;

interface DoorbellDecoderIfc;
    interface PipeIn#(GdrpDoorbellWrite) doorbellIn;
    interface PipeOut#(DecodedGdrpSubmission) decodedOut;
endinterface

function Bool doorbellAddressIsValid(
    GdrpDoorbellWrite write,
    Bit#(64) doorbellBarOffset
);
    if (write.barOffset < doorbellBarOffset)
        return False;
    else begin
        Bit#(64) relativeOffset = write.barOffset - doorbellBarOffset;
        return relativeOffset < 64'd32;
    end
endfunction

function Bool doorbellWriteIsValid(
    GdrpDoorbellWrite write,
    Bit#(64) doorbellBarOffset
);
    return doorbellBarOffset[2:0] == 0 &&
           write.storeBytes == 8 &&
           write.byteEnable == 8'hff &&
           write.barOffset[2:0] == 0 &&
           doorbellAddressIsValid(write, doorbellBarOffset);
endfunction

module mkDoorbellDecoder#(Bit#(64) doorbellBarOffset)(DoorbellDecoderIfc);
    FIFOF#(GdrpDoorbellWrite) doorbellQ <- mkSizedFIFOF(2);
    FIFOF#(DecodedGdrpSubmission) decodedQ <- mkSizedFIFOF(2);

    // Rejects do not depend on decodedQ readiness, so a blocked consumer cannot
    // delay fail-stop detection for the invalid head of doorbellQ.
    rule rejectInvalidDoorbell (!doorbellWriteIsValid(
        doorbellQ.first,
        doorbellBarOffset
    ));
        let write = doorbellQ.first;
        if (doorbellBarOffset[2:0] != 0)
            dynamicAssert(False, "M0_DOORBELL_UNALIGNED_BASE");
        else if (write.storeBytes != 8)
            dynamicAssert(False, "M0_DOORBELL_INVALID_STORE_SIZE");
        else if (write.byteEnable != 8'hff)
            dynamicAssert(False, "M0_DOORBELL_PARTIAL_STORE");
        else if (write.barOffset[2:0] != 0)
            dynamicAssert(False, "M0_DOORBELL_UNALIGNED_ADDRESS");
        else
            dynamicAssert(False, "M0_DOORBELL_INVALID_ADDRESS");
    endrule

    rule decodeDoorbell (doorbellWriteIsValid(
        doorbellQ.first,
        doorbellBarOffset
    ));
        let write = doorbellQ.first;
        Bit#(64) relativeOffset = write.barOffset - doorbellBarOffset;
        TxQpn qpn = zeroExtend(relativeOffset[4:3]);
        doorbellQ.deq;
        decodedQ.enq(DecodedGdrpSubmission {
            qpn: qpn,
            token: write.token
        });
    endrule

    interface doorbellIn = toPipeIn(doorbellQ);
    interface decodedOut = toPipeOut(decodedQ);
endmodule

interface DoorbellTxMvpIfc;
    interface ServerP#(SlotCfgReq, TxCfgResp) slotConfig;
    interface ServerP#(QpCfgReq, TxCfgResp) qpConfig;
    interface ServerP#(MrCfgReq, TxCfgResp) mrConfig;
    interface ServerP#(PgtCfgReq, TxCfgResp) pgtConfig;

    interface PipeIn#(GdrpDoorbellWrite) doorbellIn;
    interface PipeOut#(TxDmaReadRequest) dmaReadReqOut;
endinterface

module mkDoorbellTxMvp#(Bit#(64) doorbellBarOffset)(DoorbellTxMvpIfc);
    DoorbellDecoderIfc decoder <- mkDoorbellDecoder(doorbellBarOffset);
    TxMvpIfc mvp <- mkTxMvp;

    mkConnection(decoder.decodedOut, mvp.submissionIn);

    interface slotConfig = mvp.slotConfig;
    interface qpConfig = mvp.qpConfig;
    interface mrConfig = mvp.mrConfig;
    interface pgtConfig = mvp.pgtConfig;
    interface doorbellIn = decoder.doorbellIn;
    interface dmaReadReqOut = mvp.dmaReadReqOut;
endmodule

endpackage
