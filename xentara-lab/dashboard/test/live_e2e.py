"""Live test: drives the dashboard in headless Chrome against a REAL Xentara, through the DevTools protocol.

It logs in, checks that the 11 data points arrive, writes the inputs (set point, pump speed, auto mode, pump, alarm
acknowledge) and prints whether the model confirmed each write. Needs: pip install websockets, Google Chrome, a running
Xentara with the lab model, a user with the "write" entitlement, and the dashboard served somewhere.

    python3 live_e2e.py <dashboard URL> <xentara host:port> <user> <file with the password> <screenshot.png>
    python3 live_e2e.py "http://127.0.0.1:8091/" localhost:19670 admin ~/.xentara-password shot.png
"""
import asyncio
import base64
import json
import subprocess
import sys
import tempfile
import time
import urllib.request

import websockets

PAGE = sys.argv[1]  # e.g. http://127.0.0.1:8091/?host=localhost:19671
HOST = sys.argv[2]
USER = sys.argv[3]
PASSWORD = open(sys.argv[4]).read().strip()
SHOT = sys.argv[5]
PORT = 9333


class Cdp:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0
        self.pending = {}
        self.console = []
        self.task = asyncio.create_task(self.pump())

    async def pump(self):
        async for raw in self.ws:
            message = json.loads(raw)
            if 'id' in message:
                future = self.pending.pop(message['id'], None)
                if future:
                    future.set_result(message)
            elif message.get('method') == 'Runtime.consoleAPICalled':
                args = ' '.join(str(a.get('value', a.get('description', ''))) for a in message['params']['args'])
                self.console.append(f"console.{message['params']['type']}: {args}")
            elif message.get('method') == 'Runtime.exceptionThrown':
                self.console.append('EXCEPTION: ' + json.dumps(message['params']['exceptionDetails'].get('exception', {}).get('description', message['params']['exceptionDetails'].get('text'))))
            elif message.get('method') == 'Log.entryAdded':
                entry = message['params']['entry']
                self.console.append(f"log.{entry['level']}: {entry['text']} {entry.get('url', '')}")

    async def call(self, method, **params):
        self.next_id += 1
        future = asyncio.get_event_loop().create_future()
        self.pending[self.next_id] = future
        await self.ws.send(json.dumps({'id': self.next_id, 'method': method, 'params': params}))
        return (await asyncio.wait_for(future, 60)).get('result', {})

    async def js(self, expression, await_promise=False):
        result = await self.call('Runtime.evaluate', expression=expression, returnByValue=True, awaitPromise=await_promise)
        if 'exceptionDetails' in result:
            raise RuntimeError(result['exceptionDetails'].get('exception', {}).get('description', 'script error'))
        return result['result'].get('value')


async def wait_for(cdp, expression, timeout, interval=0.5):
    end = time.time() + timeout
    while time.time() < end:
        value = await cdp.js(expression)
        if value:
            return value
        await asyncio.sleep(interval)
    return None


def values(snapshot, *names):
    return {n: (snapshot.get(n) or {}).get('value') for n in names}


