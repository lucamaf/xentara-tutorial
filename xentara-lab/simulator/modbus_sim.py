#!/usr/bin/env python3
"""A Modbus TCP device simulator: a small water-tank station. Needs pymodbus (see requirements.txt).

  Input registers (read only, function 4)
    0      tank level, uint16, 0.1 %           (0 .. 1000)
    1      temperature, int16, 0.1 degC        (-200 .. 1500)
    2-3    flow rate, float32 "ABCD", l/min    (high word first)
    4-5    total volume pumped, uint32, litres (high word first)
  Discrete inputs (read only, function 2)
    0      pump running
    1      high level alarm   (level > 90 %, latched)
    2      low level alarm    (level < 10 %, latched)
  Holding registers (read/write, functions 3, 6, 16)
    0      level set point, uint16, 0.1 %      (0 .. 1000, default 500)
    1      pump speed, uint16, %               (0 .. 100, default 60)
  Coils (read/write, functions 1, 5, 15)
    0      pump enable (manual mode; in auto mode it shows what the controller does)
    1      auto mode (default on): a hysteresis controller switches the pump around the set point
    2      alarm acknowledge: write true to clear the latched alarms (it always reads false)

The Tank class is plain Python (the physics and the controls). pymodbus does the protocol; the only glue is the
`action` function below, which runs on every Modbus request: it advances the tank to the current time, applies
writes, and refreshes the table that is being accessed from the tank.

Usage:  python3 modbus_sim.py [--host 0.0.0.0] [--port 5020] [--unit-id 0] [--verbose]

  --verbose  prints every client connection and every request (reads too), with the unit ID the client uses.
             Xentara polls twice per cycle, so this is a few lines per second.
"""
import argparse
import asyncio
import math
import random
import signal
import struct
import time

from pymodbus.server import StartAsyncTcpServer
from pymodbus.simulator import DataType, SimData, SimDevice

STEP = 0.1  # seconds: the physics is calculated in steps of this size


# ---------------------------------------------------------------------------------------------------------------------
# The plant: no Modbus in here
# ---------------------------------------------------------------------------------------------------------------------
class Tank:
    """A 1000 litre tank, filled by a pump and drained through a constant outlet"""

    CAPACITY = 1000.0  # litres, so one litre is 0.1 %
    PUMP_FLOW_AT_100 = 25.0  # litres per second at 100 % pump speed
    OUTLET_FLOW = 9.0  # litres per second while the tank is not empty

    def __init__(self) -> None:
        # controls: written by the Modbus client
        self.setpoint = 50.0  # percent
        self.pump_speed = 60  # percent
        self.auto_mode = True
        self.pump_enable = False  # the pump command in manual mode
        # state
        self.volume = 400.0
        self.total = 0.0
        self.pump_on = False
        self.high_alarm = False
        self.low_alarm = False
        self.temperature_noise = 0.0
        self.age = 0.0  # simulated seconds since the start
        self.flow = 0.0  # litres per minute

    @property
    def level(self) -> float:
        """percent"""
        return self.volume / self.CAPACITY * 100.0

    def step(self, dt: float) -> None:
        # the pump: the controller in auto mode, the operator in manual mode
        if self.auto_mode:
            if self.level < self.setpoint - 5.0:
                self.pump_on = True
            elif self.level > self.setpoint + 5.0:
                self.pump_on = False
        else:
            self.pump_on = self.pump_enable

        inflow = self.PUMP_FLOW_AT_100 * self.pump_speed / 100.0 if self.pump_on else 0.0
        outflow = self.OUTLET_FLOW if self.volume > 0.0 else 0.0
        self.volume = max(0.0, min(self.CAPACITY, self.volume + (inflow - outflow) * dt))
        self.total += inflow * dt
        self.flow = inflow * 60.0 * (1.0 + random.uniform(-0.01, 0.01)) if inflow else 0.0

        # alarms stay latched until they are acknowledged
        self.high_alarm = self.high_alarm or self.level > 90.0
        self.low_alarm = self.low_alarm or self.level < 10.0

        # temperature: a slow wave, a little random walk, and the pump warms the water
        self.temperature_noise = max(-1.5, min(1.5, self.temperature_noise + random.uniform(-0.05, 0.05)))
        self.age += dt

    def acknowledge_alarms(self) -> None:
        self.high_alarm = self.level > 90.0
        self.low_alarm = self.level < 10.0

    @property
    def temperature(self) -> float:
        """degrees Celsius"""
        return 21.0 + 4.0 * math.sin(self.age / 90.0) + self.temperature_noise + (1.5 if self.pump_on else 0.0)


# ---------------------------------------------------------------------------------------------------------------------
# The Modbus tables of the device: how the tank looks to a Modbus client
# ---------------------------------------------------------------------------------------------------------------------
def input_registers(tank: Tank) -> list[int]:
    flow = struct.unpack('>HH', struct.pack('>f', tank.flow))  # float32, high word first
    total = int(tank.total) & 0xFFFFFFFF
    return [
        round(tank.level * 10),
        round(tank.temperature * 10) & 0xFFFF,  # int16 as two's complement
        flow[0], flow[1],
        total >> 16, total & 0xFFFF,
    ]


