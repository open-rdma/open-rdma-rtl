// RxPacketBuffer 是接收端的包缓冲模块，负责把 FTile 输出的 beat 流组装成完整帧、缓存到多槽位 payload 存储里，并向上层提供帧输出、负载读响应、槽位释放和错误上报接口。整体分三层：工具函数 → 单通道缓冲模块 → 4 通道顶层封装。

package RxPacketBuffer;
import Vector::*;
import FIFOF::*;
import RegFile::*;  // RegFile#(addr, data) 表示一个寄存器文件，通常用于较大容量的存储，支持按地址读写
import CommonTypes::*;
import RxTypes::*;

Integer rxBufferQueueDepth = 4;
Integer rxBufferReleaseQueueDepth = 8;
Bit#(12) rxBufferLastAddress = fromInteger(
    valueOf(RxPayloadSlots) * valueOf(RxFrameBeats) - 1);
Integer rxBufferMaxFrameBytes = 4138;
Bit#(8) rxHeaderWord0Index = 0;
Bit#(8) rxHeaderWord1Index = 1;
Bit#(8) rxHeaderWord2Index = 2;

// 地址计算函数：根据槽位号 slot 和槽内字偏移 wordIndex 计算 payload 存储的物理地址。把“逻辑上的 slot + index”映射到 RegFile 的线性地址空间。
function Bit#(12) rxBufferAddress(RxPayloadSlot slot, Bit#(8) wordIndex);   // 组合逻辑：12位地址可寻址4096个字；slot代表接收负载的槽位编号；wordIndex代表槽位内的字偏移，8bit范围为0~255
    Bit#(12) base = zeroExtend(slot) * fromInteger(valueOf(RxFrameBeats)); // 每个 slot 使用 RxFrameBeats 个 word
    return base + zeroExtend(wordIndex);    // addr = slot base + word offset
endfunction
// wordIndex 使用槽内 word 索引类型，slot 数与每槽容量均由 RxTypes 的公共参数决定。

// 空闲槽位查找函数：在 16 位占用位图中找到编号最小的空闲槽位。为 assemble 规则提供“新帧该写到哪个槽”的决策。
function Tuple2#(Bool, RxPayloadSlot) rxFindFreeSlot(Bit#(RxPayloadSlots) occupied);    // 组合逻辑：在 16 位的槽位占用位图中查找一个空闲槽位：输入的 occupied 代表每一个槽位是否被占用(可理解为one-hot码)，输出(是否已找到，槽位号)
    Bool found = False; // 默认没找到
    RxPayloadSlot slot = 0; // 默认槽位号为 0
    // The loop below is statically unrolled and keeps the lowest free slot.
    for (Integer i = 0; i < valueOf(RxPayloadSlots); i = i + 1) begin
        if (!found && occupied[i] == 0) begin
            found = True;
            slot = fromInteger(i);
        end
    end
    return tuple2(found, slot); // 循环没有 break，每次找到空闲都会覆盖 slot。因此循环结束后 slot 保存的是最后一次找到的空闲位，即 i 最小的那个空闲位
endfunction

// 该模块直接对接FTile的输出，一个通道应该只有256bit，因此该部分的输入接口的所有数据信息应该全部压到256bit内
interface RxPortBufferIfc;
    interface PipeIn#(RxWireBeat) wireIn;   // 带有 data、be、sof、eof 的接收数据流输入接口
    interface PipeOut#(RxBufferedFrame) frameOut;   // 带有 tag、header0、header1、header2、bytes、beats 的组装好的接收帧输出接口
    interface PipeIn#(RxPayloadReadRequest) readRequest;    // 接收读负载请求：带有 tag、wordIndex 的接收负载读取请求输入接口
    interface PipeOut#(RxPayloadReadResponse) readResponse; // 返回负载数据：带有 tag、wordIndex、low、high、valid 的接收负载读取响应输出接口
    interface PipeIn#(RxBufferRelease) releaseIn;   // 接收缓冲区槽位释放信号：带有 tag 的接收负载释放请求输入接口
    interface PipeOut#(RxError) errorOut;   // 输出错误信息：带有 error 的接收错误输出接口
