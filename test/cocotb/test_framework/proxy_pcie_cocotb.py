import json
import logging
import queue
import threading
import time

import cocotb.triggers
from cocotbext.axi import Region
from cocotbext.pcie.core.rc import RootComplex

from .tcpConnectionManager import TcpConnectionManager


class PcieDmaRegionProxy(Region):
    def __init__(
        self,
        size=2**64,
        tcp_host="127.0.0.1",
        tcp_port=5000,
        channel_id=0,
        tcp_timeout_s=5.0,
        poll_delay_ns=10,
        *args,
        **kwargs,
    ):
        super().__init__(size=size, *args, **kwargs)
        self.log = logging.getLogger("cocotb.tb")
        self.tcpConnection = TcpConnectionManager("1", tcp_host, tcp_port)
        self.channel_id = channel_id
        self.tcp_timeout_s = tcp_timeout_s
        self.poll_delay_ns = poll_delay_ns

        self._request_count_lock = threading.Lock()
        self._request_count = 0
        self._read_response_queues = {}
        self._read_response_lock = threading.Lock()
        self._send_queue = queue.Queue()
        self._stop_tcp_threads = False

        self._tcp_sender = threading.Thread(
            target=self._tcp_sender_thread,
            name=f"PcieDmaRegionProxySender[{channel_id}]",
            daemon=True,
        )
        self._tcp_receiver = threading.Thread(
            target=self._tcp_receiver_thread,
            name=f"PcieDmaRegionProxyReceiver[{channel_id}]",
            daemon=True,
        )
        self._tcp_sender.start()
        self._tcp_receiver.start()


    def _next_request_id(self):
        with self._request_count_lock:
            request_id = f"req_{self.channel_id}_{self._request_count}"
            self._request_count += 1
        return request_id

    def _send_json_request(self, request):
        if not self.tcpConnection.get_connection(timeout=self.tcp_timeout_s):
            raise TimeoutError("Timed out waiting for TCP connection")

        payload = (json.dumps(request) + "\n").encode("utf-8")
        if not self.tcpConnection.send_data(payload):
            raise ConnectionError(f"Failed to send TCP request: {request}")

    async def _wait_for_read_response(self, response_queue, request_id):
        if self.poll_delay_ns > 0:
            await cocotb.triggers.Timer(self.poll_delay_ns, "ns")

        try:
            response = response_queue.get(timeout=self.tcp_timeout_s)
        except queue.Empty as exc:
            raise TimeoutError(
                f"Timed out waiting for TCP read response: {request_id}"
            ) from exc

        if isinstance(response, Exception):
            raise response

        if not response.get("success", True):
            raise RuntimeError(f"TCP read failed: {response}")

        return bytes(response.get("data", []))

    async def read(self, addr, length, **kwargs):
        if length <= 0:
            return b""

        request_id = self._next_request_id()
        request = {
            "type": "mem_read",
            "channel_id": self.channel_id,
            "address": addr,
            "length": length,
            "start_byte_index": addr & 0x3,
            "is_first": True,
            "is_last": True,
            "request_id": request_id,
        }
        response_queue = queue.Queue()

        with self._read_response_lock:
            self._read_response_queues[request_id] = response_queue

        self._send_queue.put(request)

        try:
            try:
                data = await self._wait_for_read_response(response_queue, request_id)
            except Exception as exc:
                raise AssertionError(
                    f"TCP read request failed: addr=0x{addr:x}, length={length}, "
                    f"request_id={request_id}, error={exc}"
                ) from exc

            assert len(data) == length, (
                f"TCP read length mismatch: addr=0x{addr:x}, request_id={request_id}, "
                f"requested={length}, received={len(data)}"
            )
            return data
        finally:
            with self._read_response_lock:
                self._read_response_queues.pop(request_id, None)

    async def write(self, addr, data, **kwargs):
        if not data:
            return
        request = {
            "type": "mem_write",
            "channel_id": self.channel_id,
            "address": addr,
            "data": list(data),
            "length": len(data),
        }
        self._send_queue.put(request)

    def _tcp_sender_thread(self):
        while not self._stop_tcp_threads:
            try:
                request = self._send_queue.get(timeout=0.1)
            except queue.Empty:
                continue

            try:
                self._send_json_request(request)
            except Exception as exc:
                self.log.error("TCP send error: %s", exc)
                request_id = request.get("request_id")
                if request_id is not None:
                    with self._read_response_lock:
                        response_queue = self._read_response_queues.get(request_id)
                    if response_queue is not None:
                        response_queue.put(exc)

    def _tcp_receiver_thread(self):
        while not self._stop_tcp_threads:
            try:
                response_data = self.tcpConnection.receive_line(timeout=1.0)
                if not response_data:
                    time.sleep(0.001)
                    continue

                line = response_data.decode("utf-8").strip()
                if not line:
                    continue

                response = json.loads(line)
                request_id = response.get("request_id")

                if response.get("type") != "mem_read_response" or request_id is None:
                    self.log.debug("Ignore unexpected TCP response: %s", response)
                    continue

                with self._read_response_lock:
                    response_queue = self._read_response_queues.get(request_id)

                if response_queue is None:
                    self.log.warning("No waiter for TCP read response: %s", response)
                    continue

                response_queue.put(response)
            except json.JSONDecodeError as exc:
                self.log.error("TCP JSON decode error: %s", exc)
            except Exception as exc:
                self.log.error("TCP receive error: %s", exc)
                time.sleep(0.001)

    def close(self):
        self._stop_tcp_threads = True
        self._tcp_sender.join(timeout=1.0)
        self._tcp_receiver.join(timeout=1.0)
        self.tcpConnection.close()


