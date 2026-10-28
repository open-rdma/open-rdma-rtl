package E2eTypes;

import TxTypes :: *;

// TX tap -> packet tap：WQE 注册响应按 message 顺序交付。
typedef struct {
    TxRequestId requestId;
    Bit#(32)    recordHandle;
} RetxRecordMeta deriving(Bits, Eq, FShow);

// TX tap -> replay store：一个已发送 packet payload beat 的片段。
typedef struct {
    Bit#(32)   replayHandle;
    Bit#(8)    beatIndex;
    Bit#(1024) data;
} RetxReplayWriteHw deriving(Bits, Eq, FShow);

endpackage
