import FIFOF :: *;
typedef Bit#(64) SimulationTime;

typedef struct {
    String name;
    Bool enableDebug;
} DebugConf deriving (FShow);

function Action immAssertForFpCheck(Bool condition, String assertName, Fmt assertFmtMsg);
    action
        let pos = printPosition(getStringPosition(assertName));
        // let pos = printPosition(getEvalPosition(condition));
        if (!condition) begin
            $display(
                "ImmAssert failed in %m @time=%0t: %s-- %s: ",
                $time, pos, assertName, assertFmtMsg
            );
            // $finish(1);
        end
    endaction
endfunction

function ActionValue#(SimulationTime) getSimulationTime;
    actionvalue
        `ifdef IS_COMPILE_FOR_SIM
            SimulationTime curTime <- $time;
            curTime = unpack(pack(curTime));
            return curTime;
        `else
            return 0;
        `endif
    endactionvalue
endfunction

function Action checkFullyPipeline(SimulationTime previousBeatTime, Integer maxAllowedBeat, Integer clockPeriod, DebugConf dbgConf);
    action
        `ifdef IS_COMPILE_FOR_SIM
            SimulationTime curTime <- $time;
            let deltaTime = (curTime - previousBeatTime) * 1000;
            SimulationTime allowedDelta = fromInteger(maxAllowedBeat * clockPeriod);
            Bool needFullyPipelineCheck <- $test$plusargs("fully-pipeline-check");
            immAssertForFpCheck(
                (!needFullyPipelineCheck) || (deltaTime <= allowedDelta),
                "checkFullyPipeline Failed",
                $format("name = %s", dbgConf.name, ", previousBeatTime=", fshow(previousBeatTime), ", curTime=", fshow(curTime), ", deltaTime=", fshow(deltaTime), ", allowedDelta=", fshow(allowedDelta))
            );
            // $display("checkFullyPipeline name = %s", name, ", previousBeatTime=", fshow(previousBeatTime), ", curTime=", fshow(curTime), ", deltaTime=", fshow(deltaTime), ", allowedDelta=", fshow(allowedDelta));
        `endif
    endaction
endfunction

module mkFIFOFWithFullAssert#(DebugConf dbgConf)(FIFOF#(t)) provisos (Bits#(t, sz_t));
    let inner <- mkFIFOF;
    rule assertFull if (dbgConf.enableDebug);
        if (!inner.notFull) begin
            immAssertForFpCheck(
                False,
                "checkFullyPipeline Failed, this queue should not full",
                $format("name = %s", dbgConf.name)
            );
        end
    endrule
    return inner;
endmodule

module mkLFIFOFWithFullAssert#(DebugConf dbgConf)(FIFOF#(t)) provisos (Bits#(t, sz_t));
    let inner <- mkLFIFOF;
    rule assertFull if (dbgConf.enableDebug);
        if (!inner.notFull) begin
            immAssertForFpCheck(
                False,
                "checkFullyPipeline Failed, this queue should not full",
                $format("name = %s", dbgConf.name)
            );
        end
    endrule
    return inner;
endmodule

module mkSizedFIFOFWithFullAssert#(Integer depth, DebugConf dbgConf)(FIFOF#(t)) provisos (Bits#(t, sz_t));
    let inner <- mkSizedFIFOF(depth);
    rule assertFull if (dbgConf.enableDebug);
        if (!inner.notFull) begin
            immAssertForFpCheck(
                False,
                "checkFullyPipeline Failed, this queue should not full",
                $format("name = %s", dbgConf.name)
            );
        end
    endrule
    return inner;
endmodule


interface StreamFullyPipelineChecker;
    method ActionValue#(Bool) putStreamBeatInfo(Bool isFirst, Bool isLast);
endinterface

module mkStreamFullyPipelineChecker#(DebugConf dbgConf)(StreamFullyPipelineChecker);
    Reg#(UInt#(16)) lastBeatTimeReg <- mkRegU;
    Reg#(UInt#(16)) curBeatCounterReg <- mkReg(0);

    rule freeRunningCounter;
        curBeatCounterReg <= curBeatCounterReg + 1;
    endrule

    method ActionValue#(Bool) putStreamBeatInfo(Bool isFirst, Bool isLast);
        let ret = True;
        if (dbgConf.enableDebug) begin
            lastBeatTimeReg <= curBeatCounterReg;
            if (isFirst && !isLast) begin // for first beat
                // nothing to do for first beat
            end
            else if ((!isFirst && isLast) || (!isFirst && !isLast)) begin  // for middle and last beat
                if (curBeatCounterReg - lastBeatTimeReg != 1) begin
                    immAssertForFpCheck(
                        False,
                        "DataStream checkFullyPipeline Failed",
                        $format("name = %s", dbgConf.name, ", lastBeatCnt=", fshow(lastBeatTimeReg), ", curBeatCnt=", fshow(curBeatCounterReg), ", delta=", fshow(curBeatCounterReg - lastBeatTimeReg))
                    );
                    ret = False;
                end
                
            end
            else begin  // for only beat
                // nothing to do, only beat doesn't need to check.
            end
        end
        return ret;

    endmethod
endmodule


typeclass ConnectableWithFullyPipelineCheck #(type a, type b)
    dependencies (a determines b, b determines a);
    module mkConnectionFpCheck#(a x1, b x2, DebugConf dbgConf) (Empty);
endtypeclass