def get_or_create_tcp_dram_backend(
    rc,
    size=2**64,
    tcp_host="127.0.0.1",
    tcp_port=5000,
    channel_id=0,
    tcp_timeout_s=5.0,
):
    backend = getattr(rc, "_tcp_dram_backend", None)
    if backend is None:
        backend = PcieDmaRegionProxy(
            size=size,
            tcp_host=tcp_host,
            tcp_port=tcp_port,
            channel_id=channel_id,
            tcp_timeout_s=tcp_timeout_s,
        )
        rc._tcp_dram_backend = backend
        rc._tcp_dram_backend_owned = True
        rc._tcp_dram_next_offset = 0

    return backend


def register_tcp_dram_region(
    rc,
    size=1 << 25,
    base=None,
    offset=None,
    backend=None,
    tcp_host="127.0.0.1",
    tcp_port=5000,
    channel_id=0,
    tcp_timeout_s=5.0,
):
    if base is None:
        base = getattr(rc, "_tcp_dram_next_base", 0)

    if backend is None:
        backend = get_or_create_tcp_dram_backend(
            rc,
            tcp_host=tcp_host,
            tcp_port=tcp_port,
            channel_id=channel_id,
            tcp_timeout_s=tcp_timeout_s,
        )
    else:
        rc._tcp_dram_backend = backend
        rc._tcp_dram_backend_owned = False

    if offset is None:
        offset = getattr(rc, "_tcp_dram_next_offset", 0)

    region = backend.register_region(rc, base, size, offset)
    rc._tcp_dram_next_base = base + ((size + 0xFFF) & ~0xFFF)
    rc._tcp_dram_next_offset = offset + ((size + 0xFFF) & ~0xFFF)

    return base, region


class TcpRootComplex(RootComplex):
    def __init__(
        self,
        tcp_host="127.0.0.1",
        tcp_port=5000,
        channel_id=0,
        dram_region_size=1 << 25,
        dram_region_base=0,
        dram_region_offset=0,
        tcp_timeout_s=5.0,
        dram_backend=None,
        *args,
        **kwargs,
    ):
        super().__init__(*args, **kwargs)

        self.dram_backend = dram_backend or get_or_create_tcp_dram_backend(
            self,
            tcp_host=tcp_host,
            tcp_port=tcp_port,
            channel_id=channel_id,
            tcp_timeout_s=tcp_timeout_s,
        )
        if dram_backend is not None:
            self._tcp_dram_backend_owned = False

        self.dram_region_base, self.dram_region = register_tcp_dram_region(
            self,
            size=dram_region_size,
            base=dram_region_base,
            offset=dram_region_offset,
            backend=self.dram_backend,
            tcp_host=tcp_host,
            tcp_port=tcp_port,
            channel_id=channel_id,
            tcp_timeout_s=tcp_timeout_s,
        )

    def add_dram_region(self, size, base, offset):
        return register_tcp_dram_region(
            self,
            size=size,
            base=base,
            offset=offset,
            backend=self.dram_backend,
        )

    def close(self):
        if getattr(self, "_tcp_dram_backend_owned", False):
            self.dram_backend.close()
