import os
import shutil
import sys
from collections import deque, OrderedDict
from abc import ABC
import logging
import math
from .hw_consts import MEM_REGION_PAGE_SIZE, LR_KEY_IDX_PART_WIDTH, LR_KEY_KEY_PART_WIDTH, QPN_IDX_PART_WIDTH, QPN_KEY_PART_WIDTH
import asyncio
import find_libpython
import cocotb_tools.config

import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, ReadWrite, ReadOnly, Edge, NextTimeStep, NullTrigger, Event
from cocotb.types import LogicArray
from cocotb.queue import Queue
import cocotb.triggers


def gen_rtl_file_list(top_paths):
    fileset = set()
    filelist = []
    for top_path in top_paths.split(":"):
        for (dirpath, dirnames, filenames) in os.walk(top_path):
            for filename in filenames:
                if filename.endswith(".v") or filename.endswith(".sv"):
                    if filename not in fileset:
                        filelist.append(os.path.join(dirpath, filename))
                        fileset.add(filename)
    return filelist


def copy_mem_file_to_sim_build_dir(src_dirs, target_dir):
    for top_path in src_dirs.split(":"):
        for (dirpath, dirnames, filenames) in os.walk(top_path):
            for filename in filenames:
                if filename.endswith(".bin") or filename.endswith(".hex"):
                    shutil.copyfile(os.path.join(
                        dirpath, filename), os.path.join(target_dir, filename))


def cocotb_extra_env():
    """Build runtime env vars required by cocotb 2.x/dev custom simulator flows."""
    env = {
        "PYGPI_PYTHON_BIN": sys.executable,
    }

    libpython_path = find_libpython.find_libpython()
    if libpython_path:
        env["LIBPYTHON_LOC"] = libpython_path
        env["GPI_USERS"] = ";".join(
            [libpython_path, cocotb_tools.config.pygpi_entry_point()]
        )

    return env


class BluespecValueMethod:
    def __init__(self, dut, signal_base_name, clk, ready_prefix="RDY_"):

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)

        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name

        ready_signal_name = ready_prefix + signal_base_name
        return_value_signal_name = signal_base_name

        self.ready_signal = getattr(dut, ready_signal_name)
        self.return_value_signal = getattr(dut, return_value_signal_name)

    async def __call__(self, **kwargs):
        self.log.debug(
            f"11111111111111={kwargs}  retval={self.return_value_signal.value}   signal={self.signal_base_name}")

        await ReadWrite()
        self.log.debug(
            f"2222222222={kwargs}  retval={self.return_value_signal.value}   signal={self.signal_base_name}")
        while not self.ready_signal.value:
            self.log.debug(
                f"wait 11111={kwargs}  retval={self.return_value_signal.value}   signal={self.signal_base_name}")
            await RisingEdge(self.clk)
            self.log.debug(
                f"wait 2222={kwargs}  retval={self.return_value_signal.value}   signal={self.signal_base_name}")
            await ReadWrite()
        self.log.debug(
            f"333333333={kwargs}  retval={self.return_value_signal.value}   signal={self.signal_base_name}")

        for (arg_name, arg_val) in kwargs.items():
            getattr(self.dut, self.signal_base_name +
                    f"_{arg_name}").value = arg_val

        self.log.debug(
            f"444444={kwargs}  retval={self.return_value_signal.value} signal={self.signal_base_name}")
        # await ReadWrite()
        self.log.debug(
            f"555555={kwargs}  retval={self.return_value_signal.value} signal={self.signal_base_name}")

        async def _tttt(started: Event):
            started.set()
            await NextTimeStep()
            self.log.debug(
                f"6666666={kwargs}  retval={self.return_value_signal.value} signal={self.signal_base_name}")
        # await cocotb.start(_tttt())
        task_started = Event()
        task = cocotb.start_soon(_tttt(task_started))
        await task_started.wait()

        assert self.ready_signal.value
        return self.return_value_signal.value


