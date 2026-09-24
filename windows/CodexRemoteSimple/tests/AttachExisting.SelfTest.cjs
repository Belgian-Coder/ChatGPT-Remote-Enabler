"use strict";
const assert = require('node:assert/strict');
const { openExistingInspector } = require('../runtime/attach-existing.cjs');

(async () => {
  for (const scenario of ['activate', 'reuse', 'wrong-pid', 'wrong-path', 'not-browser', 'unready', 'activate-unready', 'activate-delayed', 'occupied']) {
    let signals = 0, discoveries = 0, closed = 0, capabilityChecks = 0, inspectorClosed = 0;
    let clock = 0;
    const deps = {
      now: () => clock,
      sleep: async milliseconds => { clock += milliseconds; },
      discover: async () => {
        discoveries++;
        if (scenario === 'occupied') throw Error('Busy port');
        if (scenario.startsWith('activate') && discoveries === 1) throw Object.assign(Error('Refused'), { code: 'ECONNREFUSED' });
        return [{ type: 'node', webSocketDebuggerUrl: 'ws://127.0.0.1:9229/id' }];
      },
      activate: pid => { assert.equal(pid, 123); signals++; },
      connect: async () => ({ close: () => closed++ }),
      evaluate: async (_, expression) => {
        if (expression.startsWith('({pid:')) return { pid: scenario === 'wrong-pid' ? 456 : 123, path: scenario === 'wrong-path' ? 'C:\\Other.exe' : 'C:\\ChatGPT.exe', type: scenario === 'not-browser' ? undefined : 'browser' };
        if (expression.includes('inspector')) { inspectorClosed++; return true; }
        capabilityChecks++; return scenario === 'activate-delayed' ? capabilityChecks >= 4 : !scenario.endsWith('unready');
      },
    };
    const action = openExistingInspector({ pid: 123, executablePath: 'C:\\ChatGPT.exe', rendererTimeoutMs: 1000 }, deps);
    if (['activate', 'reuse', 'activate-delayed'].includes(scenario)) {
      const result = await action;
      assert.equal(result.pid, 123); assert.equal(result.rendererPort, 9229);
      assert.equal(result.activated, scenario.startsWith('activate'));
    } else await assert.rejects(action);
    assert.equal(signals, scenario.startsWith('activate') ? 1 : 0);
    assert.equal(closed, scenario === 'occupied' ? 0 : 1);
    if (['wrong-pid', 'wrong-path', 'not-browser', 'occupied'].includes(scenario)) assert.equal(capabilityChecks, 0);
    assert.equal(inspectorClosed, scenario === 'activate-unready' ? 1 : 0, 'Only close our own activated inspector on failure');
    if (scenario === 'activate-delayed') assert.equal(capabilityChecks, 4, 'Wait for a cold renderer without reactivating the inspector');
    if (scenario.endsWith('unready')) assert.equal(clock, 1000, 'Renderer readiness wait must remain bounded');
  }
  await assert.rejects(openExistingInspector({ pid: 0, executablePath: 'C:\\ChatGPT.exe' }));
  let probeSignals = 0;
  await assert.rejects(openExistingInspector({ pid: 123, executablePath: 'C:\\ChatGPT.exe', activateIfMissing: false }, {
    discover: async () => { throw Object.assign(Error('Refused'), { code: 'ECONNREFUSED' }); },
    activate: () => probeSignals++,
  }));
  assert.equal(probeSignals, 0, 'Saved endpoint verification must not activate a missing inspector');
  console.log('Existing inspector activation tests passed (identity, occupied port, reuse, no lifecycle operations).');
})().catch(error => { console.error(error); process.exitCode = 1; });
