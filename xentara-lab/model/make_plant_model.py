"""Generates the Xentara model for the simulated water-tank station (Modbus TCP).

    python3 make_plant_model.py [device address] [output file]
    python3 make_plant_model.py modbus-sim:5020 modbus-plant.json

The UUIDs are derived from the element types and names, so generating the model again gives the same file.
"""
import json
import sys
import uuid

device_address = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1:5020'
out = sys.argv[2] if len(sys.argv) > 2 else 'modbus-plant.json'

DEVICE = 'Tank Station PLC'


NAMESPACE = uuid.UUID('6f1c1d0e-2f4a-4b0e-9a55-7a1d2c7f8b11')  # fixed, so that the UUIDs are stable


def u(type_, name):
    return str(uuid.uuid5(NAMESPACE, f'{type_}/{name}'))


def element(type_, name, **props):
    return {type_: {'name': name, 'UUID': u(type_, name), **props}}


def channel(type_, name, address, poll=None, **extra):
    props = {'address': address, **extra}
    if poll:
        props['poll'] = f'{DEVICE}.{poll}'
    return element(f'@Skill.Modbus.{type_}', name, **props)


def converted(name, raw, low, high, mapped_low, mapped_high):
    return element(
        '@Skill.SignalProcessing.ConvertedValue',
        name,
        rawValue=f'{DEVICE}.{raw}',
        mappings=[{'raw': low, 'mapped': mapped_low}, {'raw': high, 'mapped': mapped_high}],
    )


def datapoint(name, io, display, units=None):
    props = {'displayName': display, 'io': io}
    if units:
        props['units'] = units
    return element('@DataPoint', name, **props)


# ---------------------------------------------------------------- the Modbus device
device = element(
    '@Skill.Modbus.TCPDevice',
    DEVICE,
    address=device_address,
    serverID=1,
    children=[
        element('@Skill.Modbus.Poll', 'Poll Inputs'),
        element('@Skill.Modbus.Poll', 'Poll Outputs'),
        # input registers (read only)
        channel('InputRegister', 'Level Raw', 0, 'Poll Inputs', format='uint16'),
        channel('InputRegister', 'Temperature Raw', 1, 'Poll Inputs', format='int16'),
        channel('InputRegister', 'Flow Raw', 2, 'Poll Inputs', format='floatABCD'),
        channel('InputRegister', 'Total Volume Raw', 4, 'Poll Inputs', format='uint32'),
        # discrete inputs (read only)
        channel('DiscreteInput', 'Pump Running', 0, 'Poll Inputs'),
        channel('DiscreteInput', 'High Level Alarm', 1, 'Poll Inputs'),
        channel('DiscreteInput', 'Low Level Alarm', 2, 'Poll Inputs'),
        # holding registers (read/write): they are polled to read back what was written
        channel('HoldingRegister', 'Level Setpoint Raw', 0, 'Poll Outputs', format='uint16'),
        channel('HoldingRegister', 'Pump Speed Raw', 1, 'Poll Outputs', format='uint16'),
        # coils (read/write)
        channel('Coil', 'Pump Enable', 0, 'Poll Outputs'),
        channel('Coil', 'Auto Mode', 1, 'Poll Outputs'),
        channel('Coil', 'Alarm Acknowledge', 2),  # momentary command: write only, so not polled
    ],
)

# ---------------------------------------------------------------- engineering units
conversions = element(
    '@Group',
    'Conversions',
    children=[
        converted('Tank Level', 'Level Raw', 0, 1000, 0, 100),
        converted('Temperature', 'Temperature Raw', -200, 1500, -20, 150),
        converted('Level Setpoint', 'Level Setpoint Raw', 0, 1000, 0, 100),
    ],
)

# ---------------------------------------------------------------- the process data points
plant = element(
    '@Group',
    'Plant',
    children=[
        datapoint('Tank Level', 'Conversions.Tank Level', 'Tank fill level', '%'),
        datapoint('Temperature', 'Conversions.Temperature', 'Water temperature', '°C'),
        datapoint('Flow Rate', f'{DEVICE}.Flow Raw', 'Pump flow rate', 'l/min'),
        datapoint('Total Volume', f'{DEVICE}.Total Volume Raw', 'Total volume pumped', 'l'),
        datapoint('Pump Running', f'{DEVICE}.Pump Running', 'Pump is running'),
        datapoint('High Level Alarm', f'{DEVICE}.High Level Alarm', 'Level above 90 % (latched)'),
        datapoint('Low Level Alarm', f'{DEVICE}.Low Level Alarm', 'Level below 10 % (latched)'),
        datapoint('Level Setpoint', 'Conversions.Level Setpoint', 'Level set point (writable)', '%'),
        datapoint('Pump Speed', f'{DEVICE}.Pump Speed Raw', 'Pump speed (writable)', '%'),
        datapoint('Pump Enable', f'{DEVICE}.Pump Enable', 'Pump command in manual mode (writable)'),
        datapoint('Auto Mode', f'{DEVICE}.Auto Mode', 'Automatic level control (writable)'),
        datapoint('Alarm Acknowledge', f'{DEVICE}.Alarm Acknowledge', 'Acknowledge latched alarms (write true)'),
    ],
)

# ---------------------------------------------------------------- scheduling
# All tasks of one Modbus TCP device must run in the same execution track, one after the other.
track = element(
    '@Track',
    'Modbus Track',
    children=[
        element('@Timer', 'Poll Timer', period='500ms'),
        element('@Timer', 'Reconnect Timer', period='10s'),
        element(
            '@Pipeline',
            'Poll Pipeline',
            triggers=['Modbus Track.Poll Timer.expired'],
            checkpoints=[{}, {}],
            segments=[
                {
                    'start': 0,
                    'end': 1,
                    'tasks': [
                        {'function': f'{DEVICE}.Poll Inputs.execute'},
                        {'function': f'{DEVICE}.Poll Outputs.execute'},
                        {'function': f'{DEVICE}.writeOutputs'},
                        {'function': 'Inspector.dump'},
                    ],
                }
            ],
        ),
        element(
            '@Pipeline',
            'Reconnect Pipeline',
            triggers=['Modbus Track.Reconnect Timer.expired'],
            checkpoints=[{}, {}],
            segments=[{'start': 0, 'end': 1, 'tasks': [{'function': f'{DEVICE}.reconnect'}]}],
        ),
    ],
)

# ---------------------------------------------------------------- debugging output
inspector = element(
    '@Skill.Debugging.Inspector',
    'Inspector',
    title='Tank station:',
    attributes=[
        'Plant.Tank Level.value',
        'Plant.Tank Level.quality',
        'Plant.Temperature.value',
        'Plant.Flow Rate.value',
        'Plant.Total Volume.value',
        'Plant.Pump Running.value',
        'Plant.High Level Alarm.value',
        'Plant.Low Level Alarm.value',
        'Plant.Level Setpoint.value',
        'Plant.Pump Speed.value',
        'Plant.Auto Mode.value',
    ],
)

model = {
    '$schema': 'https://docs.xentara.io/xentara/schema-xentara-model.json',
    'children': [plant, conversions, device, track, inspector],
}

with open(out, 'w') as f:
    json.dump(model, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('wrote', out)
