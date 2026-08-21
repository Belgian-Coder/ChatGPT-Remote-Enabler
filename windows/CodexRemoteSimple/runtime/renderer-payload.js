// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Clean-room contributors

(function installCleanroomStatsigGateBridge() {
  "use strict";

  const API_SLOT = "__CODEX_STATSIG_GATE_BRIDGE__";
  const TARGET_GATE = "782640499";
  const REMOTE_CONNECTIONS_GATE = "4114442250";
  const GATE_OVERRIDES = Object.freeze({
    [TARGET_GATE]: false,
    [REMOTE_CONNECTIONS_GATE]: true,
  });
  const CHECK_GATE_METHODS = Object.freeze([
    "checkGate",
    "checkGateWithExposureLoggingDisabled",
  ]);
  const STRUCTURED_GATE_METHODS = Object.freeze([
    "getFeatureGate",
    "getGate",
    "getGateValue",
  ]);
  const GATE_METHODS = Object.freeze([...CHECK_GATE_METHODS, ...STRUCTURED_GATE_METHODS]);

  const existing = globalThis[API_SLOT];
  if (
    existing?.version === 2
    && existing?.targetGate === TARGET_GATE
    && existing?.remoteConnectionsGate === REMOTE_CONNECTIONS_GATE
    && typeof existing.install === "function"
  ) {
    return existing.install();
  }

  const wrapperMarker = Symbol("codex.cleanroom.statsig.gate-wrapper");
  const records = [];
  let scans = 0;

  function isObjectLike(value) {
    return (typeof value === "object" && value !== null) || typeof value === "function";
  }

  function gateOverride(value) {
    if (typeof value !== "string" && typeof value !== "number") {
      return null;
    }
    const gate = String(value);
    return Object.hasOwn(GATE_OVERRIDES, gate) ? { gate, value: GATE_OVERRIDES[gate] } : null;
  }

  function findDataMethod(receiver, methodName) {
    let holder = receiver;
    let depth = 0;
    while (isObjectLike(holder) && depth < 10) {
      let descriptor;
      try {
        descriptor = Object.getOwnPropertyDescriptor(holder, methodName);
      } catch {
        return null;
      }
      if (descriptor) {
        return typeof descriptor.value === "function" ? { descriptor, holder, method: descriptor.value } : null;
      }
      try {
        holder = Object.getPrototypeOf(holder);
      } catch {
        return null;
      }
      depth += 1;
    }
    return null;
  }

  function isActive(record) {
    try {
      return record.receiver[record.methodName] === record.wrapper;
    } catch {
      return false;
    }
  }

  function gateMethodKind(methodName) {
    return CHECK_GATE_METHODS.includes(methodName) ? "check" : "structured";
  }

  function forceResolvedGateResult(result, forcedValue) {
    if (!isObjectLike(result)) {
      return forcedValue;
    }
    try {
      const descriptors = Object.getOwnPropertyDescriptors(result);
      for (const field of ["value", "enabled"]) {
        if (Object.hasOwn(descriptors, field)) {
          const descriptor = descriptors[field];
          descriptors[field] = {
            configurable: descriptor.configurable,
            enumerable: descriptor.enumerable,
            value: forcedValue,
            writable: Object.hasOwn(descriptor, "writable") ? descriptor.writable : true,
          };
        }
      }
      const clone = Array.isArray(result)
        ? Object.assign([], result)
        : Object.create(Object.getPrototypeOf(result), descriptors);
      for (const field of ["value", "enabled"]) {
        if (field in result && !Object.hasOwn(descriptors, field)) {
          Object.defineProperty(clone, field, {
            configurable: true,
            enumerable: true,
            value: forcedValue,
            writable: true,
          });
        } else if (Array.isArray(result) && field in result) {
          clone[field] = forcedValue;
        }
      }
      return clone;
    } catch {
      const clone = { ...result };
      if ("value" in result) clone.value = forcedValue;
      if ("enabled" in result) clone.enabled = forcedValue;
      return clone;
    }
  }

  function forceStructuredGateResult(result, forcedValue) {
    if (result != null && typeof result.then === "function") {
      return result.then((value) => forceResolvedGateResult(value, forcedValue));
    }
    return forceResolvedGateResult(result, forcedValue);
  }

  function recordExistingWrapper(receiver, methodName, wrapper, kind) {
    if (records.some((record) => record.receiver === receiver && record.methodName === methodName && record.wrapper === wrapper)) {
      return;
    }
    records.push({ kind, methodName, receiver, wrapper });
  }

  function wrapGateMethod(receiver, methodName) {
    const found = findDataMethod(receiver, methodName);
    if (!found) {
      return false;
    }
    const kind = gateMethodKind(methodName);
    if (found.method[wrapperMarker]?.kind === kind) {
      recordExistingWrapper(receiver, methodName, found.method, kind);
      return true;
    }

    const original = found.method;
    const wrapper = function cleanroomStatsigGateMethod(...args) {
      const override = gateOverride(args[0]);
      if (override) {
        if (kind === "check") {
          return override.value;
        }
        return forceStructuredGateResult(Reflect.apply(original, this, args), override.value);
      }
      return Reflect.apply(original, this, args);
    };
    try {
      Object.defineProperty(wrapper, wrapperMarker, { value: Object.freeze({ kind }) });
    } catch {
      return false;
    }

    const ownDescriptor = Object.getOwnPropertyDescriptor(receiver, methodName);
    let installed = false;
    if (ownDescriptor) {
      if (ownDescriptor.writable) {
        try {
          Object.defineProperty(receiver, methodName, { ...ownDescriptor, value: wrapper });
          installed = true;
        } catch {
          installed = false;
        }
      }
    } else if (Object.isExtensible(receiver)) {
      try {
        Object.defineProperty(receiver, methodName, {
          configurable: true,
          enumerable: false,
          value: wrapper,
          writable: true,
        });
        installed = true;
      } catch {
        installed = false;
      }
    }

    if (!installed && found.descriptor.writable) {
      try {
        Object.defineProperty(found.holder, methodName, { ...found.descriptor, value: wrapper });
        installed = true;
      } catch {
        installed = false;
      }
    }
    if (installed) {
      records.push({ kind, methodName, receiver, wrapper });
    }
    return installed;
  }

  function enqueueDescriptorValues(value, queue, depth) {
    let descriptors;
    try {
      descriptors = Object.getOwnPropertyDescriptors(value);
    } catch {
      return;
    }
    for (const descriptor of Object.values(descriptors)) {
      if (Object.hasOwn(descriptor, "value") && isObjectLike(descriptor.value)) {
        queue.push({ depth: depth + 1, value: descriptor.value });
      }
    }
    if (Array.isArray(value)) {
      return;
    }
    try {
      if (value instanceof Map) {
        for (const [mapKey, mapValue] of value) {
          if (isObjectLike(mapKey)) queue.push({ depth: depth + 1, value: mapKey });
          if (isObjectLike(mapValue)) queue.push({ depth: depth + 1, value: mapValue });
        }
      } else if (value instanceof Set) {
        for (const setValue of value) {
          if (isObjectLike(setValue)) queue.push({ depth: depth + 1, value: setValue });
        }
      }
    } catch {
      // Cross-realm or proxied collections are covered by descriptor traversal.
    }
  }

  function scan() {
    scans += 1;
    const root = globalThis.__STATSIG__;
    if (!isObjectLike(root)) {
      return probe();
    }
    const queue = [{ depth: 0, value: root }];
    const visited = new WeakSet();
    let inspected = 0;
    while (queue.length > 0 && inspected < 2_000) {
      const current = queue.shift();
      if (!current || current.depth > 8 || !isObjectLike(current.value) || visited.has(current.value)) {
        continue;
      }
      visited.add(current.value);
      inspected += 1;
      for (const methodName of GATE_METHODS) {
        wrapGateMethod(current.value, methodName);
      }
      enqueueDescriptorValues(current.value, queue, current.depth);
    }
    return probe();
  }

  function probe() {
    const active = records.filter(isActive);
    const clients = new Set(active.map((record) => record.receiver));
    const checkRecords = active.filter((record) => record.kind === "check");
    let passedMethods = 0;
    let remoteConnectionsPassedMethods = 0;
    for (const record of checkRecords) {
      try {
        if (Reflect.apply(record.wrapper, record.receiver, [TARGET_GATE]) === false) {
          passedMethods += 1;
        }
        if (Reflect.apply(record.wrapper, record.receiver, [REMOTE_CONNECTIONS_GATE]) === true) {
          remoteConnectionsPassedMethods += 1;
        }
      } catch {
        // A throwing probe is a failed proof, not a reason to call the original gate.
      }
    }
    const installedMethods = active.length;
    const allFalse = checkRecords.length > 0 && passedMethods === checkRecords.length;
    const remoteConnectionsAllTrue = checkRecords.length > 0
      && remoteConnectionsPassedMethods === checkRecords.length;
    return {
      allFalse,
      checkMethods: checkRecords.length,
      installedClients: clients.size,
      installedMethods,
      passedMethods,
      proof: allFalse && remoteConnectionsAllTrue,
      remoteConnectionsAllTrue,
      remoteConnectionsGate: REMOTE_CONNECTIONS_GATE,
      remoteConnectionsPassedMethods,
      scans,
      structuredMethods: active.length - checkRecords.length,
      targetGate: TARGET_GATE,
    };
  }

  const api = Object.freeze({
    install: scan,
    probe,
    remoteConnectionsGate: REMOTE_CONNECTIONS_GATE,
    scan,
    targetGate: TARGET_GATE,
    version: 2,
  });
  try {
    Object.defineProperty(globalThis, API_SLOT, {
      configurable: false,
      enumerable: false,
      value: api,
      writable: false,
    });
  } catch {
    globalThis[API_SLOT] = api;
  }

  const interval = setInterval(scan, 100);
  interval.unref?.();
  return scan();
})();