def holding_registers(tank: Tank) -> list[int]:
    return [round(tank.setpoint * 10), tank.pump_speed]


def discrete_inputs(tank: Tank) -> list[bool]:
    return [tank.pump_on and tank.pump_speed > 0, tank.high_alarm, tank.low_alarm]


def coils(tank: Tank) -> list[bool]:
    return [tank.pump_on if tank.auto_mode else tank.pump_enable, tank.auto_mode, False]


def write_holding_register(tank: Tank, address: int, value: int) -> None:
    if address == 0:
        tank.setpoint = min(value, 1000) / 10.0
    elif address == 1:
        tank.pump_speed = min(value, 100)


def write_coil(tank: Tank, address: int, value: bool) -> None:
    if address == 0:
        tank.pump_enable = value
    elif address == 1:
        tank.auto_mode = value
    elif address == 2 and value:
        tank.acknowledge_alarms()


def pack_bits(bits: list[bool]) -> list[int]:
    """The simulator stores bits in 16 bit registers, bit 0 first"""
    return [sum(1 << i for i, bit in enumerate(bits[n:n + 16]) if bit) for n in range(0, len(bits), 16)]


def build_device(tank: Tank, unit_id: int = 0, clock=time.monotonic) -> SimDevice:
    """The pymodbus device: four tables (coils, discrete inputs, holding registers, input registers) and the action.

    unit_id 0 means that the device answers to any unit ID (Modbus TCP devices usually ignore it)."""
    last = [clock()]

    async def action(function_code, start_address, address, count, registers, set_values):
        # 1. advance the tank to the current time
        now = clock()
        while last[0] + STEP <= now:
            tank.step(STEP)
            last[0] += STEP

        # 2. apply a write request
        if set_values is not None:
            if function_code in (5, 15):
                for i, bit in enumerate(set_values):
                    write_coil(tank, address + i, bool(bit))
            elif function_code in (6, 16):
                for i, value in enumerate(set_values):
                    write_holding_register(tank, address + i, int(value))

        # 3. show the current state of the tank in the table that is being accessed
        if function_code in (1, 5, 15):
            registers[:] = pack_bits(coils(tank))
        elif function_code == 2:
            registers[:] = pack_bits(discrete_inputs(tank))
        elif function_code in (3, 6, 16):
            registers[:] = holding_registers(tank)
        elif function_code == 4:
            registers[:] = input_registers(tank)
        return None

    return SimDevice(
        id=unit_id,
        action=action,
        simdata=(
            [SimData(0, count=3, values=False, datatype=DataType.BITS)],  # coils
            [SimData(0, count=3, values=False, datatype=DataType.BITS, readonly=True)],  # discrete inputs
            [SimData(0, count=2, values=0, datatype=DataType.UINT16)],  # holding registers
            [SimData(0, count=6, values=0, datatype=DataType.UINT16, readonly=True)],  # input registers
        ),
    )


def log(message: str) -> None:
    print(f'[{time.strftime("%H:%M:%S")}] {message}', flush=True)


def describe(pdu) -> str:
    """A request in one short line, e.g. "unit 1: ReadInputRegisters address 0 count 6" """
    name = type(pdu).__name__.removesuffix('Request')
    text = f'unit {pdu.dev_id}: {name} address {pdu.address}'
    values = list(getattr(pdu, 'registers', None) or getattr(pdu, 'bits', None) or [])
    if values:
        text += f' values {values}'
    elif getattr(pdu, 'count', None):
        text += f' count {pdu.count}'
    return text


def trace_pdu(sending: bool, pdu):
    """pymodbus calls this for every request and response. It must return the PDU."""
    if not sending:
        log(f'<- {describe(pdu)}')
    return pdu


async def serve(host: str, port: int, unit_id: int, verbose: bool) -> None:
    print(f'Modbus TCP water-tank simulator listening on {host}:{port} (unit ID: {unit_id or "any"})', flush=True)
    tracing = {}
    if verbose:
        tracing = {'trace_connect': lambda connected: log('client connected' if connected else 'client disconnected'), 'trace_pdu': trace_pdu}
    await StartAsyncTcpServer(context=build_device(Tank(), unit_id), address=(host, port), **tracing)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Modbus TCP water-tank simulator')
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=5020, help='TCP port (default 5020; 502 needs root)')
    parser.add_argument('--unit-id', type=int, default=0, help='Modbus unit ID to answer to (default 0: any)')
    parser.add_argument('--verbose', action='store_true', help='log connections and every request')
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, signal.default_int_handler)  # as PID 1 of a container: stop like on Ctrl+C
    try:
        asyncio.run(serve(args.host, args.port, args.unit_id, args.verbose))
    except KeyboardInterrupt:
        pass