endinterface

// 槽位会一直保持占用，直到最终的解析器/RQ/DMA 消费者释放其标签。
module mkRxPortBuffer#(RxLaneId lane)(RxPortBufferIfc); // lane：RxlaneId 类型，表示这是第几条接收通道(共4条)；返回 RxPortBufferIfc 接口
    // 按接口定义输入输出队列
    FIFOF#(RxWireBeat) inQ <- mkSizedFIFOF(rxBufferQueueDepth);
    FIFOF#(RxBufferedFrame) frameQ <- mkSizedFIFOF(rxBufferQueueDepth);
    FIFOF#(RxPayloadReadRequest) readQ <- mkSizedFIFOF(rxBufferQueueDepth);
    FIFOF#(RxPayloadReadResponse) readResponseQ <- mkSizedFIFOF(rxBufferQueueDepth);
    FIFOF#(RxBufferRelease) releaseQ <- mkSizedFIFOF(rxBufferReleaseQueueDepth);
    FIFOF#(RxError) errorQ <- mkSizedFIFOF(rxBufferReleaseQueueDepth);

    RegFile#(Bit#(12), Bit#(256)) payload <- mkRegFile(0, rxBufferLastAddress);    // 负载存储的最后地址由槽位数和每槽 word 数派生
    Reg#(Bit#(RxPayloadSlots)) occupied <- mkReg(0);    // 16位位图，表示对应槽位是否被占用
    Vector#(RxPayloadSlots, Reg#(RxPayloadGeneration)) generations <- replicateM(mkReg(0)); // 每个槽位一个 generations 计数器。释放后自增，用于区分同一槽位在不同生命周期的 tag，防止旧的 tag 误用
    Vector#(RxPayloadSlots, Reg#(Bit#(8))) slotBeats <- replicateM(mkReg(0));

    // 组帧：保存“当前正在组装的帧”的状态。让 assemble 规则跨周期地累积帧信息。
    Reg#(Bool) active <- mkReg(False);
    Reg#(Bool) frameValid <- mkReg(True);
    Reg#(RxPayloadSlot) currentSlot <- mkReg(0);
    Reg#(RxPayloadGeneration) currentGeneration <- mkReg(0);
    Reg#(Bit#(8)) wordIndex <- mkReg(0);
    Reg#(Bit#(14)) byteCount <- mkReg(0);
    Reg#(Bit#(256)) header0 <- mkReg(0);
    Reg#(Bit#(256)) header1 <- mkReg(0);
    Reg#(Bit#(256)) header2 <- mkReg(0);

    (* descending_urgency = "releaseSlot, serveRead, assemble" *)   // 显式指定 rule 优先级
    // 释放槽位
    rule releaseSlot;
        let rel = releaseQ.first;   // 从 releaseQ 中取出第一个元素
        releaseQ.deq;   // 出队
        let tag = rel.tag;
        Bool validTag = tag.lane == lane && occupied[tag.slot] == 1 
            && generations[tag.slot] == tag.generation; // 检查 tag 是否有效：lane 匹配、槽位被占用、generation 匹配
        if (validTag) begin // 如果合法
            Bit#(16) nextOccupied = occupied;
            nextOccupied[tag.slot] = 0; // 清零，释放槽位
            occupied <= nextOccupied;
            generations[tag.slot] <= generations[tag.slot] + 1; // generations 计数器+1，标记新一代开始
        end
        else begin
            errorQ.enq(RxError{qpn:0, psn:0, code:RX_BUFFER_BAD_TAG});  // 不合法向 errorQ 输出错误信息
        end
    endrule

    // 组装帧：每周期从 inQ 取 beat，组装成帧，写入 payload，维护占用和 generation。
    rule assemble;
        // 取数据与找空闲槽位
        let beat = inQ.first;   // 读取输入队列 inQ 的队首元素，绑定到 beat，但不出队。
        let free = rxFindFreeSlot(occupied);    // 调用函数 rxFindFreeSlot，根据当前槽位占用情况 occupied 查找一个空闲槽位，返回一个元组。
        Bool haveFree = tpl_1(free);    // 取元组的第一个元素，类型为 Bool，表示是否存在空闲槽位。
        RxPayloadSlot freeSlot = tpl_2(free);   // 取元组的第二个元素，类型为 RxPayloadSlot，表示空闲槽位的编号。
        Bool starts = beat.sof == 1;    // 判断当前 beat 是否为帧起始
        Bool canConsume = active || !starts || haveFree;    // 如果正在组帧，或收到的不是 SOF，或者有空闲槽位，就可以消费这个 beat。否则（不在组帧、收到 SOF、且无空闲槽位）不能消费，需要等待。

        // 消费与错误处理
        if (canConsume) begin
            inQ.deq;    // 能消费就出队
            if (!active && !starts) begin
                errorQ.enq(RxError{qpn:0, psn:0, code:RX_BAD_FRAME});   // 如果不在组帧且收到的不是 SOF，说明是孤儿 beat，报 RX_BAD_FRAME
            end
            else begin  // 否则进入正常处理
                // 计算槽位、generation、索引
                Bool abandoned = starts && active;
                RxPayloadSlot slot = starts ? (active ? currentSlot : freeSlot) : currentSlot;
                RxPayloadGeneration generation = starts
                    ? (active ? generations[slot] + 1 : generations[slot])
                    : currentGeneration;
                Bit#(8) index = starts ? 0 : wordIndex;
                // 计算有效字节与合法性
                Bit#(6) validBytes = pack(countOnes(beat.be));
                Bit#(14) total = (starts ? 0 : byteCount) + zeroExtend(validBytes);
                Bool validBeat = beat.be != 0 && rxPrefixBe32(beat.be)
                    && (beat.eof == 1 || beat.be == '1)
                    && index < fromInteger(valueOf(RxFrameBeats))
                    && total <= fromInteger(rxBufferMaxFrameBytes);
                Bool validNow = (starts ? True : frameValid) && validBeat;
                // 头部保存
                Bit#(256) h0 = starts ? 0 : header0;
                Bit#(256) h1 = starts ? 0 : header1;
                Bit#(256) h2 = starts ? 0 : header2;
                if (index == rxHeaderWord0Index) h0 = beat.data;
                if (index == rxHeaderWord1Index) h1 = beat.data;
                if (index == rxHeaderWord2Index) h2 = beat.data;
                // 写入负载存储
                if (index < fromInteger(valueOf(RxFrameBeats)))
                    payload.upd(rxBufferAddress(slot, index), beat.data);

                // 更新占用与 generation
                Bit#(RxPayloadSlots) nextOccupied = occupied;
                Bool writeGeneration = starts;
                RxPayloadGeneration nextGeneration = generation;
                if (starts)
                    nextOccupied[slot] = 1;

                // 处理 EOF
                if (beat.eof == 1) begin
                    if (validNow) begin
                        Bit#(8) beats = index + 1;
                        slotBeats[slot] <= beats;
                        frameQ.enq(RxBufferedFrame{tag:RxPayloadTag{lane:lane,
                            slot:slot, generation:generation}, header0:h0,
                            header1:h1, header2:h2, bytes:truncate(total), beats:beats});
                    end
                    else begin
                        nextOccupied[slot] = 0;
                        writeGeneration = True;
                        nextGeneration = generation + 1;
                    end
                    if (abandoned || !validNow)
                        errorQ.enq(RxError{qpn:0, psn:0, code:RX_BAD_FRAME});
                    active <= False;
                    frameValid <= True;
                    wordIndex <= 0;
                    byteCount <= 0;
                    header0 <= 0;
                    header1 <= 0;
                    header2 <= 0;
                end
                // 处理非 EOF
                else begin
                    if (abandoned)
                        errorQ.enq(RxError{qpn:0, psn:0, code:RX_BAD_FRAME});
                    active <= True;
                    frameValid <= validNow;
                    currentSlot <= slot;
                    currentGeneration <= generation;
                    wordIndex <= index + 1;
                    byteCount <= total;
                    header0 <= h0;
                    header1 <= h1;
                    header2 <= h2;
                end
                if (writeGeneration)
                    generations[slot] <= nextGeneration;
                occupied <= nextOccupied;
            end
        end
    endrule

    // 响应读请求：处理上层对 payload 的读请求
    rule serveRead;
        let request = readQ.first;
        readQ.deq;
        let tag = request.tag;
        Bool validTag = tag.lane == lane && occupied[tag.slot] == 1
            && generations[tag.slot] == tag.generation
            && request.wordIndex < slotBeats[tag.slot];
        Bit#(8) safeIndex = validTag ? request.wordIndex : 0;
        Bit#(256) low = payload.sub(rxBufferAddress(tag.slot, safeIndex));
        Bit#(256) high = 0;
        if (validTag && request.wordIndex + 1 < slotBeats[tag.slot])
            high = payload.sub(rxBufferAddress(tag.slot, safeIndex + 1));
        readResponseQ.enq(RxPayloadReadResponse{tag:tag,
            wordIndex:request.wordIndex, low:validTag ? low : 0,
            high:high, valid:validTag});
        if (!validTag)
            errorQ.enq(RxError{qpn:0, psn:0, code:RX_BUFFER_BAD_TAG});
    endrule

    // 接口绑定：把内部 FIFO 包装成对外接口。
    interface wireIn = toPipeIn(inQ);
    interface frameOut = toPipeOut(frameQ);
    interface readRequest = toPipeIn(readQ);
    interface readResponse = toPipeOut(readResponseQ);
    interface releaseIn = toPipeIn(releaseQ);
    interface errorOut = toPipeOut(errorQ);
endmodule

// 4个通道的接收缓冲区的顶层封装，直接对接FTile的输出
interface RxPacketBufferIfc;
    interface Vector#(RxLaneCount, PipeIn#(RxWireBeat)) ports;
    interface Vector#(RxLaneCount, PipeOut#(RxBufferedFrame)) frames;
    interface Vector#(RxLaneCount, PipeIn#(RxPayloadReadRequest)) readRequests;
    interface Vector#(RxLaneCount, PipeOut#(RxPayloadReadResponse)) readResponses;
    interface Vector#(RxLaneCount, PipeIn#(RxBufferRelease)) releases;
    interface Vector#(RxLaneCount, PipeOut#(RxError)) errors;
endinterface

// 连线
module mkRxPacketBuffer(RxPacketBufferIfc);
    Vector#(RxLaneCount, RxPortBufferIfc) lanes;
    Vector#(RxLaneCount, PipeIn#(RxWireBeat)) inputs;
    Vector#(RxLaneCount, PipeOut#(RxBufferedFrame)) outputs;
    Vector#(RxLaneCount, PipeIn#(RxPayloadReadRequest)) readInputs;
    Vector#(RxLaneCount, PipeOut#(RxPayloadReadResponse)) readOutputs;
    Vector#(RxLaneCount, PipeIn#(RxBufferRelease)) releaseInputs;
    Vector#(RxLaneCount, PipeOut#(RxError)) errorOutputs;
    for (Integer i = 0; i < valueOf(RxLaneCount); i = i + 1) begin
        lanes[i] <- mkRxPortBuffer(fromInteger(i));
        inputs[i] = lanes[i].wireIn;
        outputs[i] = lanes[i].frameOut;
        readInputs[i] = lanes[i].readRequest;
        readOutputs[i] = lanes[i].readResponse;
        releaseInputs[i] = lanes[i].releaseIn;
        errorOutputs[i] = lanes[i].errorOut;
    end
    interface ports = inputs;
    interface frames = outputs;
    interface readRequests = readInputs;
    interface readResponses = readOutputs;
    interface releases = releaseInputs;
    interface errors = errorOutputs;
endmodule
endpackage
