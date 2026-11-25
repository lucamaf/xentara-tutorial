"""Tests of the simulator. Needs pymodbus (pip install -r requirements.txt).  Run:  python3 -m unittest -v test_modbus_sim"""
import asyncio
import socket
import struct
import unittest

from pymodbus.client import AsyncModbusTcpClient
from pymodbus.server import ServerAsyncStop, StartAsyncTcpServer

import modbus_sim as sim


def run_for(tank, seconds):
    for _ in range(int(seconds / sim.STEP)):
        tank.step(sim.STEP)


class TankTests(unittest.TestCase):
    def test_auto_mode_holds_the_level_around_the_set_point(self):
        tank = sim.Tank()
        run_for(tank, 300)
        levels = []
        for _ in range(3000):
            tank.step(sim.STEP)
            levels.append(tank.level)
        self.assertGreater(min(levels), 40.0)
        self.assertLess(max(levels), 60.0)
        self.assertGreater(max(levels) - min(levels), 1.0, 'the level moves while the pump cycles')

    def test_a_different_set_point_moves_the_level(self):
        tank = sim.Tank()
        tank.setpoint = 70.0
        run_for(tank, 300)
        self.assertGreater(tank.level, 60.0)

    def test_manual_mode_pump_off_drains_the_tank_and_latches_the_low_alarm(self):
        tank = sim.Tank()
        tank.auto_mode, tank.pump_enable = False, False
        run_for(tank, 120)
        self.assertEqual(tank.level, 0.0)
        self.assertFalse(tank.pump_on)
        self.assertTrue(tank.low_alarm)

    def test_manual_mode_pump_on_fills_the_tank_and_the_high_alarm_stays_until_acknowledged(self):
        tank = sim.Tank()
        tank.auto_mode, tank.pump_enable, tank.pump_speed = False, True, 100
        run_for(tank, 120)
        self.assertEqual(tank.level, 100.0)
        self.assertTrue(tank.pump_on and tank.high_alarm)
        self.assertGreater(tank.total, 500)
        tank.pump_enable = False
        run_for(tank, 30)
        self.assertLess(tank.level, 90.0)
        self.assertTrue(tank.high_alarm, 'latched')
        tank.acknowledge_alarms()
        self.assertFalse(tank.high_alarm)

    def test_an_alarm_cannot_be_acknowledged_while_its_condition_lasts(self):
        tank = sim.Tank()
        tank.auto_mode, tank.pump_enable, tank.pump_speed = False, True, 100
        run_for(tank, 120)
        tank.acknowledge_alarms()
        self.assertTrue(tank.high_alarm)