class BluespecActionValueMethod:
    def __init__(self, dut, signal_base_name, clk, ready_prefix="RDY_", enable_prefix="EN_"):

        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)

        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name

        ready_signal_name = ready_prefix + signal_base_name
        enable_signal_name = enable_prefix + signal_base_name
        return_value_signal_name = signal_base_name

        self.ready_signal = getattr(dut, ready_signal_name)
        self.enable_signal = getattr(dut, enable_signal_name)
        self.return_value_signal = getattr(dut, return_value_signal_name, None)

        self.enable_signal.setimmediatevalue(0)

        self.next_beat_values = {}

        # self.ready_signal_new = self.ready_signal.value
        # self.enable_signal_new = self.enable_signal.value
        # self.return_value_signal_new = None if self.return_value_signal is None else self.return_value_signal.value

        # self._call_finished_evt = cocotb.triggers.Event()
        # self.has_pending_task = False
        # cocotb.start_soon(self._handshake_task())

    # async def _handshake_task(self):
    #     while True:
    #         await RisingEdge(self.clk)

    #         self.ready_signal.value = self.ready_signal_new
    #         self.enable_signal.value = self.enable_signal_new
    #         self.return_value_signal.value = self.return_value_signal_new

    #         if self.has_pending_task:
    #             self.enable_signal_new = 1
    #             if self.ready_signal.value == 1:  # handshake success

    async def __call__(self, **kwargs):
        async def _deassert_en_signal(event: Event):
            event.set()
            self.log.debug(
                f"aaaaaaaa={kwargs}  signal={self.signal_base_name}")
            await RisingEdge(self.clk)
            self.log.debug(
                f"bbbbbbbb={kwargs}  signal={self.signal_base_name}")
            self.enable_signal.value = 0

            self.next_beat_values.clear()

        self.log.debug(
            f"11111111111111={kwargs}  signal={self.signal_base_name}")
        await ReadWrite()
        self.log.debug(f"2222222222={kwargs}  signal={self.signal_base_name}")
        while not self.ready_signal.value:
            await RisingEdge(self.clk)
            await ReadWrite()
        self.log.debug(f"333333333={kwargs}  signal={self.signal_base_name}")

        self.enable_signal.value = 1
        assert len(self.next_beat_values) == 0
        for (arg_name, arg_val) in kwargs.items():
            getattr(self.dut, self.signal_base_name +
                    f"_{arg_name}").value = arg_val


        # await cocotb.start(_deassert_en_signal())
        # cocotb.start_soon(_deassert_en_signal())
        # await NullTrigger()

        task_started = Event()
        task = cocotb.start_soon(_deassert_en_signal(task_started))
        await task_started.wait()

        self.log.debug(
            f"444444={kwargs}  retval={self.return_value_signal.value if self.return_value_signal is not None else '<NA>'} signal={self.signal_base_name}")
        await ReadWrite()
        self.log.debug(
            f"555555={kwargs}  retval={self.return_value_signal.value if self.return_value_signal is not None else '<NA>'} signal={self.signal_base_name}")

        if self.return_value_signal is not None:
            # but return value should be returned current beat
            return self.return_value_signal.value


class BluespecActionMethod(BluespecActionValueMethod):
    def __init__(self, dut, signal_base_name, clk, ready_prefix="RDY_", enable_prefix="EN_"):
        super().__init__(dut, signal_base_name, clk, ready_prefix, enable_prefix)
        self.return_value_signal = None


class BluespecType(ABC):
    def pack(self) -> int:
        return 0

    def unpack(self, val):
        pass

    def width(self):
        pass