async def main():
    chrome = subprocess.Popen(
        ['google-chrome', '--headless=new', '--no-sandbox', '--disable-gpu', '--ignore-certificate-errors', f'--remote-debugging-port={PORT}',
         f'--user-data-dir={tempfile.mkdtemp(prefix="dashboard-e2e-")}', '--window-size=1250,1150', 'about:blank'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                request = urllib.request.Request(f'http://127.0.0.1:{PORT}/json/new?about:blank', method='PUT')
                target = json.load(urllib.request.urlopen(request, timeout=2))
                break
            except Exception:
                await asyncio.sleep(0.3)
        else:
            raise RuntimeError('Chrome did not start')

        async with websockets.connect(target['webSocketDebuggerUrl'], max_size=64 * 1024 * 1024) as ws:
            cdp = Cdp(ws)
            for domain in ('Page', 'Runtime', 'Log'):
                await cdp.call(f'{domain}.enable')
            await cdp.call('Emulation.setDeviceMetricsOverride', width=1250, height=1150, deviceScaleFactor=1, mobile=False)
            await cdp.call('Page.navigate', url=PAGE)
            assert await wait_for(cdp, 'typeof window.lab === "object"', 15), 'the dashboard did not load'
            print('page loaded:', await cdp.js('document.title'))

            # ---- connect with the dashboard's own code
            await cdp.js(f'window.lab.connectLive({json.dumps(HOST)}, {json.dumps(USER)}, {json.dumps(PASSWORD)})', await_promise=True)
            state = await wait_for(cdp, '(() => { const s = document.getElementById("status").dataset.state; return (s === "live" || s === "error") ? s : null })()', 25)
            text = await cdp.js('document.getElementById("status").textContent')
            error = await cdp.js('document.getElementById("error").textContent')
            print(f'connection state: {state}  |  {text}  |  {error}')
            if state != 'live':
                print('--- console:'); [print('  ', c) for c in cdp.console[-15:]]
                return 1

            await asyncio.sleep(3)
            snap = json.loads(await cdp.js('JSON.stringify(window.lab.snapshot())'))
            print('subscribed values:', len(snap), 'data points')
            for name in ('Tank Level', 'Temperature', 'Flow Rate', 'Total Volume', 'Pump Running', 'High Level Alarm', 'Low Level Alarm', 'Level Setpoint', 'Pump Speed', 'Auto Mode', 'Pump Enable'):
                e = snap.get(name, {})
                print(f'   {name:18} value={e.get("value")!r:>12}  quality={e.get("quality")!r}')

            # ---- an input: the set point
            async def write(name, value, label):
                await cdp.js(f'window.lab.send({json.dumps(name)}, {json.dumps(value)}, {json.dumps(label)})', await_promise=True)
                status = await wait_for(cdp, '(() => { const e = document.getElementById("write-status"); return /confirmed|sent\\.|Not connected|Unknown|denied|error|read only/i.test(e.textContent) ? e.className + " | " + e.textContent : null })()', 20)
                print(f'   write {name} = {value}: {status}')

            print('--- writes')
            await write('Level Setpoint', 70, 'Set point 70 %')
            await write('Pump Speed', 100, 'Pump speed 100 %')
            before = json.loads(await cdp.js('JSON.stringify(window.lab.snapshot())'))
            print(f'   level {before["Tank Level"]["value"]} % (set point {before["Level Setpoint"]["value"]}, speed {before["Pump Speed"]["value"]})')
            await asyncio.sleep(12)
            after = json.loads(await cdp.js('JSON.stringify(window.lab.snapshot())'))
            print(f'   12 s later: level {after["Tank Level"]["value"]} %, pump running {after["Pump Running"]["value"]}, flow {after["Flow Rate"]["value"]}')

            print('--- manual mode: pump on')
            await write('Auto Mode', False, 'Automatic control off')
            await write('Pump Enable', True, 'Pump on')
            await asyncio.sleep(4)
            manual = json.loads(await cdp.js('JSON.stringify(window.lab.snapshot())'))
            print('   ', values(manual, 'Auto Mode', 'Pump Enable', 'Pump Running', 'Flow Rate'))
            await write('Alarm Acknowledge', True, 'Acknowledge alarms')

            await write('Auto Mode', True, 'Automatic control on')
            await write('Level Setpoint', 50, 'Set point 50 %')

            await asyncio.sleep(2)
            shot = await cdp.call('Page.captureScreenshot', format='png')
            open(SHOT, 'wb').write(base64.b64decode(shot['data']))
            print('screenshot:', SHOT)
            print('--- console messages:', len(cdp.console))
            for c in cdp.console[-12:]:
                print('  ', c[:200])
        return 0
    finally:
        chrome.terminate()


sys.exit(asyncio.run(main()))