class TableTests(unittest.TestCase):
    def test_input_registers_are_encoded(self):
        tank = sim.Tank()
        tank.volume, tank.total, tank.flow, tank.age = 654.0, 70_000.0, 123.5, 0.0
        level, temperature, flow_high, flow_low, total_high, total_low = sim.input_registers(tank)
        self.assertEqual(level, 654)
        self.assertTrue(200 <= temperature <= 300, 'about 21 degC in tenths')
        self.assertEqual(struct.unpack('>f', struct.pack('>HH', flow_high, flow_low))[0], 123.5)
        self.assertEqual((total_high << 16) | total_low, 70_000)

    def test_a_negative_temperature_is_a_signed_16_bit_value(self):
        class Frozen(sim.Tank):
            temperature = -12.3

        register = sim.input_registers(Frozen())[1]
        self.assertEqual(struct.unpack('>h', struct.pack('>H', register))[0], -123)

    def test_writes_reach_the_tank(self):
        tank = sim.Tank()
        sim.write_holding_register(tank, 0, 700)
        sim.write_holding_register(tank, 1, 80)
        sim.write_coil(tank, 1, False)
        sim.write_coil(tank, 0, True)
        self.assertEqual((tank.setpoint, tank.pump_speed, tank.auto_mode, tank.pump_enable), (70.0, 80, False, True))
        self.assertEqual(sim.holding_registers(tank), [700, 80])
        self.assertEqual(sim.coils(tank), [True, False, False])

    def test_values_are_limited(self):
        tank = sim.Tank()
        sim.write_holding_register(tank, 0, 5000)
        sim.write_holding_register(tank, 1, 900)
        self.assertEqual((tank.setpoint, tank.pump_speed), (100.0, 100))

    def test_bits_are_packed_bit_zero_first(self):
        self.assertEqual(sim.pack_bits([True, False, True]), [0b101])
        self.assertEqual(sim.pack_bits([True] * 17), [0xFFFF, 1])


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class ServerTests(unittest.IsolatedAsyncioTestCase):
    """The whole device, with pymodbus as the client"""

    async def asyncSetUp(self):
        self.tank = sim.Tank()
        self.now = 1000.0  # a fake clock, so that the tests control how much time passes
        port = free_port()
        device = sim.build_device(self.tank, clock=lambda: self.now)
        self.server = asyncio.create_task(StartAsyncTcpServer(context=device, address=('127.0.0.1', port)))
        await asyncio.sleep(0.3)  # let the server start listening
        self.client = AsyncModbusTcpClient('127.0.0.1', port=port)
        for _ in range(50):
            if await self.client.connect():
                break
            await asyncio.sleep(0.1)
        self.assertTrue(self.client.connected)

    async def asyncTearDown(self):
        self.client.close()
        await ServerAsyncStop()
        await asyncio.wait_for(self.server, 5)

    async def test_read_all_tables(self):
        r = await self.client.read_input_registers(0, count=6, device_id=1)
        self.assertFalse(r.isError())
        self.assertEqual(r.registers[0], 400)  # 40.0 %
        r = await self.client.read_holding_registers(0, count=2, device_id=1)
        self.assertEqual(r.registers, [500, 60])
        r = await self.client.read_coils(0, count=3, device_id=1)
        self.assertEqual(r.bits[:3], [False, True, False])  # not pumping yet, auto mode
        r = await self.client.read_discrete_inputs(0, count=3, device_id=1)
        self.assertEqual(r.bits[:3], [False, False, False])

    async def test_writes_are_read_back(self):
        self.assertFalse((await self.client.write_register(0, 700, device_id=1)).isError())
        self.assertEqual((await self.client.read_holding_registers(0, count=1, device_id=1)).registers, [700])
        self.assertFalse((await self.client.write_registers(0, [500, 80], device_id=1)).isError())
        self.assertEqual((await self.client.read_holding_registers(0, count=2, device_id=1)).registers, [500, 80])
        self.assertFalse((await self.client.write_coil(1, False, device_id=1)).isError())
        self.assertFalse((await self.client.write_coils(0, [True, False, False], device_id=1)).isError())
        self.assertEqual((await self.client.read_coils(0, count=3, device_id=1)).bits[:3], [True, False, False])
        self.assertEqual(self.tank.pump_speed, 80)

    async def test_time_passes_between_requests(self):
        await self.client.write_coil(1, False, device_id=1)  # manual
        await self.client.write_coil(0, True, device_id=1)  # pump on
        await self.client.write_register(1, 100, device_id=1)  # full speed
        before = (await self.client.read_input_registers(0, count=1, device_id=1)).registers[0]
        self.now += 10.0
        after = (await self.client.read_input_registers(0, count=1, device_id=1)).registers[0]
        self.assertGreater(after, before + 100, 'the level rose by more than 10 % in 10 s')
        self.assertTrue((await self.client.read_discrete_inputs(0, count=1, device_id=1)).bits[0])

    async def test_alarm_acknowledge_is_a_momentary_command(self):
        await self.client.write_coil(1, False, device_id=1)
        await self.client.write_coil(0, True, device_id=1)
        await self.client.write_register(1, 100, device_id=1)
        self.now += 60.0
        self.assertTrue((await self.client.read_discrete_inputs(1, count=1, device_id=1)).bits[0], 'high alarm')
        await self.client.write_coil(0, False, device_id=1)
        self.now += 30.0
        self.assertTrue((await self.client.read_discrete_inputs(1, count=1, device_id=1)).bits[0], 'still latched')
        await self.client.write_coil(2, True, device_id=1)
        self.assertFalse((await self.client.read_discrete_inputs(1, count=1, device_id=1)).bits[0], 'acknowledged')
        self.assertFalse((await self.client.read_coils(2, count=1, device_id=1)).bits[0], 'the coil resets itself')

    async def test_errors_are_exceptions(self):
        self.assertTrue((await self.client.read_holding_registers(1000, count=1, device_id=1)).isError())
        self.assertTrue((await self.client.read_input_registers(5, count=2, device_id=1)).isError(), 'beyond the last register')
        self.assertTrue((await self.client.write_coil(50, True, device_id=1)).isError())


if __name__ == '__main__':
    unittest.main()