class BluespecBits(BluespecType):
    _width = 0

    def __init__(self, value=None):
        if isinstance(value, BluespecBits):
            self._inner = LogicArray(value.pack(), self._width)
        elif isinstance(value, bytes):
            if len(value) * 8 < self._width:
                value = value.ljust(self._width // 8, b'\0')
            self._inner = LogicArray.from_bytes(value=value, range=self._width, byteorder="little")
        else:
            self._inner = LogicArray(value, self._width)

    def pack(self):
        return self._inner.to_unsigned()

    @classmethod
    def unpack(cls, val):
        return cls(val)

    @classmethod
    def width(cls):
        return cls._width

    def __str__(self):
        return str(hex(self._inner.to_unsigned()))

    def __repr__(self):
        return str(hex(self._inner.to_unsigned()))

    def __call__(self):
        return self.pack()


class BluespecStruct(BluespecType):
    _members_def = OrderedDict()
    _width = -1  # lazy calc

    def __init__(self, *members):
        self.__dict__["_members"] = OrderedDict()

        for ((member_name, member_type), member_inst) in zip(self._members_def.items(), members):
            if isinstance(member_inst, BluespecType):
                assert isinstance(member_inst, member_type)
                self._members[member_name] = member_inst
            else:
                self._members[member_name] = member_type(member_inst)

    def pack(self):
        packed_val = 0
        for member in self._members.values():
            member_packed_val = member.pack()
            packed_val = (packed_val << member.width()) | member_packed_val
        return packed_val

    @classmethod
    def width(cls):
        if cls._width == -1:
            _width = 0
            for member_type in cls._members_def.values():
                _width += member_type.width()
            cls._width = _width

        return cls._width

    def __getattr__(self, name):
        if name in self._members:
            return self._members[name]
        return super().__getattribute__(name)

    def __setattr__(self, name, value):
        if name in self._members:
            self._members[name] = self._members_def[name].unpack(value)
            return
        return super().__setattr__(name, value)

    @classmethod
    def unpack(cls, val):
        args = []
        if isinstance(val, LogicArray):
            val = val.to_unsigned()
        for member_type in reversed(cls._members_def.values()):
            mask = (1 << member_type.width()) - 1
            member_val = val & mask
            args.append(member_type.unpack(member_val))
            val = val >> member_type.width()

        args.reverse()
        ret = cls(*args)
        return ret

    def __repr__(self):
        return f"<{type(self)} {self._members}>"


class BluespecUnionTagNotMatchError(Exception):
    pass


class BluespecTaggedUnion(BluespecType):
    _members_def = OrderedDict()
    _width = -1  # lazy calc

    def __init__(self, tag, value):
        self.__dict__["_members"] = OrderedDict()

        assert type(value) == self._members_def[tag]

        self._tag = tag
        self._value = value
        self._tag_idx = -1

        tag_bit_len = (len(self._members_def)).bit_length()

        for (idx, (tag_name, member_type)) in enumerate(self._members_def.items()):
            self._width = max(self._width, member_type.width())
            if tag_name == tag:
                self._tag_idx = idx
        self._width += tag_bit_len

        self.tag_bits = self._tag_idx << (self._width - tag_bit_len)

    def pack(self):
        return self._value.pack() | self.tag_bits

    @classmethod
    def width(cls):
        if cls._width == -1:
            _width = 0
            for member_type in cls._members_def.values():
                _width = max(_width, member_type.width())
            tag_bit_len = (len(cls._members_def)).bit_length()
            _width += tag_bit_len

            cls._width = _width

        return cls._width

    def get_by_tag(self, tag):
        if tag == self._tag:
            return self._value
        else:
            raise BluespecUnionTagNotMatchError(
                f"inner data tag is {self._tag}")

    def get_by_tag_default(self, tag, default=None):
        if tag == self._tag:
            return self._value
        else:
            return default

    def is_match_tag(self, tag):
        return tag == self._tag

    @classmethod
    def unpack(cls, val):
        payload_width = 0
        for member_type in cls._members_def.values():
            payload_width = max(payload_width, member_type.width())

        tag_bits = val >> payload_width

        tag_name, type_of_payload = list(cls._members_def.items())[tag_bits]

        mask = (1 << type_of_payload.width()) - 1
        member_val = val & mask

        payload = type_of_payload.unpack(member_val)
        return cls(tag_name, payload)

    def __repr__(self):
        return f"<{type(self)} {self._tag}: {self._value}>"


class BluespecBool(BluespecBits):
    _width = 1

    def __call__(self):
        ret = super().__call__()
        return ret == 1


class BluespecVoid(BluespecBits):
    _width = 0


def BluespecMaybe(inner_type):
    class BluespecMaybeInner(BluespecTaggedUnion):
        _members_def = OrderedDict(
            invalid=BluespecVoid,
            valid=inner_type,
        )

        def __repr__(self):
            return f"<BluespecMaybe#({inner_type.__class__}) {self._tag} {self._value}>"
    return BluespecMaybeInner


#####################################################
#####################################################
#####################################################


def get_qpn(qp_index, qp_key):
    return (qp_index << QPN_KEY_PART_WIDTH) | qp_key


class BlueRdmaData256(BluespecBits):
    _width = 256


class BlueRdmaData256ByteNum(BluespecBits):
    _width = 6


class BlueRdmaData256ByteIndex(BluespecBits):
    _width = 5


class BlueRdmaDataStream256(BluespecStruct):
    _members_def = OrderedDict(
        data=BlueRdmaData256,
        byte_num=BlueRdmaData256ByteNum,
        start_byte_index=BlueRdmaData256ByteIndex,
        is_first=BluespecBool,
        is_last=BluespecBool
    )

    def __init__(self, data, byte_num, start_byte_index, is_first, is_last):
        data = BlueRdmaData256(data)
        byte_num = BlueRdmaData256ByteNum(byte_num)
        start_byte_index = BlueRdmaData256ByteIndex(start_byte_index)
        is_first = BluespecBool(is_first)
        is_last = BluespecBool(is_last)
        super().__init__(data, byte_num, start_byte_index, is_first, is_last)

    def __str__(self):
        return (
            f"< BlueRdmaDataStream256 "
            f"data={self.data}, "
            f"byte_num={self.byte_num}, "
            f"start_byte_index={self.start_byte_index}, "
            f"is_first={self.is_first}, "
            f"is_last={self.is_last} >"
        )


class BlueRdmaData512(BluespecBits):
    _width = 512


class BlueRdmaData512ByteNum(BluespecBits):
    _width = 7


class BlueRdmaData512ByteIndex(BluespecBits):
    _width = 6


class BlueRdmaDataStream512(BluespecStruct):
    _members_def = OrderedDict(
        data=BlueRdmaData512,
        byte_num=BlueRdmaData512ByteNum,
        start_byte_index=BlueRdmaData512ByteIndex,
        is_first=BluespecBool,
        is_last=BluespecBool
    )

    def __init__(self, data, byte_num, start_byte_index, is_first, is_last):
        data = BlueRdmaData512(data)
        byte_num = BlueRdmaData512ByteNum(byte_num)
        start_byte_index = BlueRdmaData512ByteIndex(start_byte_index)
        is_first = BluespecBool(is_first)
        is_last = BluespecBool(is_last)
        super().__init__(data, byte_num, start_byte_index, is_first, is_last)

    def __str__(self):
        return (
            f"< BlueRdmaDataStream512 "
            f"data={self.data}, "
            f"byte_num={self.byte_num}, "
            f"start_byte_index={self.start_byte_index}, "
            f"is_first={self.is_first}, "
            f"is_last={self.is_last} >"
        )


class BlueRdmaLength(BluespecBits):
    _width = 32


class BlueRdmaAddr(BluespecBits):
    _width = 64

class BlueRdmaMemAccessType(BluespecBits):
    _width = 2
    MemAccessTypeNormalReadWrite = 0
    MemAccessTypeFetchAdd  = 1
    MemAccessTypeSwap = 2
    MemAccessTypeCAS  = 3


class BlueRdmaAtomicOperand(BluespecBits):
    _width = 64


class BlueRdmaDtldStreamMemAccessMeta(BluespecStruct):
    _members_def = OrderedDict(
        addr=BlueRdmaAddr,
        total_len=BlueRdmaLength,
        accessType=BlueRdmaMemAccessType,
        operand_1=BlueRdmaAtomicOperand,
        operand_2=BlueRdmaAtomicOperand,
        noSnoop=BluespecBool
    )

    def __init__(self, addr, total_len, accessType=BlueRdmaMemAccessType.MemAccessTypeNormalReadWrite, operand_1=0, operand_2=0, noSnoop=False):
        addr = BlueRdmaAddr(addr)
        total_len = BlueRdmaLength(total_len)
        accessType = BlueRdmaMemAccessType(accessType)
        operand_1 = BlueRdmaAtomicOperand(operand_1)
        operand_2 = BlueRdmaAtomicOperand(operand_2)
        noSnoop = BluespecBool(noSnoop)
        super().__init__(addr, total_len, accessType, operand_1, operand_2, noSnoop)

    def __str__(self):
        return (
            f"< BlueRdmaDtldStreamMemAccessMeta "
            f"addr={self.addr}, "
            f"total_len={self.total_len}, "
            f"accessType={self.accessType}, "
            f"operand_1={self.operand_1}, "
            f"operand_2={self.operand_2}, "
            f"noSnoop={self.noSnoop} >"
        )


class BlueRdmaPKEY(BluespecBits):
    _width = 16


class BlueRdmaWorkReqOpCode(BluespecBits):
    _width = 4


class BlueRdmaWorkReqSendFlag(BluespecBits):
    _width = 5


class BlueRdmaTypeQP(BluespecBits):
    _width = 4


class BlueRdmaPSN(BluespecBits):
    _width = 24


class BlueRdmaPMTU(BluespecBits):
    _width = 3


class BlueRdmaIpAddr(BluespecBits):
    _width = 32


class BlueRdmaEthMacAddr(BluespecBits):
    _width = 48


class BlueRdmaLKEY(BluespecBits):
    _width = 32


class BlueRdmaRKEY(BluespecBits):
    _width = 32


class BlueRdmaQPN(BluespecBits):
    _width = 24


def BlueRdmaReservedZero(width):
    class BlueRdmaReservedZeroInner(BluespecBits):
        _width = width
    return BlueRdmaReservedZeroInner


class BlueRdmaWorkQueueElem(BluespecStruct):
    _members_def = OrderedDict(
        pkey=BlueRdmaPKEY,
        opcode=BlueRdmaWorkReqOpCode,
        flags=BlueRdmaWorkReqSendFlag,
        qp_type=BlueRdmaTypeQP,
        psn=BlueRdmaPSN,
        pmtu=BlueRdmaPMTU,
        dqp_ip=BlueRdmaIpAddr,
        mac_addr=BlueRdmaEthMacAddr,
        laddr=BlueRdmaAddr,
        lkey=BlueRdmaLKEY,
        raddr=BlueRdmaAddr,
        rkey=BlueRdmaRKEY,
        len=BlueRdmaLength,
        totalLen=BlueRdmaLength,
        dqpn=BlueRdmaQPN,
        sqpn=BlueRdmaQPN,
        comp=BlueRdmaReservedZero(65),
        swap=BlueRdmaReservedZero(65),
        immDtOrInvRKey=BlueRdmaReservedZero(34),
        srqn=BlueRdmaReservedZero(25),
        qkey=BlueRdmaReservedZero(33),
        is_first=BluespecBool,
        is_last=BluespecBool,
    )

    def __init__(self, pkey, opcode, flags, qp_type, psn, pmtu, dqp_ip,
                 mac_addr, laddr, lkey, raddr, rkey, len, totalLen, dqpn, sqpn, is_first, is_last):
        super().__init__(pkey, opcode, flags, qp_type, psn, pmtu, dqp_ip,
                         mac_addr, laddr, lkey, raddr, rkey, len, totalLen, dqpn, sqpn, 0, 0, 0, 0, 0, is_first, is_last)


class BlueRdmaFourChannelPsnBitmapPreMergeReq(BluespecStruct):
    _members_def = OrderedDict(
        psn=BlueRdmaPSN,
        qpn=BlueRdmaQPN,
    )

    def __init__(self, psn, qpn):
        super().__init__(psn, qpn)


class BlueRdmaOooWindowBitmap(BluespecBits):
    _width = 128


class BlueRdmaPsnMergeWindowBoundary(BluespecBits):
    _width = 20


class BlueRdmaOooWindowBitmapStorageEntryEpoch(BluespecBits):
    _width = 4


class BlueRdmaOooWindowBitmapStorageChannelIdx(BluespecBits):
    _width = 1


class BlueRdmaIndexQP(BluespecBits):
    _width = QPN_IDX_PART_WIDTH


class BlueRdmaBitmapWindowStorageEntry(BluespecStruct):
    _members_def = OrderedDict(
        data=BlueRdmaOooWindowBitmap,
        leftBound=BlueRdmaPsnMergeWindowBoundary,
        epoch=BlueRdmaOooWindowBitmapStorageEntryEpoch,
        channelIdx=BlueRdmaOooWindowBitmapStorageChannelIdx,
    )

    def __init__(self, data, leftBound, epoch, channelIdx):
        super().__init__(data, leftBound, epoch, channelIdx)


class BlueRdmaBitmapWindowStorageUpdateResp(BluespecStruct):
    _members_def = OrderedDict(
        rowAddr=BlueRdmaIndexQP,
        isShiftWindow=BluespecBool,
        isShiftOutOfBoundary=BluespecBool,
        windowShiftedOutData=BlueRdmaOooWindowBitmap,
        oldEntry=BlueRdmaBitmapWindowStorageEntry,
        newEntry=BlueRdmaBitmapWindowStorageEntry
    )

    def __init__(self, rowAddr, isShiftWindow, isShiftOutOfBoundary, windowShiftedOutData, oldEntry, newEntry):
        super().__init__(rowAddr, isShiftWindow, isShiftOutOfBoundary,
                         windowShiftedOutData, oldEntry, newEntry)


BlueRdmaBitmapWindowStorageUpdateRespMaybe = BluespecMaybe(
    BlueRdmaBitmapWindowStorageUpdateResp)


class BluespecPipeOut:
    def __init__(self, dut, signal_base_name, clk, is_zero_width_signal=False):
        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name
        self.is_zero_width_signal = is_zero_width_signal

        self.bsv_not_empty = BluespecValueMethod(
            dut, signal_base_name + "_notEmpty", clk)
        if not is_zero_width_signal:
            self.bsv_first = BluespecValueMethod(
                dut, signal_base_name + "_first", clk)
        self.bsv_deq = BluespecActionMethod(
            dut, signal_base_name + "_deq", clk)

    async def not_empty(self):
        return await self.bsv_not_empty()

    async def deq(self):
        await self.bsv_deq()

    async def first(self):
        if self.is_zero_width_signal:
            return 0
        return await self.bsv_first()


class BluespecPipeIn:
    def __init__(self, dut, signal_base_name, clk):
        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name

        self.bsv_not_full = BluespecValueMethod(
            dut, signal_base_name + "_notFull", clk)
        self.bsv_enq = BluespecActionMethod(
            dut, signal_base_name + "_enq", clk)

    async def not_full(self):
        return await self.bsv_not_full()

    async def enq(self, data):
        await self.bsv_enq(data=data)


class BluespecPipeInNr:
    def __init__(self, dut, signal_base_name, clk):
        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name

        self.bsv_deq_signal_out = BluespecValueMethod(
            dut, signal_base_name + "_deqSignalOut", clk)
        self.bsv_first_in = BluespecActionMethod(
            dut, signal_base_name + "_firstIn", clk)
        self.bsv_not_empty_in = BluespecActionMethod(
            dut, signal_base_name + "_notEmptyIn", clk)

    async def deq_signal_out(self):
        return await self.bsv_deq_signal_out()

    async def first_in(self, data):
        await self.bsv_first_in(dataIn=data)

    async def not_empty_in(self, data):
        await self.bsv_not_empty_in(val=data)


class BluespecPipeInNrWithQueue:
    def __init__(self, dut, signal_base_name, clk):
        self.log = logging.getLogger("cocotb.tb")
        self.log.setLevel(logging.INFO)

        self.dut = dut
        self.clk = clk
        self.signal_base_name = signal_base_name

        self._pipe_in_nr = BluespecPipeInNr(dut, signal_base_name, clk)
        self._queue = deque(maxlen=2)
        self._deq_event = cocotb.triggers.Event()
        cocotb.start_soon(self._forward_task())

    async def _forward_task(self):
        await RisingEdge(self.clk)
        while True:
            deq_signal = await self._pipe_in_nr.deq_signal_out()
            if deq_signal == 1:
                assert len(self._queue) > 0
                self._queue.popleft()
                self._deq_event.set()
                self.log.debug(
                    f"BluespecPipeInNrWithQueue handle deq signal. signal_name={self.signal_base_name}")

            if len(self._queue) > 0:
                ele = self._queue[0]
                await self._pipe_in_nr.first_in(ele)
                await self._pipe_in_nr.not_empty_in(1)

                debug_ds = BlueRdmaDataStream256.unpack(ele)
                self.log.debug(
                    f"BluespecPipeInNrWithQueue forward. signal_name={self.signal_base_name}, ele={debug_ds}")

            else:
                await self._pipe_in_nr.not_empty_in(0)

            await RisingEdge(self.clk)

    async def not_full(self):
        return len(self._queue) != self._queue.maxlen

    async def enq(self, data):
        if len(self._queue) == self._queue.maxlen:
            self._deq_event.clear()
            await self._deq_event.wait()
        self._queue.append(data)
        # self.log.debug(
        #     f"BluespecPipeInNrWithQueue enq. signal_name={self.signal_base_name}, data={data}")


class DeviceRingbufTestHelper:
    def __init__(self, dut, pcie_bfm, mem, start_addr):
        self.dut = dut
        self.pcie_bfm = pcie_bfm
        self.mem = mem
        self.start_addr = start_addr
