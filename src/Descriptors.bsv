import Reserved :: *;

import RdmaHeaders :: *;
import BasicDataTypes :: *;
import EthernetTypes :: *;


typedef enum {
    CmdQueueOpcodeUpdateMrTable = 'h0,
    CmdQueueOpcodeUpdatePGT = 'h1,
    CmdQueueOpcodeQpManagement = 'h2,
    CmdQueueOpcodeSetNetworkParam = 'h3,
    CmdQueueOpcodeSetRawPacketReceiveMeta = 'h4,
    CmdQueueOpcodeUpdateErrorPsnRecoverPoint = 'h5
} CommandQueueOpcode deriving(Bits, Eq);

typedef struct {
    Bool                    valid;          //  1  bits
    Bool                    hasNextFrag;    //  1  bits
    ReservedZero#(5)        reserved0;      //  5  bits
    Bool                    isExtendOpcode; //  1  bits  Reserved for extension. For MetaReport queue, if this is false, opcode is equal to RDMA's opcode, otherwise, the opcode has different meaning.
    Bit#(8)                 opCode;         //  8  bits
} RingbufDescCommonHead deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;     // 16 bits
    MSN                         msn;              // 16 bits

    Length                      totalLen;         // 32 bits
    RKEY                        rkey;             // 32 bits
    IpAddr                      dqpIP;            // 32 bits
    ADDR                        raddr;            // 64 bits

    PSN                         psn;              // 24 bits
    TypeQP                      qpType;           // 4  bits
    ReservedZero#(4)            reserved0;        // 4  bits
    QPN                         dqpn;             // 24 bits
    WorkReqSendFlag             flags;            // 5  bits
    ReservedZero#(3)            reserved1;        // 3  bits
} SendQueueReqDescSeg0 deriving(Bits, FShow);

typedef struct {
   RingbufDescCommonHead      commonHeader;      // 16 bits
   PMTU                       pmtu;              // 3 bits
   Bool                       isFirst;           // 1 bits
   Bool                       isLast;            // 1 bits
   Bool                       isRetry;           // 1 bits
   Bool                       enableEcn;         // 1 bits
   ReservedZero#(1)           reserved0;         // 1 bits

   Bit#(8)                    sqpnLow8Bits;      // 8 bits
   IMM                        imm;               // 32 bits
   EthMacAddr                 macAddr;           // 48 bits
   Bit#(16)                   sqpnHigh16Bits;    // 16 bits

   LKEY                       lkey;              // 32 bits
   Length                     len;               // 32 bits
   ADDR                       laddr;             // 64 bits
} SendQueueReqDescSeg1 deriving(Bits, FShow);

typedef struct {
    ReservedZero#(7)        reserved0;      //  7  bits
    Bool                    isSuccess;      //  1  bits
    Bit#(8)                 userData;       //  8  bits
} RingbufDescCmdQueueCommonHead deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    ReservedZero#(32)               reserved0;              // 32  bits
    ReservedZero#(64)               reserved1;              // 64  bits
    ReservedZero#(64)               reserved2;              // 64  bits
    ReservedZero#(64)               reserved3;              // 64  bits
} CmdQueueRespDescOnlyCommonHeader deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    ReservedZero#(32)               reserved0;              // 32  bits
    Bit#(64)                        mrBaseVA;
    Bit#(32)                        mrLength;
    Bit#(32)                        mrKey;
    ReservedZero#(32)               reserved1;              // 32  bits
    Bit#(8)                         accFlags;
    Bit#(17)                        pgtOffset;
    ReservedZero#(7)                reserved2;
} CmdQueueReqDescUpdateMrTable deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    ReservedZero#(32)               reserved0;              // 32  bits
    Bit#(64)                        dmaAddr;
    Bit#(32)                        startIndex;
    Bit#(32)                        zeroBasedEntryCount;
    ReservedZero#(64)               reserved1;
} CmdQueueReqDescUpdatePGT deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    IpAddr                          peerIpAddr;             // 32  bits
    Bool                            isValid;                // 1   bit  // when destory a qp and reuse it, driver must send a desc with this field set to True. this will clear all states of this QP on hardware.
    Bool                            isError;                // 1   bit
    ReservedZero#(6)                reserved0;              // 6   bits
    QPN                             qpn;                    // 24  bits
    ReservedZero#(32)               reserved1;              // 32  bits
    QPN                             peerQPN;                // 24  bits
    FlagsType#(MemAccessTypeFlag)   rqAccessFlags;          // 8   bits
    TypeQP                          qpType;                 // 4   bits
    ReservedZero#(4)                reserved2;              // 4   bits
    PMTU                            pmtu;                   // 3   bits
    ReservedZero#(5)                reserved3;              // 5   bits

    ReservedZero#(16)               reserved4;              // 16  bits
    UdpPort                         localUdpPort;           // 16  bits
    EthMacAddr                      peerMacAddr;            // 48  bits
} CmdQueueReqDescQpManagement deriving(Bits, FShow);

