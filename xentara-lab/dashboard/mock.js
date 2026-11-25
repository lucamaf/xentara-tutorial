// Demo source: the same water-tank physics as the Modbus simulator (../simulator/modbus_sim.py), in the browser, so that the
// dashboard can be tried without Xentara. It has the same interface as XentaraClient: connect(), close(), write(name, value).
// Writes take effect after a short delay, like the real chain (dashboard, Xentara, Modbus, tank).
(function (root) {
  'use strict';

  const STEP = 0.1; // seconds of simulated time per step

  class MockSource {
    /** options: onStatus, onValues, speed (simulated seconds per real second, default 1), writeDelay (ms, default 600) */
    constructor(options) {
      this.options = Object.assign({ onStatus() {}, onValues() {}, speed: 1, writeDelay: 600 }, options);
      this.capacity = 1000;
      this.pumpFlowAt100 = 25;
      this.outletFlow = 9;
      // controls
      this.setpoint = 50;
      this.pumpSpeed = 60;
      this.autoMode = true;
      this.pumpEnable = false;
      // state
      this.volume = 400;
      this.total = 0;
      this.pumpOn = false;
      this.highAlarm = false;
      this.lowAlarm = false;
      this.flow = 0;
      this.age = 0;
      this.noise = 0;
      this.timer = null;
      this.writes = [];
    }

    get level() {
      return (this.volume / this.capacity) * 100;
    }

    get temperature() {
      return 21 + 4 * Math.sin(this.age / 90) + this.noise + (this.pumpOn ? 1.5 : 0);
    }

    step(dt) {
      if (this.autoMode) {
        if (this.level < this.setpoint - 5) this.pumpOn = true;
        else if (this.level > this.setpoint + 5) this.pumpOn = false;
      } else {
        this.pumpOn = this.pumpEnable;
      }
      const inflow = this.pumpOn ? (this.pumpFlowAt100 * this.pumpSpeed) / 100 : 0;
      const outflow = this.volume > 0 ? this.outletFlow : 0;
      this.volume = Math.max(0, Math.min(this.capacity, this.volume + (inflow - outflow) * dt));
      this.total += inflow * dt;
      this.flow = inflow ? inflow * 60 * (1 + (Math.random() - 0.5) * 0.02) : 0;
      this.highAlarm = this.highAlarm || this.level > 90;
      this.lowAlarm = this.lowAlarm || this.level < 10;
      this.noise = Math.max(-1.5, Math.min(1.5, this.noise + (Math.random() - 0.5) * 0.1));
      this.age += dt;
    }

    snapshot() {
      const now = Date.now();
      const point = (value) => ({ value, quality: 0, time: now });
      return {
        'Tank Level': point(Math.round(this.level * 10) / 10),
        Temperature: point(Math.round(this.temperature * 10) / 10),
        'Flow Rate': point(this.flow),
        'Total Volume': point(Math.floor(this.total)),
        'Pump Running': point(this.pumpOn && this.pumpSpeed > 0),
        'High Level Alarm': point(this.highAlarm),
        'Low Level Alarm': point(this.lowAlarm),
        'Level Setpoint': point(this.setpoint),
        'Pump Speed': point(this.pumpSpeed),
        'Pump Enable': point(this.autoMode ? this.pumpOn : this.pumpEnable),
        'Auto Mode': point(this.autoMode),
      };
    }

    connect() {
      this.options.onStatus('live', 'Demo: simulated tank in the browser (no Xentara connection)');
      this.options.onValues(this.snapshot());
      this.timer = setInterval(() => {
        const steps = Math.max(1, Math.round((this.options.speed * 0.1) / STEP));
        for (let i = 0; i < steps; i++) this.step(STEP);
        this.options.onValues(this.snapshot());
      }, 100);
      return Promise.resolve();
    }

    close() {
      clearInterval(this.timer);
      this.timer = null;
      this.options.onStatus('disconnected', 'Disconnected.');
    }

    write(name, value) {
      this.writes.push([name, value]);
      return new Promise((resolve) => {
        setTimeout(() => {
          const clamp = (v, low, high) => Math.max(low, Math.min(high, Number(v)));
          if (name === 'Level Setpoint') this.setpoint = clamp(value, 0, 100);
          else if (name === 'Pump Speed') this.pumpSpeed = Math.round(clamp(value, 0, 100));
          else if (name === 'Auto Mode') this.autoMode = Boolean(value);
          else if (name === 'Pump Enable') this.pumpEnable = Boolean(value);
          else if (name === 'Alarm Acknowledge' && value) {
            this.highAlarm = this.level > 90;
            this.lowAlarm = this.level < 10;
          }
          resolve();
        }, this.options.writeDelay);
      });
    }
  }

  const api = { MockSource };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.Mock = api;
})(typeof self !== 'undefined' ? self : this);