typedef CmdQueueReqDescQpManagement CmdQueueRespDescQpManagement;

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    ReservedZero#(32)               reserved0;              // 32  bits
    IpGateWay                       gateWay;                // 32  bits
    IpNetMask                       netMask;                // 32  bits
    IpAddr                          ipAddr;                 // 32  bits
    ReservedZero#(32)               reserved1;              // 32  bits
    EthMacAddr                      macAddr;                // 48  bits
    ReservedZero#(16)               reserved2;              // 16  bits
} CmdQueueReqDescSetNetworkParam deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead           commonHeader;           // 16  bits
    RingbufDescCmdQueueCommonHead   cmdQueueCommonHeader;   // 16  bits
    ReservedZero#(32)               reserved0;              // 32  bits
    ADDR                            writeBaseAddr;          // 64  bits
    ReservedZero#(64)               reserved1;              // 64  bits
    ReservedZero#(64)               reserved2;              // 64  bits
} CmdQueueReqDescSetRawPacketReceiveMeta deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;     // 16 bits
    MSN                         msn;              // 16 bits

    PSN                         psn;              // 24 bits
    Bool                        ecnMarked;        // 1  bits
    Bool                        solicited;        // 1  bits
    Bool                        ackReq;           // 1  bits
    Bool                        isRetry;          // 1  bits
    ReservedZero#(4)            reserved0;        // 4  bits

    QPN                         dqpn;             // 24 bits
    ReservedZero#(8)            reserved1;        // 8  bits

    Length                      totalLen;         // 32 bits
    ADDR                        raddr;            // 64 bits
    RKEY                        rkey;             // 32 bits
    ImmDt                       immData;          // 32 bits
} MetaReportQueuePacketBasicInfoDesc deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;     // 16 bits
    ReservedZero#(16)           reserved0;        // 16 bits

    Length                      totalLen;         // 32 bits
    ADDR                        laddr;            // 64 bits
    LKEY                        lkey;             // 32 bits
    ReservedZero#(32)           reserved1;        // 32 bits
    ReservedZero#(64)           reserved2;        // 64 bits
} MetaReportQueueReadReqExtendInfoDesc deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;       // 16 bits
    ReservedZero#(4)            reserved0;          // 4 Bits
    Bool                        isSendByLocalHw;    // 1 Bit  indicate whether sent by local hardware. if True, means this ack is generated by local Hw, and the same reported content will also be sent to remote peer. if false, it means the reported content is reveiced from remote peer.
    Bool                        isSendByDriver;     // 1 Bit  indicate whether sent by driver, since software doesn't known the newest ACK's MSN on hardware. When ack is send by software, MSN is unused.
    Bool                        isWindowSlided;     // 1 Bit
    Bool                        isPacketLost;       // 1 Bit
    ReservedZero#(8)            reserved1;          // 8 Bits

    PSN                         psnBeforeSlide;     // 24 bits
    ReservedZero#(8)            reserved2;          // 8 Bits

    PSN                         psnNow;             // 24 bits
    QPN                         qpn;                // 24 bits Note: this field's meaning is depend on isSendByLocalHw flag below. if isSendByLocalHw is True, then this field is the QPN of local QP. if isSendByLocalHw is Flase, then this field comes from ACK packet's BTH header, so the QPN is ACK packet's receive side's QPN.
    MSN                         msn;                // 16 bits only valid when it's received from remote, if it is generated by local, then it's meaning less.

    AckBitmap                   nowBitmap;          // 128bits
} MetaReportQueueAckDesc deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;       // 16 bits
    ReservedZero#(16)           reserved0;          // 16 Bits
    ReservedZero#(32)           reserved1;          // 32 Bits
    ReservedZero#(64)           reserved2;          // 64 Bits
    AckBitmap                   preBitmap;          // 128bits
} MetaReportQueueAckExtraDesc deriving(Bits, FShow);

typedef struct {
    RingbufDescCommonHead       commonHeader;       // 16 bits
    ReservedZero#(16)           reserved0;          // 16 Bits
    Length                      len;                // 32 Bits
    ADDR                        addr;               // 64 Bits must ensure addr and length not across page boundary.
    ReservedZero#(64)           reserved1;          // 64 Bits
    ReservedZero#(64)           reserved2;          // 64 Bits
} SimpleNicTxQueueDesc deriving(Bits, FShow);

typedef 0 SIMPLE_NIC_RX_QUEUE_DESC_OPCODE_NEW_PACKET;

typedef struct {
    RingbufDescCommonHead       commonHeader;       // 16 bits
    ReservedZero#(16)           reserved0;          // 16 Bits
    Length                      len;                // 32 Bits
    Dword                       slotIdx;            // 32 Bits
    ReservedZero#(32)           reserved1;          // 32 Bits
    ReservedZero#(64)           reserved2;          // 64 Bits
    ReservedZero#(64)           reserved3;          // 64 Bits
} SimpleNicRxQueueDesc deriving(Bits, FShow);
