"use strict";

(() => {
  const API_SLOT = "__CODEX_REMOTE_MOBILE_PROJECT_VIEW__";
  const CARD_ID = "codex-remote-mobile-project-card";
  const CONFIG_SLOT = "__CODEX_REMOTE_MOBILE_CONFIG__";
  const THREAD_LIST_REGISTRY_SLOT = "__CODEX_REMOTE_MOBILE_THREAD_LIST_REGISTRY__";
  const CONTEXT_ID = "codex-remote-mobile-project-context";
  const PANEL_ID = "codex-remote-mobile-project-panel";
  const STYLE_ID = "codex-remote-mobile-project-style";
  const ROW_SELECTOR = "[data-app-action-sidebar-thread-row]";
  const AUTO_ENABLED_KEY = "codex-remote-mobile-auto-register-enabled-v1";
  const HOST_NAMES_KEY = "codex-remote-mobile-host-names-v1";
  const AUTO_MANAGED_KEY = "codex-remote-mobile-auto-managed-v1";
  const AUTO_SUPPRESSED_KEY = "codex-remote-mobile-auto-suppressed-v1";
  const AUTO_ARCHIVE_ENABLED_KEY = "codex-remote-mobile-auto-archive-enabled-v1";
  const AUTO_ARCHIVED_RECORDS_KEY = "codex-remote-mobile-auto-archived-records-v1";
  const AUTO_ARCHIVE_LOCK_KEY = "codex-remote-mobile-auto-archive-lock-v1";
  const UPDATE_SLOT = "__CHATGPT_REMOTE_UPDATE__";
  const UPDATE_EVENT = "chatgpt-remote-update-status";
  const AUTO_ARCHIVE_DAYS = 7;
  const AUTO_DELETE_AFTER_ARCHIVE_DAYS = 7;
  const AUTO_ARCHIVE_INTERVAL_MS = 60 * 60 * 1000;
  const AUTO_ARCHIVE_RETRY_MS = 5 * 60 * 1000;
  const AUTO_MAINTENANCE_BATCH_LIMIT = 20;
  const AUTO_MAINTENANCE_RUN_LIMIT_MS = 90000;
  const REMOTE_UNREAD_ACK_KEY = "codex-remote-mobile-unread-ack-v1";
  const REMOTE_UNREAD_ACK_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;
  const LOCAL_REMOTE_PROJECTS_TTL_MS = 15000;
  const NATIVE_INVENTORY_REFRESH_MS = 60000;
  const NATIVE_INVENTORY_DIRTY_DEBOUNCE_MS = 250;
  const NATIVE_INVENTORY_ERROR_RETRY_MS = 60000;
  const REMOTE_INVENTORY_FILENAME = "remote-project-inventory-v1.json";
  const REMOTE_INVENTORY_MAX_AGE_MS = 180000;
  const REMOTE_INVENTORY_ACTIVE_MS = 5000;
  const REMOTE_INVENTORY_IDLE_MS = 15000;
  const REMOTE_INVENTORY_FUTURE_SKEW_MS = 5 * 60 * 1000;
  const REMOTE_INVENTORY_RETRY_MS = 15000;
  const REMOTE_INVENTORY_ACTIVE_TTL_MS = 5000;
  const REMOTE_INVENTORY_IDLE_TTL_MS = 30000;
  const REMOTE_TASK_STATUS_MAX_AGE_MS = 30000;
  const REQUEST_TIMEOUT_MS = 12000;
  const MAX_THREAD_LIST_PAGES = 200;
  const THREAD_VISIBILITY_CONTRACT_VERSION = 53;
  const VERIFIED_THREAD_IDS_KEY = "codex-remote-mobile-verified-thread-ids-v2";
  const VERIFIED_THREAD_IDS_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
  const VERIFIED_THREAD_IDS_FUTURE_SKEW_MS = 5 * 60 * 1000;
  const USER_VISIBLE_THREAD_SOURCE_KINDS = Object.freeze(["cli", "vscode"]);
  const MAINTENANCE_THREAD_SOURCE_KINDS = Object.freeze([
    ...USER_VISIBLE_THREAD_SOURCE_KINDS,
    "appServer",
    "exec",
    "subAgent",
    "subAgentReview",
    "subAgentCompact",
    "subAgentThreadSpawn",
    "subAgentOther",
    "unknown",
  ]);
  const PUBLISHER_VERSION = 53;
  const VERSION = 66;
  const UPDATE_STATES = new Set(["checking", "current", "available", "queued", "preparing", "closing", "updating", "restarting", "error", "unavailable"]);
  const ACTIVITY_BUSY_STATUSES = new Set(["active", "generating", "inprogress", "loading", "pending", "queued", "running", "working"]);
  const ACTIVITY_IDLE_STATUSES = new Set(["complete", "completed", "idle", "notloaded"]);
  const TRUSTED_TITLE_SOURCES = new Set([
    "app-server-displayName",
    "app-server-entry-title",
    "app-server-name",
    "app-server-subject",
    "app-server-summary-title",
    "app-server-title",
    "native-dom",
    "native-generated-title",
    "native-title",
  ]);
  const LOCAL_FOLDER_PATH = Object.freeze({
    closed: "M5.55957 2.14136C6.06503 2.14136 6.55801 2.30207 6.9668 2.59937L7.81836 3.21851C8.04761 3.38513 8.32401 3.47534 8.60742 3.47534H12.1338C13.4545 3.47559 14.5254 4.54621 14.5254 5.86694V11.4666C14.5254 12.7873 13.4545 13.8579 12.1338 13.8582H3.86621C2.54554 13.8579 1.47461 12.7873 1.47461 11.4666V4.53296C1.47486 3.21244 2.54569 2.1416 3.86621 2.14136H5.55957ZM2.52539 7.85718V11.4666C2.52539 12.2074 3.12544 12.8081 3.86621 12.8083H12.1338C12.8746 12.8081 13.4746 12.2074 13.4746 11.4666V7.85718H2.52539ZM3.86621 3.19214C3.12559 3.19238 2.52564 3.79234 2.52539 4.53296V6.8064H13.4746V5.86694C13.4746 5.12611 12.8746 4.52539 12.1338 4.52515H8.60742C8.10203 4.52515 7.60895 4.36534 7.2002 4.06812L6.34863 3.448C6.11937 3.28135 5.84301 3.19214 5.55957 3.19214H3.86621Z",
    open: "M4.75488 2.1416C5.30942 2.14164 5.74594 2.23705 6.11816 2.38965C6.48323 2.53934 6.76728 2.73817 7.00391 2.9043L7.02148 2.91699C7.47057 3.23238 7.8162 3.47463 8.55176 3.47461H11.333C12.7194 3.47484 13.8311 4.61217 13.8311 6L13.875 6.38281H13.8594C14.8729 6.38292 15.5982 7.3629 15.3018 8.33203L14.0068 12.5586C13.7703 13.3297 13.0576 13.8563 12.251 13.8564H3.83984C3.4199 13.8564 3.04144 13.7174 2.73828 13.4883L2.67383 13.4346C1.99907 12.9811 1.55577 12.2065 1.55566 11.3311L0.941406 4.66699C0.941406 3.2792 2.05315 2.1419 3.43945 2.1416H4.75488ZM4.7627 7.42969C4.56039 7.42972 4.3807 7.5625 4.32129 7.75586L3.08594 11.7891C2.96123 12.1965 3.18214 12.6072 3.54883 12.7529C3.63476 12.7768 3.74102 12.7958 3.88184 12.8086H12.251C12.5974 12.8085 12.9033 12.5821 13.0049 12.251L14.2998 8.02539C14.3901 7.72947 14.1688 7.42979 13.8594 7.42969H4.7627ZM3.43945 3.19141C2.64724 3.1917 1.99121 3.84481 1.99121 4.66699L2.49316 10.1201L3.32031 7.44922C3.51452 6.81571 4.10008 6.38284 4.7627 6.38281H12.8252L12.7812 6C12.7812 5.22902 12.2045 4.607 11.4795 4.53223L11.333 4.52441H8.55176C8.05756 4.52442 7.64464 4.44062 7.2666 4.2793C6.91453 4.12896 6.6274 3.92345 6.41797 3.77637L6.40039 3.76367C6.16212 3.59639 5.96404 3.46151 5.71973 3.36133C5.54113 3.28812 5.32754 3.2289 5.05176 3.2041L4.75488 3.19141H3.43945Z",
  });

  const previous = globalThis[API_SLOT];
  let previousProbe = null;
  try { previousProbe = previous?.probe?.() ?? null; } catch {}
  const previousHydrationTimeoutEvidence = typeof previousProbe?.inventoryHydrationError === "string"
    && /(?:(?:^|;\s*)local:\s*thread\/list\b[^;]*|local inventory hydration[^;]*)(?:timed out|bounded deadline)/iu.test(previousProbe.inventoryHydrationError);
  const previousMaintenanceTimeoutEvidence = [
    previousProbe?.autoArchiveError,
    previousProbe?.autoArchiveLastResult?.error,
  ].some((value) => typeof value === "string"
    && /(?:thread\/list|local inventory hydration|maintenance .*?(?:snapshot|revalidation)).*?(?:timed out|bounded deadline)/iu.test(value));
  let legacyPendingDiscovery = Number(previous?.version) < 62
    && (previousProbe?.inventoryHydrationPending === true
      || previousProbe?.autoArchivePending === true
      || previousHydrationTimeoutEvidence
      || previousMaintenanceTimeoutEvidence);
  let legacyDiscoveryCloseScheduled = false;
  try { previous?.uninstall?.(); } catch {}
  try { globalThis.__CODEX_REMOTE_PROJECT_LABELS__?.uninstall?.(); } catch {}

  const sharedThreadListRegistry = (() => {
    const existing = globalThis[THREAD_LIST_REGISTRY_SLOT];
    if (existing?.activeRequests instanceof WeakMap && existing?.gates instanceof WeakMap && existing?.legacySuspects instanceof WeakSet && existing?.quarantines instanceof WeakMap) {
      existing.activeQuarantineCount = Number.isInteger(existing.activeQuarantineCount) && existing.activeQuarantineCount >= 0 ? existing.activeQuarantineCount : 0;
      existing.recoveryPending = existing.recoveryPending === true;
      existing.recoveryReason = existing.recoveryPending && typeof existing.recoveryReason === "string" ? existing.recoveryReason : null;
      return existing;
    }
    const registry = {
      activeRequests: new WeakMap(),
      activeQuarantineCount: 0,
      gates: new WeakMap(),
      legacySuspects: new WeakSet(),
      quarantines: new WeakMap(),
      recoveryPending: false,
      recoveryReason: null,
    };
    Object.defineProperty(globalThis, THREAD_LIST_REGISTRY_SLOT, { configurable: false, enumerable: false, value: registry, writable: false });
    return registry;
  })();

  const config = globalThis[CONFIG_SLOT] ?? {};
  const state = {
    active: false,
    actionCardKey: null,
    autoArchiveError: null,
    autoArchiveGeneration: 0,
    autoArchiveLastRunAt: 0,
    autoArchiveLastResult: null,
    autoArchiveLeaseTimer: null,
    autoArchiveOwner: globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`,
    autoArchivePending: false,
    autoArchiveTimer: null,
    autoRegistrationFailures: new Map(),
    autoRegistrationPending: null,
    autoRegistrationTimer: null,
    autoReconciliationPending: false,
    autoReconciliationTimer: null,
    collapsed: new Set(),
    contextPoint: null,
    contextProjectKey: null,
    overlayFocusReturnKey: null,
    pendingOverlayFocus: null,
    drag: null,
    dragJustEndedAt: 0,
    disposed: false,
    filter: "all",
    hostConnectivity: new Map(),
    inventoryHydrationPending: false,
    inventoryHydrationError: sharedThreadListRegistry.recoveryPending ? sharedThreadListRegistry.recoveryReason : null,
    inventoryHydrationMicrotask: false,
    inventoryHydrationDirty: false,
    inventoryHydrationPhase: "idle",
    inventoryHydrationRounds: 0,
    inventoryHydrationStarted: false,
    inventoryHydrationTimer: null,
    inventoryHydrationTruncated: false,
    counters: {
      fullProbeRuns: 0,
      hostDiscoveryScans: 0,
      inventoryDirtyRequests: 0,
      inventoryHydrationRuns: 0,
      remoteRuntimeScans: 0,
      renders: 0,
      updateActivityScans: 0,
    },
    hostDiscoveryCache: null,
    hostDiscoveryDirty: true,
    hostDiscoveryScannedAt: 0,
    lastAction: null,
    localFetchFromHost: null,
    localCodexHome: null,
    localInventoryPublishedAt: 0,
    localInventoryProjects: [],
    localInventoryPublisherError: null,
    localInventoryPublisherPending: false,
    localInventoryPublisherTimer: null,
    localInventoryStatusSignature: "",
    localRuntimeHostIds: new Set(),
    localRegisteredProjects: new Map(),
    localRegisteredProjectsError: null,
    localRegisteredProjectsFetchedAt: 0,
    localRegisteredProjectsPending: false,
    localRuntime: null,
    localRuntimeGeneration: 0,
    localThreadListActiveClients: new Set(),
    localThreadListGates: sharedThreadListRegistry.gates,
    localThreadListQuarantines: sharedThreadListRegistry.quarantines,
    navigationBridge: null,
    mountRetryTimer: null,
    mountRetryDelay: 500,
    mountObserver: null,
    nativeContainer: null,
    originalDisplay: "",
    observer: null,
    observerTarget: null,
    panel: null,
    pendingNewThreads: new Set(),
    peerCacheStates: new Map(),
    projectService: null,
    queryClient: null,
    remoteProjectInventories: new Map(),
    remoteCodexHomes: new Map(),
    remoteRuntimeCache: new Map(),
    remoteRuntimeScannedAt: 0,
    remoteUnreadRecords: null,
    reorderPending: false,
    scheduledFrame: null,
    threadInventories: new Map(sharedThreadListRegistry.lastLocalInventory || sharedThreadListRegistry.recoveryPending ? [["local", {
      ...(sharedThreadListRegistry.lastLocalInventory ?? { fetchedAt: Date.now(), pages: 0, threads: [] }),
      error: sharedThreadListRegistry.recoveryPending ? sharedThreadListRegistry.recoveryReason : null,
      hostId: "local",
      retryAt: sharedThreadListRegistry.recoveryPending ? Date.now() + NATIVE_INVENTORY_ERROR_RETRY_MS : 0,
    }]] : []),
    threadManagers: new Map(),
    verifiedThreadIds: new Map(),
    view: "mobile",
    updateStatus: null,
    settingsOpen: false,
    deviceDetailsOpen: false,
    updateDetailsOpen: false,
    liveRegion: null,
    lastAnnouncement: "",
    displayedHosts: [],
  };

  function assignLocalRuntime(fetchFromHost, requestClient) {
    if (typeof requestClient?.sendRequest !== "function") return;
    if (legacyPendingDiscovery) {
      sharedThreadListRegistry.legacySuspects.add(requestClient);
      markLocalThreadListRecoveryPending("Pending v61 local request is awaiting a distinct app-server client");
      if (!legacyDiscoveryCloseScheduled) {
        legacyDiscoveryCloseScheduled = true;
        queueMicrotask(() => {
          legacyPendingDiscovery = false;
          legacyDiscoveryCloseScheduled = false;
        });
      }
      return;
    }
    if (sharedThreadListRegistry.legacySuspects.has(requestClient) || state.localThreadListQuarantines.has(requestClient)) return;
    if (state.localRuntime?.requestClient && state.localRuntime.requestClient !== requestClient) return;
    if (state.localRuntime?.requestClient !== requestClient) state.localRuntimeGeneration += 1;
    state.localRuntime = { fetchFromHost, requestClient };
  }

  function readBoolean(key) {
    try {
      const value = localStorage.getItem(key);
      return value === null ? key === AUTO_ENABLED_KEY : value === "true";
    } catch { return key === AUTO_ENABLED_KEY; }
  }

  function readOptionalBoolean(key) {
    try { return localStorage.getItem(key) === "true"; } catch { return false; }
  }

  function writeBoolean(key, value) {
    try { localStorage.setItem(key, String(Boolean(value))); } catch {}
  }

  function readRecords(key) {
    try {
      const value = JSON.parse(localStorage.getItem(key) || "{}");
      return value && typeof value === "object" && !Array.isArray(value) ? value : {};
    } catch { return {}; }
  }

  function writeRecords(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch {}
  }

  function loadVerifiedThreadIds() {
    const now = Date.now();
    const records = readRecords(VERIFIED_THREAD_IDS_KEY);
    let changed = false;
    for (const [hostId, record] of Object.entries(records)) {
      const verifiedAt = Number(record?.verifiedAt);
      if (!Number.isFinite(verifiedAt)
        || record?.contractVersion !== THREAD_VISIBILITY_CONTRACT_VERSION
        || verifiedAt - now > VERIFIED_THREAD_IDS_FUTURE_SKEW_MS
        || now - verifiedAt > VERIFIED_THREAD_IDS_MAX_AGE_MS
        || !Array.isArray(record?.ids)) {
        changed = true;
        continue;
      }
      const ids = new Set(record.ids.slice(0, 10000).map(rawConversationId).filter(Boolean));
      state.verifiedThreadIds.set(normalizeHostId(hostId), { ids, verifiedAt });
    }
    if (changed) persistVerifiedThreadIds(now);
  }

  function persistVerifiedThreadIds(now = Date.now()) {
    const records = {};
    for (const [hostId, record] of state.verifiedThreadIds) {
      if (!Number.isFinite(record?.verifiedAt)
        || record.verifiedAt - now > VERIFIED_THREAD_IDS_FUTURE_SKEW_MS
        || now - record.verifiedAt > VERIFIED_THREAD_IDS_MAX_AGE_MS) continue;
      records[hostId] = { contractVersion: THREAD_VISIBILITY_CONTRACT_VERSION, ids: [...record.ids].slice(0, 10000), verifiedAt: record.verifiedAt };
    }
    writeRecords(VERIFIED_THREAD_IDS_KEY, records);
  }

  function pruneVerifiedThreadIds(now = Date.now()) {
    let changed = false;
    for (const [hostId, record] of state.verifiedThreadIds) {
      if (!Number.isFinite(record?.verifiedAt)
        || record.verifiedAt - now > VERIFIED_THREAD_IDS_FUTURE_SKEW_MS
        || now - record.verifiedAt > VERIFIED_THREAD_IDS_MAX_AGE_MS) {
        state.verifiedThreadIds.delete(hostId);
        changed = true;
      }
    }
    if (changed) persistVerifiedThreadIds(now);
    return changed;
  }

  function rememberVerifiedThreadIds(hostId, threads) {
    const normalizedHostId = normalizeHostId(hostId);
    const verifiedAt = Date.now();
    const ids = new Set((threads ?? []).slice(0, 10000).map((thread) => rawConversationId(thread?.id ?? thread?.conversationId ?? "")).filter(Boolean));
    state.verifiedThreadIds.set(normalizedHostId, { ids, verifiedAt });
    pruneVerifiedThreadIds(verifiedAt);
    persistVerifiedThreadIds(verifiedAt);
  }

  function acquireAutoArchiveLease() {
    try {
      const now = Date.now();
      const existing = JSON.parse(localStorage.getItem(AUTO_ARCHIVE_LOCK_KEY) || "null");
      if (existing?.owner !== state.autoArchiveOwner && Number(existing?.expiresAt) > now) return false;
      localStorage.setItem(AUTO_ARCHIVE_LOCK_KEY, JSON.stringify({ expiresAt: now + 2 * 60 * 1000, owner: state.autoArchiveOwner }));
      return JSON.parse(localStorage.getItem(AUTO_ARCHIVE_LOCK_KEY) || "null")?.owner === state.autoArchiveOwner;
    } catch { return false; }
  }

  function releaseAutoArchiveLease() {
    try {
      const existing = JSON.parse(localStorage.getItem(AUTO_ARCHIVE_LOCK_KEY) || "null");
      if (existing?.owner === state.autoArchiveOwner) localStorage.removeItem(AUTO_ARCHIVE_LOCK_KEY);
    } catch {}
  }

  function withTimeout(promise, label, timeoutMilliseconds = REQUEST_TIMEOUT_MS) {
    let timer = null;
    const timeout = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        const error = new Error(`${label} timed out`);
        error.code = "CODEX_REMOTE_REQUEST_TIMEOUT";
        reject(error);
      }, timeoutMilliseconds);
    });
    return Promise.race([Promise.resolve(promise), timeout]).finally(() => {
      if (timer !== null) clearTimeout(timer);
    });
  }

  function sendRequestWithTimeout(requestClient, method, params, timeoutMilliseconds = REQUEST_TIMEOUT_MS) {
    if (typeof requestClient?.sendRequest !== "function") return Promise.reject(new Error("App-server bridge is unavailable"));
    return withTimeout(Promise.resolve().then(() => requestClient.sendRequest(method, params)), method, timeoutMilliseconds);
  }

  function fetchFromHostWithTimeout(fetchFromHost, action, payload, timeoutMilliseconds = REQUEST_TIMEOUT_MS) {
    if (typeof fetchFromHost !== "function") return Promise.reject(new Error("Project-state bridge is unavailable"));
    return withTimeout(Promise.resolve().then(() => fetchFromHost(action, payload)), action, timeoutMilliseconds);
  }

  function remoteUnreadIdentity(hostId, conversationKey) {
    return `${normalizeHostId(hostId)}::${conversationKey}`;
  }

  function normalizeTaskStatus(value) {
    return /^(?:active|generating|in[_-]?progress|loading|pending|queued|running|working)$/iu.test(value || "") ? "loading" : "idle";
  }

  function publishedTaskMetadata(task, thread) {
    const runtimeStatus = typeof thread?.status === "string" ? thread.status : thread?.status?.type;
    const unreadKnown = typeof thread?.hasUnreadTurn === "boolean" || typeof thread?.unread === "boolean";
    return {
      conversationKey: task.conversationId || rawConversationId(task.conversationKey),
      statusType: typeof runtimeStatus === "string" && runtimeStatus ? normalizeTaskStatus(runtimeStatus) : task.statusType,
      unread: unreadKnown ? thread?.hasUnreadTurn === true || thread?.unread === true : task.unread,
    };
  }

  function normalizedTitle(value) {
    return typeof value === "string" && value.trim() ? value.trim() : null;
  }

  function persistedThreadTitle(thread) {
    const candidates = [
      ["app-server-name", thread?.name],
      ["app-server-title", thread?.title],
      ["app-server-displayName", thread?.displayName],
      ["app-server-subject", thread?.subject],
      ["app-server-summary-title", thread?.summary?.title],
      ["app-server-entry-title", thread?.entry?.title],
    ];
    for (const [titleSource, value] of candidates) {
      const title = normalizedTitle(value);
      if (title) return { title, titleSource };
    }
    return { titleSource: "none" };
  }

  function trustedThreadTitle(thread) {
    if (Object.prototype.hasOwnProperty.call(thread ?? {}, "titleSource")) {
      const titleSource = TRUSTED_TITLE_SOURCES.has(thread?.titleSource) ? thread.titleSource : "none";
      const title = titleSource === "none" ? null : normalizedTitle(thread?.title);
      return title ? { title, titleSource } : { titleSource: "none" };
    }
    return persistedThreadTitle(thread);
  }

  function parsedThreadTitle(thread, publisherVersion) {
    if (!Number.isInteger(publisherVersion) || publisherVersion < PUBLISHER_VERSION
      || !Object.prototype.hasOwnProperty.call(thread ?? {}, "titleSource")) return { titleSource: "none" };
    return trustedThreadTitle(thread);
  }

  function threadTitle(thread) {
    return trustedThreadTitle(thread).title ?? "Untitled task";
  }

  function localNativeSummaryTitle(conversationId) {
    const manager = state.threadManagers.get("local");
    if (typeof manager?.getThreadSummaries !== "function") return { titleSource: "none" };
    try {
      const result = manager.getThreadSummaries();
      const summaries = Array.isArray(result) ? result : Array.isArray(result?.threads) ? result.threads : Array.isArray(result?.summaries) ? result.summaries : [];
      const summary = summaries.find((item) => rawConversationId(item?.id ?? item?.conversationId ?? item?.conversationKey ?? "") === conversationId);
      const title = normalizedTitle(summary?.title);
      if (title) return { title, titleSource: "native-title" };
      const generatedTitle = normalizedTitle(summary?.generatedTitle);
      if (generatedTitle) return { title: generatedTitle, titleSource: "native-generated-title" };
    } catch {}
    return { titleSource: "none" };
  }

  function localNativeDomTitle(conversationId) {
    const row = [...document.querySelectorAll(ROW_SELECTOR)]
      .find((item) => rawConversationId(item.getAttribute("data-app-action-sidebar-thread-id") || "") === conversationId);
    const title = normalizedTitle(row?.getAttribute("data-app-action-sidebar-thread-title"));
    return title && title !== "Untitled task" ? { title, titleSource: "native-dom" } : { titleSource: "none" };
  }

  function publishedThreadTitle(thread, conversationId) {
    for (const candidate of [localNativeSummaryTitle(conversationId), localNativeDomTitle(conversationId), persistedThreadTitle(thread)]) {
      if (candidate.title) return candidate;
    }
    return { titleSource: "none" };
  }

  function titleSourceRank(titleSource) {
    if (typeof titleSource === "string" && titleSource.startsWith("app-server-")) return 3;
    if (titleSource === "native-title" || titleSource === "native-generated-title") return 2;
    if (titleSource === "native-dom") return 1;
    return 0;
  }

  function mergeTaskTitle(target, source) {
    const candidate = trustedThreadTitle(source);
    if (!candidate.title) {
      if (!trustedThreadTitle(target).title) {
        target.title = "Untitled task";
        target.titleSource = "none";
      }
      return;
    }
    if (titleSourceRank(candidate.titleSource) >= titleSourceRank(target?.titleSource)) {
      target.title = candidate.title;
      target.titleSource = candidate.titleSource;
    }
  }

  function acknowledgeRemoteUnread(task) {
    if (!task?.conversationKey || task.hostId === "local") return;
    const records = state.remoteUnreadRecords ??= readRecords(REMOTE_UNREAD_ACK_KEY);
    records[remoteUnreadIdentity(task.hostId, task.conversationId || task.conversationKey)] = { acknowledgedAt: Date.now() };
    writeRecords(REMOTE_UNREAD_ACK_KEY, records);
  }

  function remoteUnreadAcknowledged(task, authoritativeState) {
    if (!task?.conversationKey || task.hostId === "local") return false;
    const records = state.remoteUnreadRecords ??= readRecords(REMOTE_UNREAD_ACK_KEY);
    const key = remoteUnreadIdentity(task.hostId, task.conversationId || task.conversationKey);
    const record = records[key];
    if (!record) return false;
    const acknowledgedAt = Number(record.acknowledgedAt);
    const expired = !Number.isFinite(acknowledgedAt) || Date.now() - acknowledgedAt > REMOTE_UNREAD_ACK_MAX_AGE_MS;
    const transitioned = authoritativeState && authoritativeState.unread !== true;
    if (expired || transitioned) {
      delete records[key];
      writeRecords(REMOTE_UNREAD_ACK_KEY, records);
      return false;
    }
    return true;
  }

  function projectIdentity(project) {
    return project?.hostId && project.hostId !== "local" && project.cwd
      ? `${normalizeHostId(project.hostId)}::${normalizePath(project.cwd)}`
      : null;
  }

  function projectIdentityAliases(project) {
    const identity = projectIdentity(project);
    if (!identity) return [];
    const legacyPath = project.cwd.replace(/[\\/]+$/u, "").toLocaleLowerCase();
    const normalizedHostId = normalizeHostId(project.hostId);
    const shortHostId = normalizedHostId.replace(/^remote-control:/u, "");
    return [...new Set([
      identity,
      `${normalizedHostId}::${legacyPath}`,
      `${shortHostId}::${normalizePath(project.cwd)}`,
      `${shortHostId}::${legacyPath}`,
    ])];
  }

  function setRecord(storageKey, project, enabled) {
    const identity = projectIdentity(project);
    if (!identity) return false;
    const records = readRecords(storageKey);
    for (const alias of projectIdentityAliases(project)) delete records[alias];
    if (enabled) {
      records[identity] = {
        cwd: project.cwd,
        hostId: project.hostId,
        name: project.name,
        updatedAt: new Date().toISOString(),
      };
    } else {
      delete records[identity];
    }
    writeRecords(storageKey, records);
    return true;
  }

  function hasRecord(storageKey, project) {
    const records = readRecords(storageKey);
    return projectIdentityAliases(project).some((identity) => Boolean(records[identity]));
  }

  function getFiber(element) {
    const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
    return key ? element[key] : null;
  }

  function cwdFromProps(props) {
    if (!props || typeof props !== "object") return null;
    const candidates = [
      props.displayCwd,
      props.cwd,
      props.threadSummary?.cwd,
      props.entry?.cwd,
      props.entry?.summary?.cwd,
    ];
    return candidates.find((value) => typeof value === "string" && value.trim()) ?? null;
  }

  function metadataFromRow(row) {
    let cwd = null;
    let isGrouped = null;
    let isProjectless = null;
    let projectId = null;
    let projectLabel = null;
    const nativeStatus = nativeTaskStatusMetadata(row);
    const statusType = normalizeTaskStatus(nativeStatus?.statusState?.type);
    const unread = nativeStatus?.statusState?.unread === true;
    const hostNames = new Map();
    let fiber = getFiber(row);
    for (let level = 0; fiber && level < 80; level += 1, fiber = fiber.return) {
      const props = fiber.memoizedProps;
      cwd ??= cwdFromProps(props);
      if (typeof props?.hoverCardProjectId === "string" && props.hoverCardProjectId) projectId ??= props.hoverCardProjectId;
      if (typeof props?.hoverCardProjectLabel === "string" && props.hoverCardProjectLabel.trim()) projectLabel ??= props.hoverCardProjectLabel.trim();
      if (isGrouped === null && typeof props?.isGrouped === "boolean") isGrouped = props.isGrouped;
      if (isProjectless === null && typeof props?.isProjectlessHoverCard === "boolean") isProjectless = props.isProjectlessHoverCard;
      if (Array.isArray(props?.connectionGroups)) {
        for (const group of props.connectionGroups) {
          if (typeof group?.hostId === "string" && typeof group?.hostDisplayName === "string") {
            hostNames.set(group.hostId, group.hostDisplayName);
          }
        }
      }
    }
    const hostId = normalizeHostId(row.getAttribute("data-app-action-sidebar-thread-host-id") || "local");
    const hostContainer = row.closest('[role="listitem"][aria-label]');
    const hostDisplayName = hostContainer && !hostContainer.hasAttribute("data-sidebar-project-kind")
      ? hostContainer.getAttribute("aria-label") || null
      : null;
    const conversationKey = row.getAttribute("data-app-action-sidebar-thread-id") || "";
    const conversationId = rawConversationId(conversationKey);
    const title = row.getAttribute("data-app-action-sidebar-thread-title") || "Untitled task";
    const selected = row.getAttribute("data-app-action-sidebar-thread-selected") === "true";
    return { conversationId, conversationKey, cwd, hostDisplayName, hostId, hostNames, isGrouped, isProjectless, originalRow: row, projectId, projectLabel, selected, statusType, title, titleSource: title === "Untitled task" ? "none" : "native-dom", unread, unreadCount: nativeStatus?.statusState?.unreadCount ?? 0, nativeStatusState: nativeStatus?.statusState ?? null, needsAttention: nativeStatus?.needsAttention === true, attentionLabel: nativeStatus?.attentionLabel ?? null, attentionKind: nativeStatus?.attentionKind ?? null };
  }

  function commonAncestor(elements) {
    if (!elements.length) return null;
    let candidate = elements[0].parentElement;
    while (candidate && !elements.every((element) => candidate.contains(element))) {
      candidate = candidate.parentElement;
    }
    return candidate;
  }

  function nativeListContainer(rows, nativeProjectItems) {
    const elements = [...rows, ...nativeProjectItems]
      .filter((element) => element instanceof Element && !element.closest(`#${PANEL_ID}`));
    if (!elements.length) return null;
    const containsSidebarChrome = (candidate) => [...candidate.querySelectorAll('button,a,[role="button"]')].some((element) => {
      if (element.closest(`[data-sidebar-project-kind],${ROW_SELECTOR}`)) return false;
      // A native section's small New chat action belongs to that list, unlike
      // the global New chat/Explore navigation rows above all sections.
      if (element.closest('[class*="group/nav-section-title"]')) return false;
      const label = (element.getAttribute("aria-label") || element.textContent || "").replace(/\s+/gu, " ").trim();
      return label === "New chat" || label === "Explore";
    });
    const isSectionWrapper = (element, depth = 0) => {
      if (!(element instanceof Element) || depth > 8) return false;
      if (element.tagName === "SECTION") return true;
      if (!["DIV", "SPAN"].includes(element.tagName) || !element.children.length) return false;
      return [...element.children].every((child) => isSectionWrapper(child, depth + 1));
    };
    // Current packages keep Projects and Recents in sibling section wrappers.
    // Include the empty sibling too: task rows alone cannot discover its title.
    const section = elements[0].closest("section");
    if (section) {
      let candidate = section;
      while (isSectionWrapper(candidate.parentElement) && !containsSidebarChrome(candidate.parentElement)) {
        candidate = candidate.parentElement;
      }
      if (elements.every((element) => candidate.contains(element)) && !containsSidebarChrome(candidate)) return candidate;
    }
    // Older packages have one list without section wrappers. Keep the proven
    // common ancestor, but never replace the sidebar shell or global controls.
    const fallback = commonAncestor(elements);
    return fallback && !fallback.matches("body,nav,header") && !containsSidebarChrome(fallback) ? fallback : null;
  }

  function discoverHostNames() {
    if (!state.hostDiscoveryDirty && state.hostDiscoveryCache && Date.now() - state.hostDiscoveryScannedAt < 2000) return state.hostDiscoveryCache;
    state.counters.hostDiscoveryScans += 1;
    const names = new Map();
    const availability = new Map();
    const availabilitySeenAt = new Map();
    const authoritativeNames = new Map();
    const registeredProjects = new Map();
    const runtimes = new Map();
    const seen = new WeakSet();
    let budget = 24000;
    const scan = (value, depth = 0) => {
      if (!value || typeof value !== "object" || depth > 9 || seen.has(value) || value.nodeType || budget-- <= 0) return;
      seen.add(value);
      if (typeof value.queryClient?.invalidateQueries === "function") state.queryClient = value.queryClient;
      if (typeof value.invalidateQueries === "function" && typeof value.getQueryData === "function") state.queryClient = value;
      if (typeof value.projects?.removeRemote === "function") state.projectService = value.projects;
      if (typeof value.removeRemote === "function" && typeof value.createRemote === "function") state.projectService = value;
      if (typeof value.navigateToLocalConversation === "function" && typeof value.navigate === "function") state.navigationBridge = value;
      if (typeof value.getThreadSummaries === "function" && typeof value.activateThreadSummary === "function" && typeof value.getHostId === "function") {
        const managerHostId = normalizeHostId(value.getHostId());
        if (typeof managerHostId === "string") state.threadManagers.set(managerHostId, value);
      }
      const connectionHost = typeof value.host === "string" ? value.host : null;
      const hostId = value.hostId ?? value.host_id ?? value.environmentId ?? value.environment_id ?? connectionHost;
      const displayName = value.displayName ?? value.display_name ?? value.hostDisplayName ?? (connectionHost ? value.name : null);
      if (typeof hostId === "string" && /^(?:remote-control:)?env_/iu.test(hostId) && typeof displayName === "string" && !isSyntheticHostName(displayName)) {
        const normalizedHostId = hostId.startsWith("remote-control:") ? hostId : `remote-control:${hostId}`;
        names.set(normalizedHostId, displayName.trim());
        const explicitAvailability = typeof value.isAvailable === "boolean" ? value.isAvailable
          : typeof value.available === "boolean" ? value.available
          : typeof value.isOnline === "boolean" ? value.isOnline
          : typeof value.online === "boolean" ? value.online
          : typeof value.connected === "boolean" ? value.connected
          : typeof value.status === "string" ? /^(online|connected|ready|available|active)$/iu.test(value.status)
          : typeof value.state === "string" ? /^(online|connected|ready|available|active)$/iu.test(value.state)
          : null;
        if (explicitAvailability !== null) {
          const seenAtText = value.lastSeenAt ?? value.last_seen_at ?? value.updatedAt ?? value.updated_at;
          const seenAt = typeof seenAtText === "string" ? Date.parse(seenAtText) : Number.NaN;
          const currentSeenAt = availabilitySeenAt.get(normalizedHostId);
          if (currentSeenAt === undefined
            || (Number.isFinite(seenAt) && (!Number.isFinite(currentSeenAt) || seenAt >= currentSeenAt))
            || (!Number.isFinite(seenAt) && !Number.isFinite(currentSeenAt) && explicitAvailability === false)) {
            availability.set(normalizedHostId, explicitAvailability);
            availabilitySeenAt.set(normalizedHostId, seenAt);
          }
        }
      }
      if (typeof hostId === "string" && /^(?:remote-control:)?env_/iu.test(hostId)) {
        const normalizedHostId = hostId.startsWith("remote-control:") ? hostId : `remote-control:${hostId}`;
        const requestClient = typeof value.sendRequest === "function" ? value : value.requestClient;
        const fetchFromHost = typeof value.fetchFromHost === "function" ? value.fetchFromHost.bind(value) : null;
        if (typeof requestClient?.sendRequest === "function") {
          const previousRuntime = runtimes.get(normalizedHostId);
          runtimes.set(normalizedHostId, {
            fetchFromHost: fetchFromHost ?? previousRuntime?.fetchFromHost ?? null,
            requestClient,
          });
        }
      }
      if (hostId === "local") {
        const localRequestClient = typeof value.sendRequest === "function" ? value : value.requestClient;
        const localFetchFromHost = typeof value.fetchFromHost === "function"
          ? value.fetchFromHost.bind(value)
          : state.localFetchFromHost;
        if (typeof localFetchFromHost === "function") state.localFetchFromHost = localFetchFromHost;
        if (typeof localRequestClient?.sendRequest === "function") {
          assignLocalRuntime(localFetchFromHost, localRequestClient);
        }
      }
      if (Array.isArray(value.remoteProjects)) {
        for (const project of value.remoteProjects) {
          const projectHostId = typeof project?.hostId === "string" && project.hostId
            ? (project.hostId.startsWith("remote-control:") ? project.hostId : `remote-control:${project.hostId}`)
            : null;
          const projectId = typeof project?.id === "string" && project.id ? project.id : null;
          const cwd = typeof project?.remotePath === "string" && project.remotePath.trim() ? project.remotePath : null;
          if (!projectHostId || !projectId || !cwd) continue;
          registeredProjects.set(projectId, {
            cwd,
            hostDisplayName: null,
            hostId: projectHostId,
            item: null,
            label: typeof project.label === "string" && project.label.trim() ? project.label.trim() : projectName(cwd),
            projectId,
          });
        }
      }
      if (value instanceof Map) {
        let count = 0;
        for (const [key, item] of value) {
          if (count++ >= 1000) break;
          scan(key, depth + 1);
          scan(item, depth + 1);
        }
        return;
      }
      if (value instanceof Set) {
        let count = 0;
        for (const item of value) {
          if (count++ >= 1000) break;
          scan(item, depth + 1);
        }
        return;
      }
      for (const [key, item] of Object.entries(value).slice(0, 200)) {
        if (["alternate", "child", "return", "sibling", "stateNode"].includes(key)) continue;
        scan(item, depth + 1);
      }
    };
    const candidates = [...document.querySelectorAll(`${ROW_SELECTOR},[aria-label]`)];
    for (const element of candidates) {
      let fiber = getFiber(element);
      for (let level = 0; fiber && level < 80; level += 1, fiber = fiber.return) {
        const group = fiber.memoizedProps?.group;
        if (typeof group?.hostId === "string" && !isSyntheticHostName(group?.hostDisplayName)) {
          authoritativeNames.set(normalizeHostId(group.hostId), group.hostDisplayName);
        }
        scan(fiber.memoizedProps);
        scan(fiber.memoizedState);
        scan(fiber.updateQueue);
      }
      if (budget <= 0) break;
    }
    for (const [hostId, displayName] of authoritativeNames) names.set(hostId, displayName);
    for (const element of document.querySelectorAll('[data-sidebar-project-kind="remote"][role="listitem"]')) {
      let fiber = getFiber(element);
      for (let level = 0; fiber && level < 30; level += 1, fiber = fiber.return) {
        const group = fiber.memoizedProps?.group;
        if (group?.projectKind === "remote" && typeof group.hostId === "string" && !isSyntheticHostName(group.hostDisplayName)) {
          names.set(normalizeHostId(group.hostId), group.hostDisplayName);
          break;
        }
      }
    }
    const result = { names, availability, registeredProjects, runtimes };
    state.hostDiscoveryCache = result;
    state.hostDiscoveryDirty = false;
    state.hostDiscoveryScannedAt = Date.now();
    return result;
  }

  function discoverRemoteRuntimes(fallback) {
    const now = Date.now();
    const cacheTtl = state.remoteRuntimeCache.size ? 30000 : 2000;
    if (state.remoteRuntimeScannedAt && now - state.remoteRuntimeScannedAt < cacheTtl) return state.remoteRuntimeCache;
    const runtimes = new Map(fallback);
    state.counters.remoteRuntimeScans += 1;
    const anchor = document.querySelector(ROW_SELECTOR)
      ?? document.querySelector('[data-sidebar-project-kind][role="listitem"]');
    let root = anchor ? getFiber(anchor) : null;
    while (root?.return) root = root.return;
    const fibers = [];
    const seenFibers = new Set();
    const queue = root ? [root] : [];
    for (let queueIndex = 0; queueIndex < queue.length && fibers.length < 20000; queueIndex += 1) {
      const fiber = queue[queueIndex];
      if (!fiber || seenFibers.has(fiber)) continue;
      seenFibers.add(fiber);
      fibers.push(fiber);
      if (fiber.child) queue.push(fiber.child);
      if (fiber.sibling) queue.push(fiber.sibling);
    }
    const seen = new WeakSet();
    let budget = 500000;
    const scan = (value, depth = 0) => {
      if (!value || typeof value !== "object" || value.nodeType || value === globalThis || seen.has(value) || depth > 14 || budget-- <= 0) return;
      seen.add(value);
      if (typeof value.queryClient?.invalidateQueries === "function") state.queryClient = value.queryClient;
      if (typeof value.invalidateQueries === "function" && typeof value.getQueryData === "function") state.queryClient = value;
      if (typeof value.projects?.removeRemote === "function") state.projectService = value.projects;
      if (typeof value.removeRemote === "function" && typeof value.createRemote === "function") state.projectService = value;
      if (typeof value.navigateToLocalConversation === "function" && typeof value.navigate === "function") state.navigationBridge = value;
      if (typeof value.getThreadSummaries === "function" && typeof value.activateThreadSummary === "function" && typeof value.getHostId === "function") {
        const managerHostId = normalizeHostId(value.getHostId());
        if (typeof managerHostId === "string") state.threadManagers.set(managerHostId, value);
      }
      let keys;
      try { keys = Object.keys(value); } catch { return; }
      try {
        const hostId = typeof value.hostId === "string" ? value.hostId : null;
        const requestClient = typeof value.sendRequest === "function" ? value : value.requestClient;
        const fetchFromHost = typeof value.fetchFromHost === "function" ? value.fetchFromHost.bind(value) : null;
        if (hostId && /^(?:remote-control:)?env_/iu.test(hostId) && typeof requestClient?.sendRequest === "function") {
          const normalizedHostId = hostId.startsWith("remote-control:") ? hostId : `remote-control:${hostId}`;
          const previousRuntime = runtimes.get(normalizedHostId);
          runtimes.set(normalizedHostId, {
            fetchFromHost: fetchFromHost ?? previousRuntime?.fetchFromHost ?? null,
            requestClient,
          });
        }
        if (hostId === "local") {
          if (fetchFromHost) state.localFetchFromHost = fetchFromHost;
          if (typeof requestClient?.sendRequest === "function") {
            assignLocalRuntime(fetchFromHost ?? state.localFetchFromHost, requestClient);
          }
        }
      } catch {}
      if (Array.isArray(value)) {
        for (const item of value.slice(0, 200)) scan(item, depth + 1);
        return;
      }
      if (value instanceof Map) {
        let count = 0;
        for (const [key, item] of value) {
          if (count++ >= 1000) break;
          scan(key, depth + 1);
          scan(item, depth + 1);
        }
        return;
      }
      if (value instanceof Set) {
        let count = 0;
        for (const item of value) {
          if (count++ >= 1000) break;
          scan(item, depth + 1);
        }
        return;
      }
      for (const key of keys.slice(0, 400)) {
        if (["alternate", "child", "return", "sibling", "stateNode", "_owner"].includes(key)) continue;
        try { scan(value[key], depth + 1); } catch {}
      }
    };
    for (const fiber of fibers) {
      scan(fiber.memoizedProps);
      scan(fiber.memoizedState);
      scan(fiber.updateQueue);
      if (budget <= 0) break;
    }
    state.remoteRuntimeCache = runtimes;
    state.remoteRuntimeScannedAt = now;
    return runtimes;
  }

  function normalizePath(value) {
    return (canonicalRemotePath(value) ?? value).replace(/\\/gu, "/").replace(/\/+$/u, "").toLocaleLowerCase();
  }

  function normalizeHostId(hostId) {
    return typeof hostId === "string" && /^(?:remote-control:)?env_/iu.test(hostId)
      ? (hostId.startsWith("remote-control:") ? hostId : `remote-control:${hostId}`)
      : hostId;
  }

  function rawConversationId(value) {
    if (typeof value !== "string") return "";
    const match = value.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/iu);
    return match?.[1] ?? value;
  }

  function projectName(cwd) {
    if (!cwd) return "Unknown project";
    const cleaned = cwd.replace(/[\\/]+$/u, "");
    return cleaned.split(/[\\/]+/u).filter(Boolean).at(-1) || cwd;
  }

  function isDatedCodexScratchPath(cwd) {
    return typeof cwd === "string" && /[\\/]Documents[\\/]Codex[\\/]\d{4}-\d{2}-\d{2}[\\/][^\\/]+[\\/]*$/iu.test(cwd);
  }

  function canonicalRemotePath(cwd) {
    if (typeof cwd !== "string") return null;
    const value = cwd.trim().replace(/^\\\\\?\\UNC\\/iu, "\\\\").replace(/^\\\\\?\\/u, "").replace(/[\\/]+$/u, "");
    return value || null;
  }

  function parseRegisteredRemoteProjects(value) {
    const projects = new Map();
    for (const project of Array.isArray(value) ? value : []) {
      const hostId = normalizeHostId(project?.hostId);
      const projectId = typeof project?.id === "string" && project.id ? project.id : null;
      const cwd = canonicalRemotePath(project?.remotePath);
      if (!projectId || !cwd || typeof hostId !== "string" || hostId === "local") continue;
      projects.set(projectId, {
        cwd,
        hostDisplayName: null,
        hostId,
        item: null,
        label: typeof project.label === "string" && project.label.trim() ? project.label.trim() : projectName(cwd),
        projectId,
      });
    }
    return projects;
  }

  async function refreshLocalRegisteredProjects() {
    if (typeof state.localFetchFromHost !== "function") throw new Error("Local project-state bridge is unavailable");
    const result = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "remote-projects" } });
    const projects = parseRegisteredRemoteProjects(result?.value);
    state.localRegisteredProjects = projects;
    state.localRegisteredProjectsError = null;
    state.localRegisteredProjectsFetchedAt = Date.now();
    return projects;
  }

  function scheduleLocalRegisteredProjectsRefresh() {
    const now = Date.now();
    if (typeof state.localFetchFromHost !== "function" || state.localRegisteredProjectsPending || now - state.localRegisteredProjectsFetchedAt < LOCAL_REMOTE_PROJECTS_TTL_MS) return;
    state.localRegisteredProjectsPending = true;
    refreshLocalRegisteredProjects().catch((error) => {
      state.localRegisteredProjectsError = error?.message || String(error);
    }).finally(() => {
      state.localRegisteredProjectsPending = false;
      schedule();
    });
  }

  function registeredProjectMatches(projects, project) {
    if (!project?.cwd) return false;
    const path = normalizePath(project.cwd);
    return [...projects.values()].some((candidate) => candidate.hostId === normalizeHostId(project.hostId) && normalizePath(candidate.cwd) === path);
  }

  async function waitForRegisteredProject(project, timeoutMilliseconds = 15000) {
    const deadline = Date.now() + timeoutMilliseconds;
    while (Date.now() < deadline) {
      const projects = await refreshLocalRegisteredProjects();
      if (registeredProjectMatches(projects, project)) return true;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    throw new Error("Native remote-project registration was not persisted");
  }

  function isRemoteProjectInventoryPath(cwd) {
    const value = canonicalRemotePath(cwd);
    return Boolean(value && (/^[A-Za-z]:[\\/]/u.test(value) || /^\\\\[^\\/]+[\\/][^\\/]+/u.test(value) || /^\//u.test(value)));
  }

  function freshInventory(hostId) {
    const inventory = state.remoteProjectInventories.get(hostId);
    if (!inventory?.fetchedAt || inventory.error || !Number.isFinite(inventory.generatedAt)) return null;
    const now = Date.now();
    if (now - inventory.fetchedAt > REMOTE_INVENTORY_MAX_AGE_MS || now - inventory.generatedAt > REMOTE_INVENTORY_MAX_AGE_MS) return null;
    return inventory;
  }

  function inventoryMatchesLocal(inventory) {
    const localThreads = state.threadInventories.get("local");
    let threadsMatch = false;
    if (localThreads && !localThreads.error && inventory?.threadsAuthoritative === true) {
      const localIds = new Set((localThreads.threads ?? []).map((thread) => rawConversationId(thread?.id ?? thread?.conversationId ?? "")).filter(Boolean));
      const remoteIds = new Set((inventory.threads ?? []).map((thread) => rawConversationId(thread?.id ?? "")).filter(Boolean));
      threadsMatch = localIds.size > 0 && localIds.size === remoteIds.size && [...localIds].every((id) => remoteIds.has(id));
    }
    const localPaths = new Set(state.localInventoryProjects.map((project) => normalizePath(project.cwd)));
    const remotePaths = new Set((inventory?.projects ?? []).flatMap((project) => [project.cwd, ...(project.rootPaths ?? [])]).filter(Boolean).map(normalizePath));
    const pathsMatch = localPaths.size > 0 && localPaths.size === remotePaths.size && [...localPaths].every((path) => remotePaths.has(path));
    const localName = !isSyntheticHostName(config.localDisplayName) ? config.localDisplayName.trim().replace(/\.local$/iu, "").toLocaleLowerCase() : null;
    const inventoryName = !isSyntheticHostName(inventory?.hostDisplayName) ? inventory.hostDisplayName.trim().replace(/\.local$/iu, "").toLocaleLowerCase() : null;
    return threadsMatch && (pathsMatch || Boolean(localName && inventoryName === localName));
  }

  function removeRemoteHostState(hostId) {
    state.localRuntimeHostIds.add(hostId);
    state.remoteProjectInventories.delete(hostId);
    state.hostConnectivity.delete(hostId);
    state.remoteCodexHomes.delete(hostId);
    state.peerCacheStates.delete(hostId);
    state.threadInventories.delete(hostId);
    state.threadManagers.delete(hostId);
    state.verifiedThreadIds.delete(hostId);
    if (state.remoteRuntimeCache.delete(hostId)) state.remoteRuntimeScannedAt = 0;
  }

  function purgeLocalRuntimeAliases() {
    for (const hostId of state.localRuntimeHostIds) {
      state.remoteProjectInventories.delete(hostId);
      state.hostConnectivity.delete(hostId);
      state.remoteCodexHomes.delete(hostId);
      state.peerCacheStates.delete(hostId);
      state.threadInventories.delete(hostId);
      state.threadManagers.delete(hostId);
      state.verifiedThreadIds.delete(hostId);
      if (state.remoteRuntimeCache.delete(hostId)) state.remoteRuntimeScannedAt = 0;
    }
  }

  function remoteHostHasDirectProof(hostId) {
    if (state.hostConnectivity.get(hostId)?.available === true) return true;
    return typeof state.remoteRuntimeCache.get(hostId)?.requestClient?.sendRequest === "function";
  }

  function directInventoryHasPriority(hostId, inventory, now = Date.now()) {
    if (!remoteHostHasDirectProof(hostId) || !inventory) return false;
    if (inventory.pending === true) return true;
    if (inventory.error || inventory.sourcePeerHostId || inventory.sourcePeerCache === true) return false;
    return Number.isFinite(inventory.fetchedAt)
      && Number.isFinite(inventory.generatedAt)
      && now - inventory.fetchedAt <= REMOTE_INVENTORY_IDLE_TTL_MS
      && now - inventory.generatedAt <= REMOTE_INVENTORY_MAX_AGE_MS
      && inventory.generatedAt - now <= REMOTE_INVENTORY_FUTURE_SKEW_MS;
  }

  function removeGossipedLocalInventoryDuplicates() {
    for (const [hostId, inventory] of state.remoteProjectInventories) {
      if (inventory.sourcePeerHostId && !remoteHostHasDirectProof(hostId) && inventoryMatchesLocal(inventory)) removeRemoteHostState(hostId);
    }
  }

  function inventoryProjects() {
    const projects = [];
    for (const hostId of state.remoteProjectInventories.keys()) {
      const inventory = freshInventory(hostId);
      if (!inventory) continue;
      for (const project of inventory.projects ?? []) {
        projects.push({ ...project, hostId });
      }
    }
    return projects;
  }

  function remoteTaskState(hostId, conversationKey) {
    const inventory = freshInventory(hostId);
    return inventory?.tasks?.get(conversationKey) ?? null;
  }

  function remoteTaskStatusIsFresh(inventory, taskState, now = Date.now()) {
    if (!taskState?.statusType || taskState.statusKnown === false) return false;
    if (taskState.statusType !== "loading") return true;
    return Number.isFinite(inventory?.generatedAt)
      && now - inventory.generatedAt >= -REMOTE_INVENTORY_FUTURE_SKEW_MS
      && now - inventory.generatedAt <= REMOTE_TASK_STATUS_MAX_AGE_MS;
  }

  function applyRemoteTaskState(task, inventory, now = Date.now()) {
    const taskState = inventory?.tasks?.get(task.conversationKey) ?? inventory?.tasks?.get(task.conversationId) ?? null;
    if (!task.threadStatusKnown && remoteTaskStatusIsFresh(inventory, taskState, now)) task.statusType = taskState.statusType;
    if (taskState?.unreadKnown !== false && taskState) task.unread = taskState.unread;
    return taskState;
  }

  function authoritativeInventory(hostId) {
    const inventory = freshInventory(hostId);
    return inventory?.projectsAuthoritative === false ? null : inventory;
  }

  function directCompleteInventory(hostId) {
    const inventory = authoritativeInventory(hostId);
    if (!inventory || inventory.sourcePeerCache === true || inventory.sourcePeerHostId) return null;
    return inventory;
  }

  function preferredThreadInventory(existing, incoming) {
    const existingScopedAndFresh = scopedThreadsAreFresh(existing);
    return existingScopedAndFresh && !scopedThreadsAreFresh(incoming) ? existing : incoming;
  }

  function scopedThreadsAreFresh(inventory) {
    if (inventory?.threadScope !== "user-visible"
      || inventory?.threadsAuthoritative !== true
      || !Number.isInteger(inventory?.publisherVersion)
      || inventory.publisherVersion < THREAD_VISIBILITY_CONTRACT_VERSION) return false;
    const generatedAt = Number(inventory.threadScopeGeneratedAt ?? inventory.generatedAt);
    return Number.isFinite(generatedAt)
      && Date.now() - generatedAt <= REMOTE_INVENTORY_MAX_AGE_MS
      && generatedAt - Date.now() <= REMOTE_INVENTORY_FUTURE_SKEW_MS;
  }

  function inventoryContainsProject(inventory, project) {
    if (!inventory || !project?.cwd) return false;
    const path = normalizePath(project.cwd);
    return inventory.projects.some((candidate) => [candidate.cwd, ...(candidate.rootPaths ?? [])]
      .filter(Boolean)
      .some((cwd) => normalizePath(cwd) === path));
  }

  function findCodexHome(value) {
    const candidates = [];
    const seen = new WeakSet();
    const scan = (item, depth = 0) => {
      if (typeof item === "string") {
        const trimmed = item.trim();
        if (/[\\/]\.codex$/iu.test(trimmed)) candidates.unshift(trimmed);
        else if (/[\\/]\.codex[\\/]config\.toml$/iu.test(trimmed)) candidates.push(trimmed.replace(/[\\/]config\.toml$/iu, ""));
        return;
      }
      if (!item || typeof item !== "object" || depth > 10 || seen.has(item)) return;
      seen.add(item);
      for (const child of Array.isArray(item) ? item : Object.values(item)) scan(child, depth + 1);
    };
    scan(value);
    return candidates.find((candidate) => /^(?:[A-Za-z]:[\\/]|\/)/u.test(candidate)) ?? null;
  }

  function inventoryPath(codexHome) {
    const separator = codexHome.includes("\\") ? "\\" : "/";
    return `${codexHome.replace(/[\\/]+$/u, "")}${separator}${REMOTE_INVENTORY_FILENAME}`;
  }

  function peerInventorySlug(name) {
    return String(name || "device").normalize("NFKD").replace(/[^a-z0-9]+/giu, "").toLocaleLowerCase() || "device";
  }

  function peerInventoryPath(codexHome, name) {
    const separator = codexHome.includes("\\") ? "\\" : "/";
    return `${codexHome.replace(/[\\/]+$/u, "")}${separator}remote-project-peer-${peerInventorySlug(name)}-v1.json`;
  }

  function encodeText(value) {
    const bytes = new TextEncoder().encode(value);
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
    }
    return btoa(binary);
  }

  function decodeText(value) {
    const binary = atob(value);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  }

  function parseInventoryPayload(value, includePeers = false) {
    const generatedAt = Date.parse(value?.generatedAt);
    if (value?.schemaVersion !== 1 || !Number.isFinite(generatedAt)) throw new Error("Remote project inventory has an unsupported format");
    if (!Array.isArray(value.projects) || !Array.isArray(value.threads)) throw new Error("Remote project inventory is incomplete");
    if (Date.now() - generatedAt > REMOTE_INVENTORY_MAX_AGE_MS) throw new Error("Remote project inventory is stale");
    if (generatedAt - Date.now() > REMOTE_INVENTORY_FUTURE_SKEW_MS) throw new Error("Remote project inventory timestamp is in the future");
    const hostDisplayName = !isSyntheticHostName(value.hostDisplayName) ? value.hostDisplayName.trim() : null;
    const projectsTruncated = value.projects.length > 500;
    const entries = value.projects.slice(0, 500);
    const projects = new Map();
    for (const metadata of entries) {
      if (!metadata || typeof metadata !== "object" || !Array.isArray(metadata.rootPaths)) continue;
      const rootPaths = metadata.rootPaths.map(canonicalRemotePath).filter(isRemoteProjectInventoryPath);
      const cwd = rootPaths[0];
      if (!cwd) continue;
      const name = typeof metadata.name === "string" && metadata.name.trim()
        ? metadata.name.trim()
        : projectName(cwd);
      projects.set(normalizePath(cwd), { cwd, name, rootPaths, source: "host-projects" });
    }
    const tasks = new Map();
    const tasksTruncated = Array.isArray(value.tasks) && value.tasks.length > 2000;
    for (const metadata of Array.isArray(value.tasks) ? value.tasks.slice(0, 2000) : []) {
      if (!metadata || typeof metadata !== "object" || typeof metadata.conversationKey !== "string" || !metadata.conversationKey) continue;
      const unreadKnown = typeof metadata.unread === "boolean";
      const statusKnown = typeof metadata.statusType === "string";
      if (unreadKnown || statusKnown) tasks.set(metadata.conversationKey, {
        statusKnown,
        statusType: normalizeTaskStatus(metadata.statusType),
        unread: metadata.unread === true,
        unreadKnown,
      });
    }
    const threadsTruncated = Array.isArray(value.threads) && value.threads.length > 10000;
    const threadsAuthoritative = Array.isArray(value.threads) && !threadsTruncated;
    const publisherVersion = Number.isInteger(value.publisherVersion) ? value.publisherVersion : undefined;
    const threadScope = value.threadScope === "user-visible" ? "user-visible" : null;
    const threadScopeGeneratedAt = threadScope ? Date.parse(value.threadScopeGeneratedAt ?? value.generatedAt) : undefined;
    const threads = (Array.isArray(value.threads) ? value.threads : []).slice(0, 10000).flatMap((thread) => {
      const id = rawConversationId(thread?.id ?? "");
      if (!id) return [];
      const titleRecord = parsedThreadTitle(thread, publisherVersion);
      const parsedThread = {
        cwd: canonicalRemotePath(thread?.cwd),
        hasUnreadTurn: typeof thread?.hasUnreadTurn === "boolean" ? thread.hasUnreadTurn : undefined,
        id,
        projectId: typeof thread?.projectId === "string" ? thread.projectId : null,
        status: typeof thread?.status === "string" ? thread.status : thread?.status?.type,
        updatedAt: thread?.updatedAt ?? null,
        workspaceKind: typeof thread?.workspaceKind === "string" ? thread.workspaceKind : null,
      };
      if (Object.prototype.hasOwnProperty.call(thread ?? {}, "titleSource")) parsedThread.titleSource = thread.titleSource;
      if (titleRecord.title) parsedThread.title = titleRecord.title;
      return [parsedThread];
    });
    const peers = new Map();
    if (includePeers && value?.peers && typeof value.peers === "object" && !Array.isArray(value.peers)) {
      for (const [peerHostId, peerValue] of Object.entries(value.peers).slice(0, 20)) {
        try {
          const normalizedHostId = normalizeHostId(peerHostId);
          if (typeof normalizedHostId !== "string" || normalizedHostId === "local") continue;
          peers.set(normalizedHostId, parseInventoryPayload(peerValue, false));
        } catch {}
      }
    }
    return { generatedAt, hostDisplayName, peers, projects: [...projects.values()].sort((left, right) => left.name.localeCompare(right.name)), projectsAuthoritative: !projectsTruncated, projectsTruncated, publisherVersion, tasks, tasksTruncated, threadScope, threadScopeGeneratedAt, threads, threadsAuthoritative, threadsTruncated };
  }

  function serializePeerInventory(inventory) {
    const payload = {
      generatedAt: new Date(inventory.generatedAt).toISOString(),
      hostDisplayName: inventory.hostDisplayName,
      projects: (inventory.projects ?? []).map((project) => ({
        name: project.name,
        rootPaths: [...new Set([...(project.rootPaths ?? []), project.cwd].filter(Boolean))],
      })),
      publisherVersion: inventory.publisherVersion,
      schemaVersion: 1,
      tasks: [...(inventory.tasks ?? new Map())].map(([conversationKey, task]) => ({ conversationKey, statusType: task.statusType, unread: task.unread })),
      threadScope: inventory.threadScope,
      threads: inventory.threads ?? [],
    };
    const threadScopeGeneratedAt = Number(inventory.threadScopeGeneratedAt ?? inventory.generatedAt);
    if (inventory.threadScope === "user-visible" && Number.isFinite(threadScopeGeneratedAt)) {
      payload.threadScopeGeneratedAt = new Date(threadScopeGeneratedAt).toISOString();
    }
    return payload;
  }

  function parseRemoteProjectInventory(result) {
    if (typeof result?.dataBase64 !== "string") throw new Error("Remote project inventory did not contain file data");
    if (result.dataBase64.length > 16 * 1024 * 1024) throw new Error("Remote project inventory exceeded the safe size limit");
    return parseInventoryPayload(JSON.parse(decodeText(result.dataBase64)), true);
  }

  function scheduleRemoteProjectInventory(runtimes) {
    if (state.disposed) return;
    const now = Date.now();
    for (const hostId of new Set([...state.remoteProjectInventories.keys(), ...state.hostConnectivity.keys()])) {
      if (!runtimes.has(hostId)) state.hostConnectivity.set(hostId, { available: false, checkedAt: now });
    }
    for (const [hostId, inventory] of state.remoteProjectInventories) {
      if (!runtimes.has(hostId) && (!inventory.generatedAt || now - inventory.generatedAt > REMOTE_INVENTORY_MAX_AGE_MS)) {
        state.remoteProjectInventories.delete(hostId);
        state.remoteCodexHomes.delete(hostId);
      }
    }
    for (const [hostId, runtime] of runtimes) {
      const current = state.remoteProjectInventories.get(hostId) ?? { projects: [], tasks: new Map(), threads: [] };
      const refreshTtl = current.tasks?.size ? REMOTE_INVENTORY_ACTIVE_TTL_MS : REMOTE_INVENTORY_IDLE_TTL_MS;
      if (current.pending || current.retryAt > now || current.fetchedAt && now - current.fetchedAt < refreshTtl) continue;
      if (typeof runtime?.requestClient?.sendRequest !== "function") continue;
      state.remoteProjectInventories.set(hostId, { ...current, pending: true });
      let connectionProven = false;
      const resolveCodexHome = state.remoteCodexHomes.has(hostId)
        ? Promise.resolve(state.remoteCodexHomes.get(hostId))
        : sendRequestWithTimeout(runtime.requestClient, "config/read", { cwd: null, includeLayers: true }).then((configResult) => {
          connectionProven = true;
          const codexHome = findCodexHome(configResult);
          if (!codexHome) throw new Error("Remote Codex home was not reported");
          state.remoteCodexHomes.set(hostId, codexHome);
          return codexHome;
        });
      resolveCodexHome.then((codexHome) => sendRequestWithTimeout(runtime.requestClient, "fs/readFile", { path: inventoryPath(codexHome) })).then((result) => {
        if (state.disposed) return;
        connectionProven = true;
        const parsed = parseRemoteProjectInventory(result);
        state.hostConnectivity.set(hostId, { available: true, checkedAt: Date.now() });
        const latest = state.remoteProjectInventories.get(hostId);
        if (Number.isFinite(latest?.generatedAt) && latest.generatedAt > parsed.generatedAt && latest.error == null && !latest.sourcePeerHostId && latest.sourcePeerCache !== true) {
          state.remoteProjectInventories.set(hostId, { ...latest, pending: false, retryAt: 0 });
          return;
        }
        const threadInventory = preferredThreadInventory(latest, parsed);
        state.remoteProjectInventories.set(hostId, {
          error: null,
          fetchedAt: Date.now(),
          generatedAt: parsed.generatedAt,
          hostDisplayName: parsed.hostDisplayName,
          pending: false,
          projects: parsed.projects,
          projectsAuthoritative: parsed.projectsAuthoritative,
          projectsTruncated: parsed.projectsTruncated,
          publisherVersion: threadInventory?.publisherVersion,
          retryAt: 0,
          tasks: parsed.tasks,
          tasksTruncated: parsed.tasksTruncated,
          threads: threadInventory?.threads ?? [],
          threadsAuthoritative: threadInventory?.threadsAuthoritative === true,
          threadScope: threadInventory?.threadScope ?? null,
          threadScopeGeneratedAt: threadInventory?.threadScope === "user-visible" ? (threadInventory.threadScopeGeneratedAt ?? threadInventory.generatedAt) : undefined,
          threadsTruncated: threadInventory?.threadsTruncated === true,
        });
        for (const [peerHostId, peer] of parsed.peers) {
          if (peerHostId === hostId) continue;
          if (inventoryMatchesLocal(peer)) {
            if (!remoteHostHasDirectProof(peerHostId)) removeRemoteHostState(peerHostId);
            continue;
          }
          const existing = state.remoteProjectInventories.get(peerHostId);
          if (directInventoryHasPriority(peerHostId, existing)) continue;
          if (Number.isFinite(existing?.generatedAt) && existing.generatedAt >= peer.generatedAt && existing.error == null) continue;
          const threadInventory = preferredThreadInventory(existing, peer);
          state.remoteProjectInventories.set(peerHostId, {
            error: null,
            fetchedAt: Date.now(),
            generatedAt: peer.generatedAt,
            hostDisplayName: peer.hostDisplayName,
            pending: false,
            projects: peer.projects,
            projectsAuthoritative: peer.projectsAuthoritative,
            projectsTruncated: peer.projectsTruncated,
            publisherVersion: threadInventory?.publisherVersion,
            retryAt: existing?.retryAt ?? 0,
            sourcePeerHostId: hostId,
            tasks: peer.tasks,
            tasksTruncated: peer.tasksTruncated,
            threads: threadInventory?.threads ?? [],
            threadsAuthoritative: threadInventory?.threadsAuthoritative === true,
            threadScope: threadInventory?.threadScope ?? null,
            threadScopeGeneratedAt: threadInventory?.threadScope === "user-visible" ? (threadInventory.threadScopeGeneratedAt ?? threadInventory.generatedAt) : undefined,
            threadsTruncated: threadInventory?.threadsTruncated === true,
          });
        }
        removeGossipedLocalInventoryDuplicates();
      }).catch((error) => {
        if (state.disposed) return;
        state.remoteRuntimeCache.delete(hostId);
        state.remoteRuntimeScannedAt = 0;
        if (connectionProven) state.hostConnectivity.set(hostId, { available: true, checkedAt: Date.now() });
        else state.hostConnectivity.delete(hostId);
        state.remoteCodexHomes.delete(hostId);
        const latest = state.remoteProjectInventories.get(hostId);
        if (latest?.sourcePeerCache && freshInventory(hostId)) {
          state.remoteProjectInventories.set(hostId, { ...latest, pending: false, retryAt: Date.now() + REMOTE_INVENTORY_RETRY_MS });
          return;
        }
        state.remoteProjectInventories.set(hostId, {
          error: error?.message || String(error),
          fetchedAt: latest?.fetchedAt ?? 0,
          generatedAt: latest?.generatedAt,
          hostDisplayName: latest?.hostDisplayName ?? current.hostDisplayName,
          pending: false,
          projects: latest?.projects ?? current.projects ?? [],
          publisherVersion: latest?.publisherVersion ?? current.publisherVersion,
          retryAt: Date.now() + REMOTE_INVENTORY_RETRY_MS,
          sourcePeerCache: latest?.sourcePeerCache === true,
          sourcePeerHostId: latest?.sourcePeerHostId,
          tasks: latest?.tasks ?? current.tasks ?? new Map(),
          threads: latest?.threads ?? current.threads ?? [],
          threadsAuthoritative: latest?.threadsAuthoritative === true || current.threadsAuthoritative === true,
          threadScope: latest?.threadScope ?? current.threadScope ?? null,
          threadScopeGeneratedAt: latest?.threadScopeGeneratedAt ?? current.threadScopeGeneratedAt ?? latest?.generatedAt ?? current.generatedAt,
        });
      }).finally(() => { if (!state.disposed) schedule(); });
    }
  }

  function pushLocalInventoryToPeers(dataBase64) {
    const discovery = discoverHostNames();
    const runtimes = discoverRemoteRuntimes(discovery.runtimes);
    for (const [hostId, runtime] of runtimes) {
      if (typeof runtime?.requestClient?.sendRequest !== "function") continue;
      const resolveCodexHome = state.remoteCodexHomes.has(hostId)
        ? Promise.resolve(state.remoteCodexHomes.get(hostId))
        : sendRequestWithTimeout(runtime.requestClient, "config/read", { cwd: null, includeLayers: true }).then((configResult) => {
          const codexHome = findCodexHome(configResult);
          if (!codexHome) throw new Error("Remote Codex home was not reported");
          state.remoteCodexHomes.set(hostId, codexHome);
          return codexHome;
        });
      void resolveCodexHome
        .then((codexHome) => sendRequestWithTimeout(runtime.requestClient, "fs/writeFile", {
          dataBase64,
          path: peerInventoryPath(codexHome, config.localDisplayName || "Local"),
        }))
        .catch(() => {});
    }
  }

  function scheduleLocalPeerCacheInventory(hosts) {
    const runtime = state.localRuntime;
    if (!state.localCodexHome || typeof runtime?.requestClient?.sendRequest !== "function") return;
    const now = Date.now();
    for (const host of hosts) {
      if (host.id === "local") continue;
      const cache = state.peerCacheStates.get(host.id) ?? {};
      if (cache.pending || cache.fetchedAt && now - cache.fetchedAt < REMOTE_INVENTORY_IDLE_MS) continue;
      state.peerCacheStates.set(host.id, { ...cache, pending: true });
      sendRequestWithTimeout(runtime.requestClient, "fs/readFile", { path: peerInventoryPath(state.localCodexHome, host.name) }).then((result) => {
        if (state.disposed) return;
        const parsed = parseRemoteProjectInventory(result);
        const existing = state.remoteProjectInventories.get(host.id);
        if (!directInventoryHasPriority(host.id, existing)
          && (!Number.isFinite(existing?.generatedAt)
          || parsed.generatedAt >= existing.generatedAt
          || Date.now() - existing.generatedAt > REMOTE_INVENTORY_MAX_AGE_MS)) {
          const threadInventory = preferredThreadInventory(existing, parsed);
          state.remoteProjectInventories.set(host.id, {
            error: null,
            fetchedAt: Date.now(),
            generatedAt: parsed.generatedAt,
            hostDisplayName: parsed.hostDisplayName,
            pending: false,
            projects: parsed.projects,
            projectsAuthoritative: parsed.projectsAuthoritative,
            projectsTruncated: parsed.projectsTruncated,
            publisherVersion: threadInventory?.publisherVersion,
            retryAt: existing?.retryAt ?? 0,
            sourcePeerCache: true,
            tasks: parsed.tasks,
            tasksTruncated: parsed.tasksTruncated,
            threads: threadInventory?.threads ?? [],
            threadsAuthoritative: threadInventory?.threadsAuthoritative === true,
            threadScope: threadInventory?.threadScope ?? null,
            threadScopeGeneratedAt: threadInventory?.threadScope === "user-visible" ? (threadInventory.threadScopeGeneratedAt ?? threadInventory.generatedAt) : undefined,
            threadsTruncated: threadInventory?.threadsTruncated === true,
          });
        }
        state.peerCacheStates.set(host.id, { error: null, fetchedAt: Date.now(), pending: false });
      }).catch((error) => {
        state.peerCacheStates.set(host.id, { error: error?.message || String(error), fetchedAt: Date.now(), pending: false });
      }).finally(() => { if (!state.disposed) schedule(); });
    }
  }

  function publishedLocalProjectSnapshot(projectsResult) {
    const stateProjectsAvailable = Boolean(projectsResult?.value
      && typeof projectsResult.value === "object"
      && !Array.isArray(projectsResult.value));
    const nativeItems = [...document.querySelectorAll('[data-sidebar-project-kind="local"][role="listitem"]')];
    const projects = new Map();
    const pathOwners = new Map();
    const addProject = (project, preferMetadata = false) => {
      if (!project || typeof project !== "object") return;
      const rawPaths = Array.isArray(project.rootPaths) ? project.rootPaths : [project.cwd];
      const rootPaths = [...new Set(rawPaths.map(canonicalRemotePath).filter(Boolean))];
      if (!rootPaths.length) return;
      const requestedId = typeof project.id === "string" && project.id
        ? project.id
        : typeof project.projectId === "string" && project.projectId
          ? project.projectId
          : `local-path:${normalizePath(rootPaths[0])}`;
      const existingId = projects.has(requestedId)
        ? requestedId
        : rootPaths.map((cwd) => pathOwners.get(normalizePath(cwd))).find(Boolean);
      const id = existingId ?? requestedId;
      const existing = projects.get(id);
      const name = typeof project.name === "string" && project.name.trim()
        ? project.name.trim()
        : typeof project.label === "string" && project.label.trim()
          ? project.label.trim()
          : projectName(rootPaths[0]);
      const mergedPaths = [...new Set([...(existing?.rootPaths ?? []), ...rootPaths])];
      projects.set(id, {
        id,
        name: preferMetadata || !existing?.name ? name : existing.name,
        rootPaths: mergedPaths,
      });
      for (const cwd of mergedPaths) pathOwners.set(normalizePath(cwd), id);
    };
    if (stateProjectsAvailable) {
      for (const project of Object.values(projectsResult.value)) addProject(project);
    }
    for (const item of nativeItems) {
      const project = metadataFromNativeProject(item);
      if (!project || project.hostId !== "local") continue;
      addProject({ cwd: project.cwd, id: project.projectId, name: project.label }, true);
    }
    return {
      available: stateProjectsAvailable || nativeItems.length > 0,
      projects: [...projects.values()],
    };
  }

  function scheduleLocalProjectInventoryPublication() {
    const runtime = state.localRuntime;
    const now = Date.now();
    const currentThreadInventory = state.threadInventories.get("local");
    if (!runtime
      || state.disposed
      || state.localInventoryPublisherPending
      || !currentThreadInventory
      || currentThreadInventory.truncated === true
      || !Array.isArray(currentThreadInventory.threads)
      || !Number.isFinite(currentThreadInventory.fetchedAt)) return;
    const localThreadsById = new Map((currentThreadInventory.threads ?? []).flatMap((thread) => {
      const id = rawConversationId(thread?.id ?? thread?.conversationId ?? "");
      return id ? [[id, thread]] : [];
    }));
    const tasks = [...document.querySelectorAll(ROW_SELECTOR)]
      .filter((row) => !row.closest(`#${PANEL_ID}`))
      .map(metadataFromRow)
      .filter((task) => task.hostId === "local")
      .map((task) => publishedTaskMetadata(task, localThreadsById.get(task.conversationId)));
    const threads = (state.threadInventories.get("local")?.threads ?? []).flatMap((thread) => {
      const id = rawConversationId(thread?.id ?? thread?.conversationId ?? "");
      if (!id) return [];
      const titleRecord = publishedThreadTitle(thread, id);
      const publishedThread = {
        cwd: canonicalRemotePath(thread?.cwd),
        hasUnreadTurn: thread?.hasUnreadTurn === true,
        id,
        projectId: typeof thread?.projectId === "string" ? thread.projectId : null,
        status: typeof thread?.status === "string" ? thread.status : thread?.status?.type,
        titleSource: titleRecord.titleSource,
        updatedAt: thread?.updatedAt ?? null,
        workspaceKind: typeof thread?.workspaceKind === "string" ? thread.workspaceKind : null,
      };
      if (titleRecord.title) publishedThread.title = titleRecord.title;
      return [publishedThread];
    });
    const peers = Object.fromEntries([...state.remoteProjectInventories].flatMap(([hostId]) => {
      const inventory = freshInventory(hostId);
      if (!inventory || inventory.threadsAuthoritative !== true) return [];
      return [[hostId, serializePeerInventory(inventory)]];
    }));
    const localThreadInventory = state.threadInventories.get("local");
    const nativeProjectSnapshot = publishedLocalProjectSnapshot(null);
    const statusSignature = JSON.stringify({
      peers: Object.fromEntries(Object.entries(peers).map(([hostId, peer]) => [hostId, {
        generatedAt: peer.generatedAt,
        publisherVersion: peer.publisherVersion,
        threads: peer.threads.map((thread) => ({ id: thread.id, title: thread.title ?? null, titleSource: thread.titleSource })),
      }])),
      projects: nativeProjectSnapshot.projects,
      tasks,
      threads: threads.map((thread) => ({ id: thread.id, title: thread.title ?? null, titleSource: thread.titleSource })),
      threadFetchedAt: localThreadInventory?.fetchedAt ?? 0,
    });
    const publishInterval = tasks.length ? REMOTE_INVENTORY_ACTIVE_MS : REMOTE_INVENTORY_IDLE_MS;
    const statusChanged = statusSignature !== state.localInventoryStatusSignature;
    if (!statusChanged && now - state.localInventoryPublishedAt < publishInterval) return;
    state.localInventoryPublisherPending = true;
    Promise.all([
      typeof runtime.fetchFromHost === "function"
        ? fetchFromHostWithTimeout(runtime.fetchFromHost, "get-global-state", { params: { key: "local-projects" } })
        : Promise.resolve(null),
      sendRequestWithTimeout(runtime.requestClient, "config/read", { cwd: null, includeLayers: true }),
    ]).then(([projectsResult, configResult]) => {
      const codexHome = findCodexHome(configResult);
      if (!codexHome) throw new Error("Local Codex home was not reported");
      state.localCodexHome = codexHome;
      const projectSnapshot = publishedLocalProjectSnapshot(projectsResult);
      if (!projectSnapshot.available) throw new Error("Local project catalogue is not available yet");
      const projects = projectSnapshot.projects;
      state.localInventoryProjects = projects.flatMap((project) => project.rootPaths.map((cwd) => ({
        cwd,
        hostDisplayName: null,
        hostId: "local",
        item: null,
        label: project.name,
        projectId: project.id,
        rootPaths: project.rootPaths,
      }))).filter((project) => project.projectId && project.cwd);
      removeGossipedLocalInventoryDuplicates();
      const generatedAt = new Date().toISOString();
      const threadScopeGeneratedAt = new Date(currentThreadInventory.fetchedAt).toISOString();
      const payload = JSON.stringify({ generatedAt, hostDisplayName: config.localDisplayName || null, peers, projects, publisherVersion: PUBLISHER_VERSION, schemaVersion: 1, tasks, threadScope: "user-visible", threadScopeGeneratedAt, threads });
      const dataBase64 = encodeText(payload);
      return sendRequestWithTimeout(runtime.requestClient, "fs/writeFile", { dataBase64, path: inventoryPath(codexHome) })
        .then(() => pushLocalInventoryToPeers(dataBase64));
    }).then(() => {
      if (state.disposed) return;
      state.localInventoryPublishedAt = Date.now();
      state.localInventoryStatusSignature = statusSignature;
      state.localInventoryPublisherError = null;
    }).catch((error) => {
      if (state.disposed) return;
      state.localInventoryPublisherError = error?.message || String(error);
    }).finally(() => {
      if (state.disposed) return;
      state.localInventoryPublisherPending = false;
      if (state.localInventoryPublisherTimer === null) {
        const nextInterval = tasks.length ? REMOTE_INVENTORY_ACTIVE_MS : REMOTE_INVENTORY_IDLE_MS;
        state.localInventoryPublisherTimer = setTimeout(() => {
          state.localInventoryPublisherTimer = null;
          schedule();
        }, nextInterval);
      }
      schedule();
    });
  }

  function isRecentTask(task) {
    if (!task.cwd || task.isProjectless === true) return true;
    if (task.hostId === "local") return !task.projectId || task.isGrouped === false;
    return isDatedCodexScratchPath(task.cwd);
  }

  function isSyntheticHostName(value) {
    return typeof value !== "string" || !value.trim() || /^(?:Remote\s+)?(?:remote-control:)?env_/iu.test(value.trim());
  }

  function hostNameAliases(hostId) {
    const normalized = normalizeHostId(hostId);
    const short = typeof normalized === "string" ? normalized.replace(/^remote-control:/u, "") : normalized;
    return [...new Set([normalized, hostId, short].filter((value) => typeof value === "string" && value))];
  }

  function configuredHostName(hostId) {
    for (const alias of hostNameAliases(hostId)) {
      const value = config.hostDisplayNames?.[alias];
      if (!isSyntheticHostName(value)) return value.trim();
    }
    return null;
  }

  function hostName(hostId, discoveredNames, singleRemoteHostId) {
    if (hostId === "local") return config.localDisplayName || "Local";
    const normalizedHostId = normalizeHostId(hostId);
    const aliases = hostNameAliases(normalizedHostId);
    const discovered = aliases.map((alias) => discoveredNames.get(alias)).find((value) => !isSyntheticHostName(value));
    const remembered = readRecords(HOST_NAMES_KEY);
    if (!isSyntheticHostName(discovered)) {
      if (remembered[normalizedHostId] !== discovered) {
        remembered[normalizedHostId] = discovered;
        writeRecords(HOST_NAMES_KEY, remembered);
      }
      return discovered;
    }
    const rememberedName = aliases.map((alias) => remembered[alias]).find((value) => !isSyntheticHostName(value));
    if (rememberedName) {
      if (remembered[normalizedHostId] !== rememberedName) {
        remembered[normalizedHostId] = rememberedName;
        writeRecords(HOST_NAMES_KEY, remembered);
      }
      return rememberedName;
    }
    const configured = configuredHostName(normalizedHostId);
    if (configured) {
      remembered[normalizedHostId] = configured;
      writeRecords(HOST_NAMES_KEY, remembered);
      return configured;
    }
    if (normalizedHostId === normalizeHostId(singleRemoteHostId) && !isSyntheticHostName(config.singleRemoteDisplayName)) {
      remembered[normalizedHostId] = config.singleRemoteDisplayName.trim();
      writeRecords(HOST_NAMES_KEY, remembered);
      return remembered[normalizedHostId];
    }
    return "Remote device";
  }

  function metadataFromNativeProject(item) {
    let fiber = getFiber(item);
    for (let level = 0; fiber && level < 30; level += 1, fiber = fiber.return) {
      const group = fiber.memoizedProps?.group;
      if (!group || !["local", "remote"].includes(group.projectKind)) continue;
      if (typeof group.projectId !== "string" || !group.projectId) continue;
      const hostId = group.projectKind === "remote" && typeof group.hostId === "string" && group.hostId
        ? normalizeHostId(group.hostId)
        : "local";
      const label = typeof group.label === "string" && group.label.trim()
        ? group.label.trim()
        : item.getAttribute("aria-label") || "Unknown project";
      const rawPaths = [group.path, group.cwd, group.rootPath, ...(Array.isArray(group.rootPaths) ? group.rootPaths : [])];
      const cwd = rawPaths.find((path) => typeof path === "string" && path.trim()) ?? null;
      const hostDisplayName = typeof group.hostDisplayName === "string" && group.hostDisplayName.trim()
        ? group.hostDisplayName.trim()
        : null;
      return { cwd, hostDisplayName, hostId, item, label, projectId: group.projectId };
    }
    return null;
  }

  function taskFromThread(thread, hostId) {
    const conversationId = rawConversationId(thread?.id ?? thread?.conversationId ?? "");
    if (!conversationId) return null;
    const cwd = canonicalRemotePath(thread?.cwd ?? thread?.workingDirectory ?? thread?.workspace?.cwd);
    const projectId = typeof thread?.projectId === "string" ? thread.projectId
      : typeof thread?.project_id === "string" ? thread.project_id
      : typeof thread?.project?.id === "string" ? thread.project.id
      : null;
    const runtimeStatus = typeof thread?.status === "string" ? thread.status : thread?.status?.type;
    const statusKnown = typeof runtimeStatus === "string" && runtimeStatus.length > 0;
    const unreadKnown = typeof thread?.hasUnreadTurn === "boolean" || typeof thread?.unread === "boolean";
    const titleRecord = trustedThreadTitle(thread);
    return {
      conversationId,
      conversationKey: conversationId,
      cwd,
      hostDisplayName: null,
      hostId,
      hostNames: new Map(),
      isGrouped: Boolean(projectId || cwd),
      isProjectless: thread?.projectless === true || thread?.workspaceKind === "projectless" || !cwd,
      originalRow: null,
      projectId,
      projectLabel: typeof thread?.projectLabel === "string" ? thread.projectLabel : null,
      selected: false,
      sourceThread: thread,
      directStatusKnown: false,
      threadStatusKnown: statusKnown,
      statusKnown,
      statusType: normalizeTaskStatus(runtimeStatus),
      title: titleRecord.title ?? "Untitled task",
      titleSource: titleRecord.titleSource,
      unread: thread?.hasUnreadTurn === true || thread?.unread === true,
      unreadKnown,
    };
  }

  function collectAuthoritativeThreadIds() {
    pruneVerifiedThreadIds();
    const authoritativeIds = new Map();
    const directAuthoritativeHosts = new Set();
    for (const [hostId, record] of state.verifiedThreadIds) authoritativeIds.set(hostId, new Set(record.ids));
    for (const [hostId, inventory] of state.threadInventories) {
      if (!inventory.error) {
        authoritativeIds.set(hostId, new Set((inventory.threads ?? []).map((thread) => rawConversationId(thread?.id ?? thread?.conversationId ?? "")).filter(Boolean)));
        directAuthoritativeHosts.add(hostId);
      }
    }
    for (const [hostId] of state.remoteProjectInventories) {
      const inventory = freshInventory(hostId);
      if (!directAuthoritativeHosts.has(hostId) && scopedThreadsAreFresh(inventory)) {
        authoritativeIds.set(hostId, new Set(inventory.threads.map((thread) => rawConversationId(thread?.id ?? "")).filter(Boolean)));
      }
    }
    return authoritativeIds;
  }

  function taskIsAuthoritative(task, authoritativeIds) {
    return Boolean(task?.conversationId
      && authoritativeIds.has(task.hostId)
      && authoritativeIds.get(task.hostId).has(task.conversationId));
  }

  function collectModel() {
    purgeLocalRuntimeAliases();
    const rows = [...document.querySelectorAll(ROW_SELECTOR)].filter((row) => !row.closest(`#${PANEL_ID}`));
    const authoritativeIds = collectAuthoritativeThreadIds();
    const taskMap = new Map();
    for (const task of rows.map(metadataFromRow).filter((task) => task.conversationId)) {
      if (!taskIsAuthoritative(task, authoritativeIds)) continue;
      taskMap.set(`${task.hostId}::${task.conversationId}`, task);
    }
    for (const [hostId, inventory] of state.threadInventories) {
      if (inventory.error) continue;
      for (const thread of inventory.threads ?? []) {
        const task = taskFromThread(thread, hostId);
        if (!task) continue;
        task.directStatusKnown = task.statusKnown;
        const key = `${hostId}::${task.conversationId}`;
        const nativeTask = taskMap.get(key);
        if (nativeTask) {
          if (task.cwd) nativeTask.cwd = task.cwd;
          if (task.projectId) nativeTask.projectId = task.projectId;
          if (task.projectLabel) nativeTask.projectLabel = task.projectLabel;
          nativeTask.sourceThread = thread;
          mergeTaskTitle(nativeTask, task);
          if (task.statusKnown) {
            nativeTask.directStatusKnown = true;
            nativeTask.threadStatusKnown = true;
            nativeTask.statusType = task.statusType;
          }
          if (task.unreadKnown) nativeTask.unread = task.unread;
        } else {
          taskMap.set(key, task);
        }
      }
    }
    for (const [hostId] of state.remoteProjectInventories) {
      const inventory = freshInventory(hostId);
      if (!authoritativeIds.has(hostId)) continue;
      for (const thread of inventory?.threads ?? []) {
        const task = taskFromThread(thread, hostId);
        if (!task) continue;
        if (task.statusType === "loading" && !remoteTaskStatusIsFresh(inventory, { statusKnown: true, statusType: "loading" })) {
          task.statusKnown = false;
          task.threadStatusKnown = false;
          task.statusType = "idle";
        }
        if (authoritativeIds.has(hostId) && !authoritativeIds.get(hostId).has(task.conversationId)) continue;
        const key = `${hostId}::${task.conversationId}`;
        const existing = taskMap.get(key);
        if (existing) {
          if (task.cwd) existing.cwd = task.cwd;
          if (task.projectId) existing.projectId = task.projectId;
          existing.sourceThread = thread;
          mergeTaskTitle(existing, task);
          if (task.statusKnown && !existing.directStatusKnown) {
            existing.statusType = task.statusType;
            existing.threadStatusKnown = true;
          }
          if (task.unreadKnown) existing.unread = task.unread;
        } else {
          taskMap.set(key, task);
        }
      }
    }
    const tasks = [...taskMap.values()];
    const remoteInventoryProjects = inventoryProjects();
    const authoritativeProjectPaths = new Map();
    if (state.localInventoryPublishedAt > 0
      && !state.localInventoryPublisherError
      && Date.now() - state.localInventoryPublishedAt <= REMOTE_INVENTORY_MAX_AGE_MS) {
      authoritativeProjectPaths.set("local", new Set(state.localInventoryProjects.map((project) => normalizePath(project.cwd))));
    }
    for (const [hostId] of state.remoteProjectInventories) {
      if (directCompleteInventory(hostId)) authoritativeProjectPaths.set(hostId, new Set());
    }
    for (const project of remoteInventoryProjects) {
      if (!authoritativeProjectPaths.has(project.hostId)) authoritativeProjectPaths.set(project.hostId, new Set());
      for (const cwd of [project.cwd, ...(project.rootPaths ?? [])].filter(Boolean)) {
        authoritativeProjectPaths.get(project.hostId).add(normalizePath(cwd));
      }
    }
    const projectIsAuthoritative = (project) => {
      const paths = authoritativeProjectPaths.get(project.hostId);
      if (!paths || paths.size === 0 || !project.cwd) return true;
      return paths.has(normalizePath(project.cwd));
    };
    const domNativeProjects = [...document.querySelectorAll('[data-sidebar-project-kind][role="listitem"]')]
      .map(metadataFromNativeProject)
      .filter((project) => project && !state.localRuntimeHostIds.has(project.hostId) && projectIsAuthoritative(project));
    const hostDiscovery = discoverHostNames();
    const nativeProjects = [...domNativeProjects];
    const nativeProjectIds = new Set(nativeProjects.map((project) => project.projectId));
    for (const project of [...hostDiscovery.registeredProjects.values(), ...state.localRegisteredProjects.values()]) {
      if (!projectIsAuthoritative(project)) continue;
      if (!nativeProjectIds.has(project.projectId)) nativeProjects.push(project);
      nativeProjectIds.add(project.projectId);
    }
    for (const project of state.localInventoryProjects) {
      if (!nativeProjectIds.has(project.projectId)) nativeProjects.push(project);
      nativeProjectIds.add(project.projectId);
    }
    for (const task of tasks) {
      if (task.hostId === "local") continue;
      const inventory = authoritativeInventory(task.hostId);
      if (!inventory) {
        task.unread = task.unread && !remoteUnreadAcknowledged(task, null);
        continue;
      }
      const authoritativeState = applyRemoteTaskState(task, inventory);
      task.unread = task.unread && !remoteUnreadAcknowledged(task, authoritativeState);
    }
    const names = new Map(hostDiscovery.names);
    const availability = new Map(hostDiscovery.availability);
    for (const [hostId, inventory] of state.remoteProjectInventories) {
      if (!isSyntheticHostName(inventory?.hostDisplayName)) names.set(hostId, inventory.hostDisplayName.trim());
    }
    const remoteRuntimes = discoverRemoteRuntimes(hostDiscovery.runtimes);
    for (const hostId of state.localRuntimeHostIds) {
      names.delete(hostId);
      availability.delete(hostId);
      remoteRuntimes.delete(hostId);
    }
    for (const hostId of new Set([...names.keys(), ...availability.keys(), ...hostDiscovery.registeredProjects.values()].map((item) => typeof item === "string" ? item : item.hostId))) {
      if (hostId !== "local" && !remoteRuntimes.has(hostId)) availability.set(hostId, false);
    }
    for (const [hostId, connectivity] of state.hostConnectivity) {
      if (typeof connectivity?.available === "boolean"
        && (connectivity.available === false || Date.now() - Number(connectivity.checkedAt) <= REMOTE_INVENTORY_IDLE_TTL_MS)) {
        availability.set(hostId, connectivity.available);
      }
    }
    for (const task of tasks) {
      for (const [id, name] of task.hostNames) {
        const normalizedId = normalizeHostId(id);
        if (!names.has(normalizedId) && !isSyntheticHostName(name)) names.set(normalizedId, name.trim());
      }
      if (task.hostId !== "local" && !names.has(task.hostId) && !isSyntheticHostName(task.hostDisplayName)) names.set(task.hostId, task.hostDisplayName.trim());
    }
    for (const project of nativeProjects) {
      if (project.hostId !== "local" && !names.has(project.hostId) && !isSyntheticHostName(project.hostDisplayName)) names.set(project.hostId, project.hostDisplayName.trim());
    }
    const remoteHostIds = [...new Set([...tasks, ...nativeProjects, ...remoteInventoryProjects].map((item) => item.hostId).filter((hostId) => hostId !== "local"))];
    const singleRemoteHostId = remoteHostIds.length === 1 ? remoteHostIds[0] : null;

    const hosts = [];
    const seenHosts = new Set();
    for (const item of [...tasks, ...nativeProjects, ...remoteInventoryProjects]) {
      if (!seenHosts.has(item.hostId)) {
        seenHosts.add(item.hostId);
        hosts.push({
          id: item.hostId,
          name: hostName(item.hostId, names, singleRemoteHostId),
          available: item.hostId === "local" || availability.get(item.hostId) === true,
          availabilityKnown: item.hostId === "local" || availability.has(item.hostId),
        });
      }
    }
    for (const hostId of new Set([...names.keys(), ...availability.keys(), ...remoteRuntimes.keys()])) {
      if (hostId === "local" || seenHosts.has(hostId)) continue;
      seenHosts.add(hostId);
      hosts.push({
        id: hostId,
        name: hostName(hostId, names, singleRemoteHostId),
        available: availability.get(hostId) === true,
        availabilityKnown: availability.has(hostId),
      });
    }

    const groups = [];
    const groupsByKey = new Map();
    const projectByHostPath = new Map();
    const projectByHostId = new Map();
    for (const project of nativeProjects) {
      const key = `${project.hostId}::project:${project.projectId}`;
      if (groupsByKey.has(key)) continue;
      const aliases = [...new Set([project.cwd, ...(project.rootPaths ?? [])].filter(Boolean).map((cwd) => `${project.hostId}::${normalizePath(cwd)}`))];
      const existingGroup = aliases.map((alias) => projectByHostPath.get(alias)).find(Boolean);
      if (existingGroup) {
        groupsByKey.set(key, existingGroup);
        if (!existingGroup.projectId && project.projectId) existingGroup.projectId = project.projectId;
        for (const alias of aliases) projectByHostPath.set(alias, existingGroup);
        continue;
      }
      const group = {
        cwd: project.cwd,
        hostId: project.hostId,
        hostName: hostName(project.hostId, names, singleRemoteHostId),
        key,
        kind: "project",
        name: project.label,
        projectId: project.projectId,
        tasks: [],
      };
      groupsByKey.set(key, group);
      if (project.projectId) projectByHostId.set(`${project.hostId}::${project.projectId}`, group);
      for (const alias of aliases) projectByHostPath.set(alias, group);
      groups.push(group);
    }
    for (const project of remoteInventoryProjects) {
      const aliases = [...new Set([project.cwd, ...(project.rootPaths ?? [])].filter(Boolean).map((cwd) => `${project.hostId}::${normalizePath(cwd)}`))];
      const existingGroup = aliases.map((alias) => projectByHostPath.get(alias)).find(Boolean);
      if (existingGroup) {
        for (const alias of aliases) projectByHostPath.set(alias, existingGroup);
        continue;
      }
      const key = `${project.hostId}::cwd:${normalizePath(project.cwd)}`;
      if (groupsByKey.has(key)) continue;
      const group = {
        cwd: project.cwd,
        hostId: project.hostId,
        hostName: hostName(project.hostId, names, singleRemoteHostId),
        key,
        kind: "project",
        name: project.name,
        projectId: null,
        source: project.source,
        tasks: [],
      };
      groupsByKey.set(key, group);
      for (const alias of aliases) projectByHostPath.set(alias, group);
      groups.push(group);
    }
    for (const task of tasks) {
      const cwdKey = task.cwd ? normalizePath(task.cwd) : `unknown:${task.conversationKey}`;
      const matchingProject = (task.cwd ? projectByHostPath.get(`${task.hostId}::${cwdKey}`) : null)
        ?? (task.projectId ? projectByHostId.get(`${task.hostId}::${task.projectId}`) : null);
      const recent = !matchingProject && (authoritativeProjectPaths.has(task.hostId) || isRecentTask(task));
      const projectKey = task.projectId ? `project:${task.projectId}` : `cwd:${cwdKey}`;
      const key = recent ? `${task.hostId}::recent` : matchingProject?.key ?? `${task.hostId}::${projectKey}`;
      let group = groupsByKey.get(key);
      if (!group) {
        group = {
          cwd: task.cwd,
          hostId: task.hostId,
          hostName: hostName(task.hostId, names, singleRemoteHostId),
          key,
          kind: recent ? "recent" : "project",
          name: recent ? "Recent chats" : (task.projectLabel || projectName(task.cwd)),
          projectId: recent ? null : task.projectId,
          tasks: [],
        };
        groupsByKey.set(key, group);
        groups.push(group);
      }
      if (matchingProject && !group.cwd) group.cwd = task.cwd;
      group.tasks.push(task);
    }
    return {
      groups,
      hosts,
      projects: groups.filter((group) => group.kind === "project"),
      recents: groups.filter((group) => group.kind === "recent"),
      nativeProjectItems: nativeProjects.map((project) => project.item).filter(Boolean),
      remoteRuntimes,
      rows,
      tasks,
    };
  }

  function ensureStyle() {
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      #${PANEL_ID} { display:flex; flex-direction:column; gap:8px; padding:2px 8px 8px; }
      #${PANEL_ID} .crmp-modes { display:flex; flex-wrap:wrap; align-items:center; gap:4px; padding-bottom:2px; }
      #${PANEL_ID} .crmp-mode { flex:0 0 auto; border:0; border-radius:5px; padding:3px 6px; color:var(--color-text-tertiary,#888); background:transparent; font-size:10px; white-space:nowrap; cursor:pointer; }
      #${PANEL_ID} .crmp-mode[aria-pressed="true"] { color:var(--color-text,#eee); background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-update-control, #${PANEL_ID} .crmp-update-status { flex:0 0 auto; max-width:100%; margin-inline-start:auto; border:0; border-radius:5px; padding:3px 6px; color:var(--color-text-tertiary,#888); background:transparent; font-size:10px; line-height:14px; white-space:nowrap; }
      #${PANEL_ID} .crmp-update-control { cursor:pointer; }
      #${PANEL_ID} .crmp-update-control[data-state="available"], #${PANEL_ID} .crmp-update-control[data-state="queued"], #${PANEL_ID} .crmp-update-control[data-state="error"] { color:var(--color-text,#eee); background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-update-control:disabled { cursor:not-allowed; opacity:.6; }
      #${PANEL_ID} .crmp-update-group { display:inline-flex; flex:0 0 auto; align-items:center; gap:4px; max-width:100%; margin-inline-start:auto; color:var(--color-text-tertiary,#888); font-size:10px; line-height:14px; white-space:nowrap; }
      #${PANEL_ID} .crmp-update-group .crmp-update-status { margin-inline-start:0; }
      #${PANEL_ID} .crmp-update-cancel { border:1px solid var(--color-border-default,#555); border-radius:5px; padding:3px 6px; color:var(--color-text,#eee); background:transparent; font-size:10px; cursor:pointer; }
      #${PANEL_ID} button:focus-visible, #${CARD_ID}:focus-visible, #${CARD_ID} button:focus-visible, #${CONTEXT_ID}:focus-visible, #${CONTEXT_ID} button:focus-visible { outline:2px solid var(--color-accent,#74b9ff); outline-offset:-2px; }
      #${PANEL_ID} .crmp-filters { display:flex; flex-wrap:wrap; gap:6px; padding:2px 0 6px; }
      #${PANEL_ID} .crmp-auto-controls { display:flex; align-items:center; flex-wrap:wrap; gap:6px; padding:0 0 4px; }
      #${PANEL_ID} .crmp-inventory-status { padding:2px 4px 6px; color:var(--color-text-tertiary,#888); font-size:11px; line-height:1.35; }
      #${PANEL_ID} .crmp-auto-control { border:1px solid var(--color-border-default,#555); border-radius:6px; padding:3px 7px; color:var(--color-text-tertiary,#888); background:transparent; font-size:10px; cursor:pointer; }
      #${PANEL_ID} .crmp-auto-control[aria-pressed="true"] { color:var(--color-text,#eee); background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-auto-control:disabled { cursor:not-allowed; opacity:.5; }
      #${PANEL_ID} .crmp-title { padding:0 8px 2px; }
      #${PANEL_ID} .crmp-project-list { display:flex; flex-direction:column; gap:1px; }
      #${PANEL_ID} .crmp-chip { flex:0 0 auto; border:1px solid var(--color-border-default,#555); border-radius:999px; padding:4px 9px; color:var(--color-text-secondary,#aaa); background:var(--color-background-secondary,transparent); font-size:11px; line-height:16px; text-align:left; white-space:nowrap; cursor:pointer; }
      #${PANEL_ID} .crmp-chip[aria-pressed="true"] { color:var(--color-text,#fff); background:var(--color-background-inverted,#333); border-color:transparent; }
      #${PANEL_ID} .crmp-dot { display:inline-block; width:7px; height:7px; margin-inline-end:5px; border-radius:50%; background:#24b47e; }
      #${PANEL_ID} .crmp-dot-unavailable { background:#d95757; }
      #${PANEL_ID} .crmp-project { display:flex; flex-direction:column; }
      #${PANEL_ID} .crmp-project-head { position:relative!important; display:flex!important; align-items:center; width:100%; min-height:var(--height-token-row,30px); }
      #${PANEL_ID} .crmp-project-toggle { display:grid; flex:1 1 auto; grid-template-columns:16px minmax(0,1fr) auto; align-items:center; column-gap:8px; min-width:0; min-height:var(--height-token-row,30px); border:0; padding:4px 8px; color:inherit; background:transparent; font-size:14px; line-height:21px; text-align:left; cursor:pointer; }
      #${PANEL_ID} [draggable="true"] { cursor:grab; }
      #${PANEL_ID} [draggable="true"]:active { cursor:grabbing; }
      #${PANEL_ID} .crmp-dragging { opacity:.45; }
      #${PANEL_ID} .crmp-drop-before::before, #${PANEL_ID} .crmp-drop-after::after { position:absolute; z-index:4; right:6px; left:6px; height:2px; border-radius:2px; background:var(--color-accent,#74b9ff); content:""; pointer-events:none; }
      #${PANEL_ID} .crmp-drop-before::before { top:-1px; }
      #${PANEL_ID} .crmp-drop-after::after { bottom:-1px; }
      #${PANEL_ID} .crmp-project-action, #${PANEL_ID} .crmp-project-new { position:absolute!important; top:50%; display:flex!important; visibility:visible!important; align-items:center; justify-content:center; opacity:0; pointer-events:none; transform:translateY(-50%); transition:opacity 100ms ease; }
      #${PANEL_ID} .crmp-project-action { right:3px; }
      #${PANEL_ID} .crmp-project-new { right:29px; font-size:14px; }
      #${PANEL_ID} .crmp-project-head:hover .crmp-project-action, #${PANEL_ID} .crmp-project-head:hover .crmp-project-new, #${PANEL_ID} .crmp-project-head:focus-within .crmp-project-action, #${PANEL_ID} .crmp-project-head:focus-within .crmp-project-new, #${PANEL_ID} .crmp-project-action[aria-expanded="true"] { opacity:1; pointer-events:auto; }
      #${CARD_ID} { position:fixed; z-index:2147483646; display:flex; flex-direction:column; width:min(320px,calc(100vw - 16px)); overflow:hidden; border:1px solid var(--color-border-default,rgba(127,127,127,.2)); border-radius:10px; color:var(--color-text,#eee); background:var(--color-background-secondary,#292929); box-shadow:0 8px 22px rgba(0,0,0,.24); pointer-events:auto!important; }
      #${CARD_ID} .crmp-project-card-row { display:flex; align-items:center; gap:7px; min-height:31px; border:0; padding:6px 10px; color:inherit; background:transparent; font-size:12px; line-height:17px; text-align:left; }
      #${CARD_ID} button.crmp-project-card-row { cursor:pointer; pointer-events:auto!important; }
      #${CARD_ID} button.crmp-project-card-row:hover { background:var(--color-background-primary-hover,rgba(127,127,127,.12)); }
      #${CARD_ID} button.crmp-project-card-row:disabled { color:var(--color-text-tertiary,#777); cursor:not-allowed; opacity:.5; }
      #${CARD_ID} .crmp-project-card-head { font-weight:600; }
      #${CARD_ID} .crmp-project-card-spacer { flex:1 1 auto; }
      #${CARD_ID} .crmp-project-card-pin { width:26px; justify-content:center; padding-inline:4px; }
      #${CARD_ID} .crmp-project-card-divider { height:1px; margin:0 9px; background:var(--color-border-default,rgba(127,127,127,.2)); }
      #${CARD_ID} .crmp-project-card-path { overflow-wrap:anywhere; }
      #${CARD_ID} .crmp-project-card-icon { flex:0 0 14px; color:var(--color-text-secondary,#aaa); }
      #${CONTEXT_ID} { position:fixed; z-index:2147483647; display:flex; flex-direction:column; width:166px; overflow:hidden; border:1px solid var(--color-border-default,rgba(127,127,127,.2)); border-radius:8px; padding:5px; color:var(--color-text,#eee); background:var(--color-background-secondary,#292929); box-shadow:0 8px 22px rgba(0,0,0,.28); pointer-events:auto!important; }
      #${CONTEXT_ID} .crmp-context-item { display:grid; grid-template-columns:18px minmax(0,1fr); align-items:center; gap:7px; min-height:32px; border:0; border-radius:5px; padding:5px 8px; color:inherit; background:transparent; font-size:12px; text-align:left; cursor:pointer; pointer-events:auto!important; }
      #${CONTEXT_ID} .crmp-context-item:hover { background:var(--color-background-primary-hover,rgba(127,127,127,.12)); }
      #${CONTEXT_ID} .crmp-context-item:disabled { color:var(--color-text-tertiary,#777); cursor:not-allowed; opacity:.45; }
      #${CONTEXT_ID} .crmp-context-note { padding:6px 8px 8px; color:var(--color-text-tertiary,#888); font-size:10px; line-height:14px; }
      #${CONTEXT_ID} .crmp-context-separator { height:1px; margin:4px 0; background:var(--color-border-default,rgba(127,127,127,.2)); }
      #${PANEL_ID} .crmp-folder { position:relative; display:flex; width:16px; height:16px; align-items:center; justify-content:center; align-self:center; font-size:15px; line-height:0; }
      #${PANEL_ID} .crmp-folder svg { display:block; width:16px; height:16px; flex:none; }
      #${PANEL_ID} .crmp-project-name { overflow:hidden; font-size:inherit; font-weight:inherit; text-overflow:ellipsis; white-space:nowrap; }
      #${PANEL_ID} .crmp-project-host { max-width:82px; overflow:hidden; color:var(--color-text-tertiary,#888); font-size:9px; text-align:right; text-overflow:ellipsis; white-space:nowrap; transition:opacity 100ms ease; }
      #${PANEL_ID} .crmp-project-head:hover .crmp-project-host, #${PANEL_ID} .crmp-project-head:focus-within .crmp-project-host, #${PANEL_ID} .crmp-project-head[data-actions-open="true"] .crmp-project-host { opacity:0; }
      #${PANEL_ID} .crmp-tasks { display:flex; flex-direction:column; }
      #${PANEL_ID} .crmp-task-row { position:relative; min-width:0; }
      #${PANEL_ID} .crmp-task { display:block; width:100%; overflow:hidden; border:0; padding:5px 62px 5px 25px; color:var(--color-text,#ddd); background:transparent; font-size:12px; line-height:18px; text-align:left; text-overflow:ellipsis; white-space:nowrap; cursor:pointer; }
      #${PANEL_ID} .crmp-task[aria-current="page"] { background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-task-actions { position:absolute!important; top:0!important; right:0!important; display:flex; height:100%; align-items:center; justify-content:flex-end; gap:2px; padding-right:6px; opacity:0; pointer-events:none; transition:opacity 100ms ease; }
      #${PANEL_ID} .crmp-task-row:hover .crmp-task-actions, #${PANEL_ID} .crmp-task-row:focus-within .crmp-task-actions { opacity:1; pointer-events:auto; }
      #${PANEL_ID} .crmp-task-action { pointer-events:auto; }
      #${PANEL_ID} .crmp-task-status { position:absolute; top:0; right:8px; display:flex; width:20px; height:100%; align-items:center; justify-content:center; color:var(--color-text-secondary,#999); opacity:1; pointer-events:none; transition:opacity 100ms ease; }
      #${PANEL_ID} .crmp-task-row:hover .crmp-task-status, #${PANEL_ID} .crmp-task-row:focus-within .crmp-task-status { opacity:0; }
      #${PANEL_ID} .crmp-task-status { width:auto; min-width:20px; gap:4px; }
      #${PANEL_ID} .crmp-task-status-loading svg, #${PANEL_ID} .crmp-project-status-loading svg { width:16px; height:16px; }
      #${PANEL_ID} .crmp-task-unread-dot { display:block; width:8px; height:8px; border-radius:50%; background:var(--color-background-info-solid,var(--color-text-info,#74b9ff)); }
      #${PANEL_ID} .crmp-project-status { position:absolute; top:0; right:8px; display:flex; min-width:20px; height:100%; align-items:center; justify-content:center; pointer-events:none; }
      #${PANEL_ID} .crmp-project-head:hover .crmp-project-status, #${PANEL_ID} .crmp-project-head:focus-within .crmp-project-status, #${PANEL_ID} .crmp-project-head[data-actions-open="true"] .crmp-project-status { visibility:hidden; }
      @media (prefers-reduced-motion:no-preference) { #${PANEL_ID} .crmp-status-spin { animation:crmp-task-spin 2000ms linear infinite; } }
      @media (prefers-reduced-motion:reduce) { #${PANEL_ID} .crmp-status-spin { animation:none!important; } }

      #${PANEL_ID} .crmp-mode, #${PANEL_ID} .crmp-auto-control, #${PANEL_ID} .crmp-update-control, #${PANEL_ID} .crmp-update-cancel { min-height:30px; font-size:12px; line-height:18px; }
      #${PANEL_ID} .crmp-mode, #${PANEL_ID} .crmp-auto-control, #${PANEL_ID} .crmp-update-status, #${PANEL_ID} .crmp-update-group, #${PANEL_ID} .crmp-inventory-status, #${PANEL_ID} .crmp-project-host { color:var(--color-text-secondary,inherit); }
      #${PANEL_ID} .crmp-chip { min-height:30px; font-size:12px; white-space:normal; overflow-wrap:anywhere; }
      #${PANEL_ID} .crmp-project-host { font-size:12px; max-width:90px; }
      #${PANEL_ID} .crmp-task { font-size:13px; min-height:30px; }
      #${PANEL_ID} .crmp-update-group { flex-wrap:wrap; white-space:normal; font-size:12px; margin:0; }
      #${PANEL_ID} .crmp-update-control, #${PANEL_ID} .crmp-update-status { margin:0; white-space:normal; font-size:12px; }
      #${PANEL_ID} .crmp-update-panel, #${PANEL_ID} .crmp-settings, #${PANEL_ID} .crmp-devices { min-width:0; padding:6px; border:1px solid var(--color-border-default,#777); border-radius:8px; }
      #${PANEL_ID} .crmp-settings[hidden] { display:none; }
      #${PANEL_ID} .crmp-help { margin:6px 0; font-size:12px; line-height:1.5; color:var(--color-text-secondary,inherit); overflow-wrap:anywhere; }
      #${PANEL_ID} summary { min-height:28px; font-size:12px; line-height:28px; cursor:pointer; overflow-wrap:anywhere; }
      #${PANEL_ID} summary:focus-visible { outline:2px solid var(--color-accent,#74b9ff); }
      #${PANEL_ID} .crmp-project-action, #${PANEL_ID} .crmp-project-new, #${PANEL_ID} .crmp-task-action { min-width:24px; min-height:24px; }
      .crmp-sr-only { position:absolute!important; width:1px!important; height:1px!important; overflow:hidden!important; clip-path:inset(50%)!important; white-space:nowrap!important; }
      @media (hover:none), (pointer:coarse) {
        #${PANEL_ID} .crmp-project-action, #${PANEL_ID} .crmp-project-new, #${PANEL_ID} .crmp-task-actions { opacity:1; pointer-events:auto; }
        #${PANEL_ID} .crmp-project-host { margin-right:52px; }
      }
      @keyframes crmp-task-spin { to { transform:rotate(360deg); } }
      #${PANEL_ID} .crmp-empty { padding:8px 4px; color:var(--color-text-tertiary,#888); font-size:12px; }
    `;
    document.head.appendChild(style);
  }

  function button(className, text) {
    const element = document.createElement("button");
    element.type = "button";
    element.className = className;
    element.textContent = text;
    return element;
  }

  function normalizeUpdateStatus(value) {
    const stateValue = UPDATE_STATES.has(value?.state) ? value.state : "unavailable";
    return {
      canCancel: value?.canCancel === true,
      canQueue: value?.canQueue === true,
      message: typeof value?.message === "string" && value.message.trim() ? value.message.trim().slice(0, 240) : null,
      state: stateValue,
      version: typeof value?.version === "string" && value.version.trim() ? value.version.trim().slice(0, 40) : null,
    };
  }

  function readUpdateStatus() {
    const updater = globalThis[UPDATE_SLOT];
    if (typeof updater?.getStatus === "function") {
      try { state.updateStatus = normalizeUpdateStatus(updater.getStatus()); } catch {}
    }
    state.updateStatus ??= normalizeUpdateStatus(null);
    return { ...state.updateStatus };
  }

  function handleUpdateStatus(event) {
    if (event?.detail && typeof event.detail === "object") state.updateStatus = normalizeUpdateStatus(event.detail);
    else {
      state.updateStatus = null;
      readUpdateStatus();
    }
    schedule();
  }

  async function requestUpdateAction(action) {
    if (!["check", "queue", "cancel"].includes(action)) return;
    const updater = globalThis[UPDATE_SLOT];
    if (typeof updater?.request !== "function") {
      state.updateStatus = normalizeUpdateStatus({ state: "unavailable", message: "Update service is unavailable" });
      schedule();
      return;
    }
    if (action === "check") state.updateStatus = normalizeUpdateStatus({ ...readUpdateStatus(), state: "checking" });
    if (action === "queue") state.updateStatus = normalizeUpdateStatus({ ...readUpdateStatus(), state: "queued", canCancel: true });
    schedule();
    try {
      await updater.request(action);
      readUpdateStatus();
    } catch (error) {
      state.updateStatus = normalizeUpdateStatus({ state: "error", message: String(error?.message ?? error).slice(0, 240) });
    }
    schedule();
  }

  function updateStatusControl() {
    const status = readUpdateStatus();
    const versionLabel = status.version ? (/^v/iu.test(status.version) ? status.version : `v${status.version}`) : null;
    if (["checking", "current"].includes(status.state)) {
      const compact = document.createElement("span");
      compact.className = "crmp-update-status";
      compact.dataset.state = status.state;
      compact.textContent = status.state === "checking" ? "Checking updates…" : `Current${versionLabel ? ` · ${versionLabel}` : ""}`;
      compact.title = status.message ?? compact.textContent;
      return compact;
    }
    const labels = {
      available: `Update available${versionLabel ? ` · ${versionLabel}` : ""}`,
      queued: "Update queued",
      preparing: "Preparing update…",
      closing: "Closing for update…",
      updating: "Updating…",
      restarting: "Restarting…",
      error: "Check again",
      unavailable: "Updates unavailable",
    };
    if (["queued", "preparing"].includes(status.state) && status.canCancel) {
      const group = document.createElement("span");
      group.className = "crmp-update-group";
      group.dataset.state = status.state;
      group.title = status.message ?? labels[status.state];
      const label = document.createElement("span");
      label.className = "crmp-update-label";
      label.textContent = labels[status.state];
      const cancel = button("crmp-update-cancel", "Cancel");
      setFocusKey(cancel, "update", status.state, "cancel");
      cancel.addEventListener("click", () => { void requestUpdateAction("cancel"); });
      group.append(label, cancel);
      return group;
    }
    const control = button("crmp-update-control", labels[status.state] ?? "Updates unavailable");
    control.dataset.state = status.state;
    control.title = status.message ?? control.textContent;
    setFocusKey(control, "update", status.state);
    if (status.state === "available") {
      control.disabled = !status.canQueue;
      control.addEventListener("click", () => { void requestUpdateAction("queue"); });
    } else if (["error", "unavailable"].includes(status.state)) {
      control.disabled = typeof globalThis[UPDATE_SLOT]?.request !== "function";
      control.addEventListener("click", () => { void requestUpdateAction("check"); });
    } else {
      control.disabled = true;
    }
    return control;
  }

  function connectionLabel(host) {
    if (host.id === "local") return "This device";
    return !host.availabilityKnown ? "Connection unknown" : host.available === false ? "Disconnected" : "Connected";
  }

  function inventoryLabel(hostId) {
    if (hostId === "local") return state.inventoryHydrationPending ? "Loading local inventory." : "Local projects.";
    const inventory = state.remoteProjectInventories.get(hostId);
    if (!inventory) return "Inventory not received yet.";
    const fresh = freshInventory(hostId);
    if (inventory.pending) return fresh ? "Refreshing inventory; current information is shown." : "Loading inventory; previous information may be out of date.";
    if (!fresh) return "Inventory is unavailable or out of date; cached information may be shown.";
    return "Current inventory received.";
  }

  function emptyInventoryMessage(hostId, filtered = false) {
    if (hostId === "local") return state.inventoryHydrationPending || state.inventoryHydrationError
      ? "Loading local tasks. Waiting for current inventory." : (filtered ? "No projects or tasks on this device." : "No tasks in this project yet.");
    const host = state.displayedHosts.find(item => item.id === hostId);
    if (host?.availabilityKnown && host.available === false) return "Device disconnected. Reconnect it using Remote to load tasks.";
    const inventory = state.remoteProjectInventories.get(hostId);
    if (!inventory || inventory.pending) return "Loading tasks from this device…";
    if (!freshInventory(hostId) || inventory.error) return "Task information is out of date. Waiting for the device to refresh.";
    if (!inventory.threadsAuthoritative) return "Waiting for a complete task inventory.";
    return filtered ? "No projects or tasks match this device. Choose All to see other devices." : "No tasks in this project yet.";
  }

  function updateExplanation(status) {
    if (status.state === "queued") return /unknown|authoritative|unavailable|information/i.test(status.message || "")
      ? "Waiting for activity information. The app will stay open until it is safe to update."
      : "Waiting for tasks to finish. The app will restart when it is safe to update.";
    if (status.state === "preparing") return status.canCancel
      ? "Downloading and verifying the update. You can cancel before shutdown starts."
      : /cancell/i.test(status.message || "") ? "Finishing preparation before cancellation completes. The app will stay open." : "Preparing the verified update…";
    return ({
      available: "Install when tasks finish; the app will close and reopen automatically.",
      checking: "Checking for a new release…", closing: "Closing the app normally before updating…",
      updating: "Installing the verified update…", restarting: "Reopening the app with your saved settings…",
      error: "The update could not complete. Review the details, then check again.",
      unavailable: "The update service is unavailable in this session." })[status.state] || "";
  }

  function announceUpdate(status) {
    const announcement = `${status.state}: ${updateExplanation(status)}`;
    if (announcement === state.lastAnnouncement) return;
    state.lastAnnouncement = announcement;
    if (state.liveRegion) state.liveRegion.textContent = status.state === "current" ? "Remote Enabler is up to date." : updateExplanation(status);
  }

  function updateStatusPanel(status) {
    const panel = document.createElement("section");
    panel.className = "crmp-update-panel";
    panel.setAttribute("aria-label", "Remote Enabler update");
    panel.appendChild(updateStatusControl());
    const explanation = document.createElement("p");
    explanation.className = "crmp-help";
    explanation.textContent = updateExplanation(status);
    panel.appendChild(explanation);
    if (status.message && ["error", "unavailable"].includes(status.state)) {
      const details = document.createElement("details");
      details.open = state.updateDetailsOpen;
      details.addEventListener("toggle", () => { state.updateDetailsOpen = details.open; });
      const summary = document.createElement("summary");
      summary.textContent = "Technical details";
      setFocusKey(summary, "update-details");
      const message = document.createElement("p");
      message.className = "crmp-help";
      message.textContent = status.message;
      details.append(summary, message);
      panel.appendChild(details);
    }
    return panel;
  }

  function setFocusKey(element, ...parts) {
    element.dataset.crmpFocusKey = JSON.stringify(parts);
    return element;
  }

  function nativeElementDisabled(element) {
    return element?.disabled === true || element?.getAttribute("aria-disabled") === "true";
  }

  function captureSidebarFocus() {
    const active = document.activeElement;
    if (!(active instanceof Element)) return null;
    const overlay = active.closest(`#${CARD_ID},#${CONTEXT_ID}`);
    if (!state.panel?.contains(active) && !overlay) return null;
    const group = active.closest(".crmp-project");
    return {
      key: active.closest("[data-crmp-focus-key]")?.dataset.crmpFocusKey ?? null,
      fallbackKey: group?.querySelector(".crmp-project-toggle")?.dataset.crmpFocusKey ?? (overlay ? state.overlayFocusReturnKey : null),
      overlayId: overlay?.id ?? null,
    };
  }

  function focusSidebarElement(element) {
    if (!element?.isConnected || nativeElementDisabled(element) || !element.getClientRects().length) return false;
    element.focus({ preventScroll: true });
    return document.activeElement === element;
  }

  function restoreSidebarFocus(snapshot) {
    if (!snapshot) return;
    const keyed = (key) => key ? document.querySelector(`[data-crmp-focus-key="${CSS.escape(key)}"]`) : null;
    if (focusSidebarElement(keyed(snapshot.key))) return;
    const overlay = snapshot.overlayId ? document.getElementById(snapshot.overlayId) : null;
    if (overlay && focusProjectOverlay(overlay)) return;
    if (focusSidebarElement(keyed(snapshot.fallbackKey))) return;
    focusSidebarElement(state.panel?.querySelector('.crmp-mode[aria-pressed="true"]'));
  }

  function focusProjectOverlay(overlay, last = false) {
    const items = [...overlay.querySelectorAll("button")].filter((item) => !nativeElementDisabled(item));
    return focusSidebarElement(last ? items.at(-1) ?? overlay : items[0] ?? overlay);
  }

  function restoreRenderedFocus(snapshot) {
    for (const [element, top] of state.scrollSnapshot ?? []) if (element.isConnected) element.scrollTop = top;
    const pending = state.pendingOverlayFocus;
    state.pendingOverlayFocus = null;
    const overlay = pending ? document.getElementById(pending.id) : null;
    if (overlay && focusProjectOverlay(overlay, pending.last)) return;
    restoreSidebarFocus(snapshot);
  }

  function closeProjectOverlays(restoreFocus = true) {
    const returnKey = state.overlayFocusReturnKey;
    state.actionCardKey = null;
    state.contextProjectKey = null;
    state.contextPoint = null;
    state.pendingOverlayFocus = null;
    render();
    if (restoreFocus) restoreSidebarFocus({ key: returnKey });
    state.overlayFocusReturnKey = null;
  }

  function bindOverlayKeyboard(overlay, menu = false) {
    let search = "";
    let searchAt = 0;
    overlay.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        closeProjectOverlays();
        return;
      }
      const items = [...overlay.querySelectorAll("button")].filter((item) => !nativeElementDisabled(item));
      const index = items.indexOf(document.activeElement);
      if (event.key === "Tab" && (menu || (event.shiftKey ? index <= 0 : index === items.length - 1))) {
        event.stopPropagation();
        closeProjectOverlays();
        return;
      }
      if (!menu || event.altKey || event.ctrlKey || event.metaKey || !items.length) return;
      let next = null;
      if (event.key === "ArrowDown") next = items[(index + 1) % items.length];
      else if (event.key === "ArrowUp") next = items[(index - 1 + items.length) % items.length];
      else if (event.key === "Home") next = items[0];
      else if (event.key === "End") next = items.at(-1);
      else if (event.key.length === 1 && event.key.trim()) {
        const now = Date.now();
        search = (now - searchAt < 700 ? search : "") + event.key.toLocaleLowerCase();
        searchAt = now;
        const prefix = [...search].every((character) => character === search[0]) ? search[0] : search;
        next = [...items.slice(index + 1), ...items.slice(0, index + 1)]
          .find((item) => item.getAttribute("aria-label")?.toLocaleLowerCase().startsWith(prefix));
      }
      if (next) {
        event.preventDefault();
        event.stopPropagation();
        focusSidebarElement(next);
      }
    });
  }

  function openProjectContextMenu(project, anchor, point = null) {
    const rect = anchor.getBoundingClientRect();
    state.actionCardKey = null;
    state.contextProjectKey = project.key;
    state.contextPoint = point ?? { x: rect.left, y: rect.bottom };
    state.overlayFocusReturnKey = anchor.dataset.crmpFocusKey ?? null;
    state.pendingOverlayFocus = { id: CONTEXT_ID };
    render();
  }

  function bindActivation(element, handler) {
    let handledByPointer = false;
    let pressedPointerId = null;
    let removePointerTracking = null;
    const clearPointerTracking = () => {
      pressedPointerId = null;
      removePointerTracking?.();
      removePointerTracking = null;
    };
    element.addEventListener("pointerdown", (event) => {
      clearPointerTracking();
      handledByPointer = false;
      if (event.button !== 0 || nativeElementDisabled(element)) return;
      pressedPointerId = event.pointerId;
      const owner = element.ownerDocument;
      const clearOutsidePointer = (end) => {
        if (end.pointerId === pressedPointerId && (end.type === "pointercancel" || !element.contains(end.target))) clearPointerTracking();
      };
      owner.addEventListener("pointerup", clearOutsidePointer, true);
      owner.addEventListener("pointercancel", clearOutsidePointer, true);
      removePointerTracking = () => {
        owner.removeEventListener("pointerup", clearOutsidePointer, true);
        owner.removeEventListener("pointercancel", clearOutsidePointer, true);
      };
    });
    element.addEventListener("pointerup", (event) => {
      if (pressedPointerId === null || event.pointerId !== pressedPointerId) return;
      clearPointerTracking();
      handledByPointer = true;
      event.preventDefault();
      event.stopImmediatePropagation();
      const rect = element.getBoundingClientRect();
      if (event.button > 0 || nativeElementDisabled(element) || event.clientX < rect.left || event.clientX > rect.right
          || event.clientY < rect.top || event.clientY > rect.bottom) return;
      handler();
    });
    element.addEventListener("click", (event) => {
      clearPointerTracking();
      event.preventDefault();
      event.stopImmediatePropagation();
      if (handledByPointer && event.detail !== 0) {
        handledByPointer = false;
        return;
      }
      handledByPointer = false;
      if (!nativeElementDisabled(element)) handler();
    });
  }

  function invokeNativeElement(element) {
    if (!(element instanceof Element) || nativeElementDisabled(element)) return false;
    element.click();
    return true;
  }

  function nativeLoadMoreButtons() {
    return [...document.querySelectorAll('[role="list"][aria-label^="Chats in "] button')]
      .filter((item) => (item.textContent || "").replace(/\s+/gu, " ").trim() === "Show more");
  }

  function nativeThreadListExpansionControls() {
    const controls = [];
    const seen = new Set();
    const rows = [...document.querySelectorAll(ROW_SELECTOR)].filter((row) => !row.closest(`#${PANEL_ID}`));
    for (const row of rows) {
      let fiber = getFiber(row);
      for (let level = 0; fiber && level < 40; level += 1, fiber = fiber.return) {
        const props = fiber.memoizedProps;
        if (!Array.isArray(props?.items) || typeof props.onExpandedChange !== "function") continue;
        if (!props.items.length || !props.items.every((item) => typeof item === "string" && item.startsWith("local:"))) continue;
        const key = props.navigationListId ?? props.onExpandedChange;
        if (seen.has(key)) break;
        seen.add(key);
        controls.push({
          expand: props.onExpandedChange,
          expanded: props.expanded === true,
          itemCount: props.items.length,
          loadMore: typeof props.onLoadMore === "function" ? props.onLoadMore : null,
          maxItems: Number.isFinite(props.maxItems) ? props.maxItems : Number.POSITIVE_INFINITY,
          navigationListId: typeof props.navigationListId === "string" ? props.navigationListId : null,
        });
        break;
      }
    }
    return controls;
  }

  function nativeConnectionGroupingActive() {
    return nativeThreadListExpansionControls()
      .some((control) => control.navigationListId?.startsWith("codex:connection:"));
  }

  function runtimeThreadInventoryDue(hostId, now = Date.now()) {
    if (hostId === "local") return true;
    return Number(state.threadInventories.get(hostId)?.retryAt ?? 0) <= now;
  }

  async function hydrateNativeInventory() {
    if (state.inventoryHydrationPending) return;
    state.counters.inventoryHydrationRuns += 1;
    state.inventoryHydrationDirty = false;
    state.inventoryHydrationPending = true;
    state.inventoryHydrationPhase = "listing-threads";
    state.inventoryHydrationRounds = 0;
    state.inventoryHydrationTruncated = false;
    try {
      const discovery = discoverHostNames();
      const runtimes = new Map(discoverRemoteRuntimes(discovery.runtimes));
      if (state.localRuntime?.requestClient) runtimes.set("local", state.localRuntime);
      const tasks = [...runtimes].filter(([hostId]) => !state.localRuntimeHostIds.has(hostId) && runtimeThreadInventoryDue(hostId)).map(async ([hostId, runtime]) => {
        try {
          const deadline = Date.now() + 90000;
          const result = await (hostId === "local"
            ? listAllLocalThreadInventory(runtime.requestClient, false, deadline, false, "local inventory hydration", state.localRuntimeGeneration)
            : listAllRuntimeThreads(runtime.requestClient, false, deadline));
          const attemptedAt = Date.now();
          const prior = state.threadInventories.get(hostId);
          const truncated = result.truncated === true || result.threads.length >= 9800;
          const priorComplete = Number.isFinite(prior?.fetchedAt) && Array.isArray(prior?.threads) && prior.truncated !== true;
          const inventory = truncated
            ? {
              error: "thread/list returned an incomplete inventory",
              attemptTruncated: true,
              attemptedAt,
              fetchedAt: Number.isFinite(prior?.fetchedAt) ? prior.fetchedAt : null,
              hostId,
              pages: prior?.pages ?? 0,
              retryAt: attemptedAt + NATIVE_INVENTORY_ERROR_RETRY_MS,
              threads: Array.isArray(prior?.threads) ? prior.threads : [],
              truncated: priorComplete ? false : true,
            }
            : { attemptedAt, error: null, fetchedAt: attemptedAt, hostId, pages: result.pages, retryAt: 0, threads: result.threads, truncated: false };
          state.threadInventories.set(hostId, inventory);
          if (!truncated) rememberVerifiedThreadIds(hostId, inventory.threads);
          state.inventoryHydrationRounds += result.pages;
          if (hostId === "local") removeGossipedLocalInventoryDuplicates();
          if (!state.disposed) schedule();
          return inventory;
        } catch (error) {
          const attemptedAt = Date.now();
          const prior = state.threadInventories.get(hostId);
          const inventory = {
            error: String(error?.message ?? error).slice(0, 240),
            attemptedAt,
            fetchedAt: Number.isFinite(prior?.fetchedAt) ? prior.fetchedAt : null,
            hostId,
            pages: prior?.pages ?? 0,
            retryAt: attemptedAt + NATIVE_INVENTORY_ERROR_RETRY_MS,
            threads: Array.isArray(prior?.threads) ? prior.threads : [],
            truncated: prior?.truncated === true,
          };
          state.threadInventories.set(hostId, inventory);
          if (!state.disposed) schedule();
          return inventory;
        }
      });
      const results = await Promise.all(tasks);
      const errors = [...state.threadInventories.values()].filter((result) => result.error).map((result) => `${result.hostId}: ${result.error}`);
      state.inventoryHydrationError = errors.length ? errors.join("; ").slice(0, 240) : null;
      state.inventoryHydrationTruncated = results.some((result) => result.attemptTruncated === true || result.truncated === true || result.threads.length >= 9800);
    } catch (error) {
      state.inventoryHydrationError = String(error?.message ?? error).slice(0, 240);
    } finally {
      state.inventoryHydrationPending = false;
      state.inventoryHydrationPhase = "idle";
      if (!state.disposed) render();
    }
  }

  function scheduleNativeInventoryHydration() {
    if (state.inventoryHydrationPending || !document.querySelector('[aria-label="Project sidebar options"]')) return;
    if (state.inventoryHydrationTimer !== null) {
      if (!state.inventoryHydrationDirty) return;
      clearTimeout(state.inventoryHydrationTimer);
      state.inventoryHydrationTimer = null;
    }
    if (!state.inventoryHydrationStarted) {
      state.inventoryHydrationStarted = true;
      void hydrateNativeInventory();
      return;
    }
    const delay = state.inventoryHydrationDirty ? NATIVE_INVENTORY_DIRTY_DEBOUNCE_MS : NATIVE_INVENTORY_REFRESH_MS;
    state.inventoryHydrationStarted = true;
    state.inventoryHydrationTimer = setTimeout(() => {
      state.inventoryHydrationTimer = null;
      void hydrateNativeInventory();
    }, delay);
  }

  function normalizeSidebarStatus(value) {
    const count = Number(value?.unreadCount);
    return {
      type: value?.type === "error" ? "error" : normalizeTaskStatus(value?.type),
      unread: value?.unread === true,
      unreadCount: Number.isFinite(count) && count > 0 ? Math.floor(count) : 0,
    };
  }

  function sidebarLabelText(value, depth = 0) {
    if (typeof value === "string") return value;
    if (!value || typeof value !== "object" || depth > 4) return null;
    return typeof value.props?.defaultMessage === "string" ? value.props.defaultMessage
      : sidebarLabelText(value.props?.children, depth + 1);
  }

  function nativeTaskStatusMetadata(row) {
    let result = null;
    let fallbackUnread = null;
    const conversationId = rawConversationId(row.getAttribute("data-app-action-sidebar-thread-id") || "");
    for (let fiber = getFiber(row), level = 0; fiber && level < 24; fiber = fiber.return, level += 1) {
      const props = fiber.memoizedProps;
      if (!props || typeof props !== "object") continue;
      if (!result && props.statusState && typeof props.statusState === "object") {
        const approval = props.chips?.find?.((chip) => chip?.id === "awaiting-approval");
        result = {
          statusState: normalizeSidebarStatus(props.statusState),
          needsAttention: Boolean(props.statusPill || approval),
          attentionKind: props.statusPill ? "input" : approval ? "approval" : null,
          attentionLabel: sidebarLabelText(props.statusPill?.label ?? approval?.label),
        };
      }
      if (fallbackUnread === null && typeof props.isUnread === "boolean") fallbackUnread = props.isUnread;
      // Stop at this task's owner. Group and section status must not leak into a row.
      if (typeof props.conversationId === "string") {
        if (rawConversationId(props.conversationId) === conversationId && props.hasPendingChildApproval === true) {
          result ??= { statusState: normalizeSidebarStatus({ unread: fallbackUnread }), attentionKind: null, attentionLabel: null };
          result.needsAttention = true;
          result.attentionKind ??= "approval";
          result.attentionLabel ??= "Awaiting approval";
        }
        break;
      }
    }
    return result ?? { statusState: normalizeSidebarStatus({ unread: fallbackUnread }), needsAttention: false, attentionKind: null, attentionLabel: null };
  }

  function taskSidebarStatus(task) {
    const native = normalizeSidebarStatus(task.nativeStatusState);
    const flags = task.sourceThread?.status?.activeFlags;
    const waiting = Array.isArray(flags) && flags.some((flag) => flag === "waitingOnApproval" || flag === "waitingOnUserInput");
    return {
      type: task.statusType === "loading" ? "loading" : native.type === "error" ? "error" : "idle",
      unread: task.unread === true,
      unreadCount: Math.max(native.unreadCount, normalizeSidebarStatus(task).unreadCount),
      needsAttention: task.needsAttention === true || waiting,
      attentionKind: task.attentionKind ?? (waiting ? flags.includes("waitingOnUserInput") ? "input" : "approval" : null),
      attentionLabel: task.attentionLabel ?? (waiting ? flags.includes("waitingOnUserInput") ? "Needs input" : "Awaiting approval" : null),
    };
  }

  function sidebarStatusKind(status) {
    if ((status?.unreadCount ?? 0) > 0) return "count";
    if (status?.type === "loading") return "loading";
    if (status?.unread === true) return "unread";
    if (status?.type === "error") return "error";
    return null;
  }

  function aggregateSidebarStatus(tasks) {
    const statuses = tasks.map(taskSidebarStatus);
    // Native folders prioritize waiting/unread descendants over active descendants.
    if (statuses.some((status) => status.needsAttention || status.unread || status.unreadCount > 0)) return normalizeSidebarStatus({ unread: true });
    if (statuses.some((status) => status.type === "loading")) return normalizeSidebarStatus({ type: "loading" });
    return null;
  }

  function nativeProjectStatus(project) {
    const item = nativeProjectItem(project);
    const row = item?.querySelector('[data-app-action-sidebar-project-row],[data-app-action-sidebar-project-collapsed]');
    for (let fiber = row && getFiber(row), level = 0; fiber && level < 12; fiber = fiber.return, level += 1) {
      const props = fiber.memoizedProps;
      for (const candidate of [props, props?.actions?.props]) {
        if (!candidate || !Object.prototype.hasOwnProperty.call(candidate, "collapsedStatusState")) continue;
        return { known: true, row, statusState: candidate.collapsedStatusState == null ? null : normalizeSidebarStatus(candidate.collapsedStatusState) };
      }
      if (props?.group) break;
    }
    return { known: false, row, statusState: null };
  }

  function sidebarStatusTemplate(root, status) {
    if (!root) return null;
    const targetKind = sidebarStatusKind(status);
    const stack = [getFiber(root)?.child];
    for (let remaining = 1200; stack.length && remaining > 0; remaining -= 1) {
      const fiber = stack.pop();
      if (!fiber) continue;
      if (fiber.sibling) stack.push(fiber.sibling);
      if (fiber.child) stack.push(fiber.child);
      const nativeStatus = fiber.memoizedProps?.statusState;
      if (!nativeStatus || sidebarStatusKind(nativeStatus) !== targetKind || (targetKind === "count" && nativeStatus.unreadCount !== status.unreadCount)) continue;
      // The native status component takes statusState alone; task row components also
      // take it, but cloning their whole DOM would duplicate a title and actions.
      if (Object.keys(fiber.memoizedProps).some((key) => key !== "statusState" && key !== "className")) continue;
      let content = fiber.child;
      for (let depth = 0; content && depth < 12; depth += 1, content = content.child) {
        if (!(content.stateNode instanceof Element)) continue;
        if (root.contains(content.stateNode)) return content.stateNode.cloneNode(true);
        break;
      }
    }
    return null;
  }

  function sidebarStatusContent(status, nativeRoot) {
    const kind = sidebarStatusKind(status);
    if (!kind) return null;
    const native = sidebarStatusTemplate(nativeRoot, status);
    if (native) {
      for (const spinner of [native, ...native.querySelectorAll('[class*="animate-spin"]')]) {
        if (!spinner.className?.includes?.("animate-spin")) continue;
        spinner.classList.add("crmp-status-spin");
        spinner.style.animationDuration = "2000ms";
      }
      return native;
    }
    const content = document.createElement("span");
    content.className = "relative flex size-5 shrink-0 items-center justify-center";
    if (kind === "loading") {
      content.classList.add("text-text/70");
      const spinner = document.createElement("span");
      spinner.className = "inline-flex h-fit w-fit items-center justify-center leading-none contain-layout contain-paint contain-style crmp-status-spin";
      spinner.style.animationDuration = "2000ms";
      spinner.style.animationDelay = `-${Date.now() % 1000}ms`;
      spinner.innerHTML = '<svg class="icon-xs shrink-0" width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path opacity="0.3" d="M18 12C18 8.68629 15.3137 6 12 6C8.68629 6 6 8.68629 6 12C6 15.3137 8.68629 18 12 18C15.3137 18 18 15.3137 18 12ZM20 12C20 16.4183 16.4183 20 12 20C7.58172 20 4 16.4183 4 12C4 7.58172 7.58172 4 12 4C16.4183 4 20 7.58172 20 12Z" fill="currentColor"/><path d="M12 4C16.4183 4 20 7.58172 20 12C20 16.4183 16.4183 20 12 20C7.58172 20 4 16.4183 4 12H6C6 15.3137 8.68629 18 12 18C15.3137 18 18 15.3137 18 12C18 8.68629 15.3137 6 12 6V4Z" fill="currentColor"/></svg>';
      content.appendChild(spinner);
    } else if (kind === "count") {
      content.className = "relative flex h-5 min-w-5 shrink-0 items-center justify-center";
      const badge = document.createElement("span");
      badge.className = "flex h-5 min-w-5 items-center justify-center rounded-full px-1.5 text-[11px] leading-none font-semibold";
      badge.style.backgroundColor = "color-mix(in srgb, var(--color-text-info) 18%, transparent)";
      badge.style.boxShadow = "inset 0 0 0 1px color-mix(in srgb, var(--color-text-info) 72%, transparent)";
      badge.style.color = "var(--color-text-info)";
      badge.textContent = status.unreadCount > 99 ? "99+" : String(status.unreadCount);
      content.appendChild(badge);
    } else if (kind === "error") {
      content.classList.add("text-danger");
      content.innerHTML = '<svg class="icon-xs shrink-0" width="16" height="16" viewBox="0 0 16 16" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8 7.48633C8.28351 7.48633 8.51367 7.71649 8.51367 8V10.667C8.5135 10.9503 8.2834 11.1797 8 11.1797C7.7166 11.1797 7.4865 10.9503 7.48633 10.667V8C7.48633 7.71649 7.71649 7.48633 8 7.48633Z" fill="currentColor"/><path d="M8 4.90137C8.37814 4.9015 8.68544 5.20779 8.68555 5.58594C8.68528 5.96395 8.37804 6.27135 8 6.27148C7.62194 6.27138 7.31569 5.96396 7.31543 5.58594C7.31554 5.20778 7.62184 4.90147 8 4.90137Z" fill="currentColor"/><path fill-rule="evenodd" clip-rule="evenodd" d="M8 1.48633C11.5972 1.48633 14.5137 4.40279 14.5137 8C14.5137 11.5972 11.5972 14.5137 8 14.5137C4.40279 14.5137 1.48633 11.5972 1.48633 8C1.48633 4.40279 4.40279 1.48633 8 1.48633ZM8 2.51367C4.9698 2.51367 2.51367 4.9698 2.51367 8C2.51367 11.0302 4.9698 13.4863 8 13.4863C11.0302 13.4863 13.4863 11.0302 13.4863 8C13.4863 4.9698 11.0302 2.51367 8 2.51367Z" fill="currentColor"/></svg>';
    } else {
      const dot = document.createElement("span");
      dot.className = "crmp-task-unread-dot bg-info-solid";
      content.appendChild(dot);
    }
    return content;
  }

  function taskStatusLabel(task) {
    const status = taskSidebarStatus(task);
    if (status.attentionLabel) return status.attentionLabel;
    if (status.unreadCount > 0) return `${status.unreadCount} unread updates`;
    if (status.type === "loading") return "working";
    if (status.unread) return "unread";
    if (status.type === "error") return "error";
    return null;
  }

  function taskStatusIndicator(task) {
    const taskState = taskSidebarStatus(task);
    const status = document.createElement("span");
    let attention = null;
    if (taskState.attentionLabel && task.originalRow) {
      const candidates = [...task.originalRow.querySelectorAll("button,span")];
      attention = (taskState.attentionKind === "input" ? candidates.find((element) => element.className?.includes?.("bg-chart-blue/15")) : null)
        ?? candidates.find((element) => element.textContent?.trim() === taskState.attentionLabel && !element.querySelector("button,span")) ?? null;
      if (attention) {
        const nativeButton = attention.closest("button");
        const template = nativeButton && (taskState.attentionKind === "input" || nativeButton.textContent?.trim() === taskState.attentionLabel) ? nativeButton : attention;
        const clone = template.cloneNode(true);
        if (template.tagName === "BUTTON") {
          clone.style.pointerEvents = "auto";
          bindActivation(clone, () => template.click());
        }
        status.appendChild(clone);
      }
    }
    if (!attention && taskState.attentionKind === "input") {
      attention = document.createElement("span");
      attention.className = "relative inline-grid max-w-[150px] shrink-0 items-center overflow-hidden rounded-full bg-chart-blue/15 py-0.5 pe-2.5 ps-2 text-sm text-chart-blue";
      attention.textContent = taskState.attentionLabel || "Needs input";
      status.appendChild(attention);
    }
    const kind = taskState.attentionKind === "input" && attention ? "attention" : sidebarStatusKind(taskState);
    const content = kind === "attention" ? null : sidebarStatusContent(taskState, task.originalRow);
    if (content) status.appendChild(content);
    if (!attention && !content && taskState.needsAttention) status.appendChild(sidebarStatusContent({ unread: true }));
    if (!status.children.length) return null;
    status.className = `crmp-task-status crmp-task-status-${kind || "attention"}`;
    if (attention) status.classList.add("crmp-task-status-has-attention");
    if (!status.querySelector("button")) status.setAttribute("aria-hidden", "true");
    return status;
  }

  function projectStatusIndicator(project, expanded) {
    if (expanded || project.flatRecent) return null;
    const native = nativeProjectStatus(project);
    const statusState = native.known ? native.statusState : aggregateSidebarStatus(project.tasks);
    const kind = sidebarStatusKind(statusState);
    if (!kind) return null;
    const status = document.createElement("span");
    status.className = `crmp-project-status crmp-project-status-${kind}`;
    status.setAttribute("aria-hidden", "true");
    status.appendChild(sidebarStatusContent(statusState, native.row));
    return status;
  }

  function reserveTaskStatusSpace(taskButton, statusIndicator) {
    if (!taskButton.isConnected || !statusIndicator.isConnected) return;
    const width = statusIndicator.getBoundingClientRect().width;
    if (!Number.isFinite(width) || width <= 0) return;
    const currentPadding = Number.parseFloat(getComputedStyle(taskButton).paddingRight) || 0;
    const trailingInset = Number.parseFloat(getComputedStyle(statusIndicator).right) || 0;
    // Native task rows reserve intrinsic status width with a 3px gap before the
    // trailing rail. Keep enough room for the custom row's hover actions as well.
    taskButton.style.paddingRight = `${Math.ceil(Math.max(currentPadding, width + trailingInset + 3))}px`;
  }

  function isolateOverlay(element) {
    element.addEventListener("pointerdown", (event) => event.stopPropagation());
    element.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      event.stopPropagation();
    });
  }

  function nativeProjectItem(project) {
    if (project.kind !== "project") return null;
    const items = [...document.querySelectorAll('[data-sidebar-project-kind][role="listitem"]')];
    if (project.projectId) {
      const selector = `[data-app-action-sidebar-project-list-id="${CSS.escape(project.projectId)}"]`;
      const byId = items.find((item) => item.matches(selector) || item.querySelector(selector));
      if (byId) return byId;
    }
    return items.find((item) => {
      const metadata = metadataFromNativeProject(item);
      return metadata?.hostId === project.hostId && metadata.label === project.name;
    }) ?? null;
  }

  function reactProps(element) {
    const key = element && Object.keys(element).find((name) => name.startsWith("__reactProps$"));
    return key ? element[key] : null;
  }

  function nativeThreadRow(reference) {
    return [...document.querySelectorAll(ROW_SELECTOR)].find((row) => {
      if (row.closest(`#${PANEL_ID}`)) return false;
      return rawConversationId(row.getAttribute("data-app-action-sidebar-thread-id")) === (reference.conversationId || rawConversationId(reference.conversationKey))
        && normalizeHostId(row.getAttribute("data-app-action-sidebar-thread-host-id") || "local") === reference.hostId;
    }) ?? null;
  }

  function reorderElement(reference) {
    if (reference.kind === "project") {
      return nativeProjectItem({
        hostId: reference.hostId,
        kind: "project",
        name: reference.name,
        projectId: reference.projectId,
      });
    }
    return nativeThreadRow(reference);
  }

  function sortableSnapshot(element) {
    let itemId = null;
    const itemLists = [];
    let fiber = element ? getFiber(element) : null;
    for (let level = 0; fiber && level < 40; level += 1, fiber = fiber.return) {
      const props = fiber.memoizedProps;
      if (!itemId && typeof props?.item === "string") itemId = props.item;
      if (Array.isArray(props?.items)) itemLists.push(props.items);
    }
    const items = itemId ? itemLists.find((candidate) => candidate.includes(itemId)) : null;
    return itemId && items ? { itemId, items } : null;
  }

  function nativeKeyboardReorder(element) {
    for (let node = element, level = 0; node && level < 12; node = node.parentElement, level += 1) {
      const handler = reactProps(node)?.onKeyDownCapture;
      if (typeof handler === "function") return handler;
    }
    return null;
  }

  function reorderReference(kind, item, projectKey = null) {
    return kind === "project"
      ? { hostId: item.hostId, kind, name: item.name, projectId: item.projectId, projectKey: item.key }
      : { conversationKey: item.conversationKey, hostId: item.hostId, kind, projectKey };
  }

  function compatibleReorder(source, target) {
    if (!source || !target || source.kind !== target.kind) return false;
    if (source.kind === "project" && source.hostId !== target.hostId) return false;
    if (source.kind === "task" && (source.hostId !== target.hostId || source.projectKey !== target.projectKey)) return false;
    const sourceSnapshot = sortableSnapshot(reorderElement(source));
    const targetSnapshot = sortableSnapshot(reorderElement(target));
    return Boolean(sourceSnapshot && targetSnapshot && sourceSnapshot.items.includes(targetSnapshot.itemId));
  }

  function clearDropIndicators() {
    state.panel?.querySelectorAll(".crmp-dragging,.crmp-drop-before,.crmp-drop-after").forEach((element) => {
      element.classList.remove("crmp-dragging", "crmp-drop-before", "crmp-drop-after");
    });
  }

  function desiredReorderStep(sourceIndex, targetIndex, position) {
    const destination = position === "before"
      ? targetIndex - (sourceIndex < targetIndex ? 1 : 0)
      : targetIndex + (sourceIndex > targetIndex ? 1 : 0);
    return Math.sign(destination - sourceIndex);
  }

  function wait(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  }

  async function invokeNativeReorder(source, target, position) {
    state.reorderPending = true;
    state.lastAction = { commandId: `reorder-${source.kind}`, found: true, invoked: false, pending: true };
    try {
      for (let attempt = 0; attempt < 80; attempt += 1) {
        const sourceElement = reorderElement(source);
        const targetElement = reorderElement(target);
        const sourceSnapshot = sortableSnapshot(sourceElement);
        const targetSnapshot = sortableSnapshot(targetElement);
        if (!sourceElement || !targetElement || !sourceSnapshot || !targetSnapshot) throw new Error("Native reorder state is unavailable");
        const sourceIndex = sourceSnapshot.items.indexOf(sourceSnapshot.itemId);
        const targetIndex = sourceSnapshot.items.indexOf(targetSnapshot.itemId);
        if (sourceIndex < 0 || targetIndex < 0) throw new Error("Items are not in the same native reorder list");
        const step = desiredReorderStep(sourceIndex, targetIndex, position);
        if (step === 0) {
          state.lastAction = { commandId: `reorder-${source.kind}`, found: true, invoked: true };
          return true;
        }
        const handler = nativeKeyboardReorder(sourceElement);
        const activationTarget = sourceElement.matches('[role="button"]')
          ? sourceElement
          : sourceElement.querySelector('[role="button"]');
        if (!handler || !activationTarget) throw new Error("Native reorder callback is unavailable");
        handler({
          altKey: true,
          ctrlKey: false,
          defaultPrevented: false,
          key: step < 0 ? "ArrowUp" : "ArrowDown",
          metaKey: false,
          preventDefault() {},
          shiftKey: false,
          stopPropagation() {},
          target: activationTarget,
        });
        let moved = false;
        for (let retry = 0; retry < 20; retry += 1) {
          await wait(50);
          const next = sortableSnapshot(reorderElement(source));
          if (next && next.items.indexOf(next.itemId) !== sourceIndex) {
            moved = true;
            break;
          }
        }
        if (!moved) throw new Error("Native order did not change");
      }
      throw new Error("Native reorder exceeded the bounded move limit");
    } catch (error) {
      state.lastAction = { commandId: `reorder-${source.kind}`, error: error?.message || String(error), found: true, invoked: false };
      return false;
    } finally {
      state.reorderPending = false;
      render();
    }
  }

  function bindReorder(sourceElement, dropZone, reference) {
    const canDrag = !state.reorderPending && !nativeElementDisabled(sourceElement)
      && Boolean(nativeKeyboardReorder(reorderElement(reference)) && sortableSnapshot(reorderElement(reference)));
    sourceElement.draggable = canDrag;
    if (!canDrag) return;
    sourceElement.addEventListener("keydown", (event) => {
      if (event.defaultPrevented || !event.altKey || event.ctrlKey || event.metaKey || event.shiftKey
          || !["ArrowUp", "ArrowDown"].includes(event.key) || nativeElementDisabled(sourceElement)) return;
      const nativeElement = reorderElement(reference);
      const target = nativeElement?.matches('[role="button"]') ? nativeElement : nativeElement?.querySelector('[role="button"]');
      const handler = nativeKeyboardReorder(nativeElement);
      if (!target || !handler || nativeElementDisabled(target)) return;
      event.preventDefault();
      event.stopPropagation();
      handler({ altKey: true, ctrlKey: false, defaultPrevented: false, key: event.key, metaKey: false,
        preventDefault() {}, shiftKey: false, stopPropagation() {}, target });
      schedule();
    });
    sourceElement.addEventListener("dragstart", (event) => {
      if (!event.dataTransfer || state.reorderPending) {
        event.preventDefault();
        return;
      }
      state.drag = reference;
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("application/x-codex-mobile-reorder", reference.kind);
      dropZone.classList.add("crmp-dragging");
    });
    dropZone.addEventListener("dragover", (event) => {
      if (!compatibleReorder(state.drag, reference) || state.drag === reference) return;
      event.preventDefault();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "move";
      clearDropIndicators();
      const position = event.clientY < dropZone.getBoundingClientRect().top + dropZone.getBoundingClientRect().height / 2 ? "before" : "after";
      dropZone.classList.add(position === "before" ? "crmp-drop-before" : "crmp-drop-after");
      dropZone.dataset.dropPosition = position;
    });
    dropZone.addEventListener("dragleave", (event) => {
      if (event.relatedTarget instanceof Node && dropZone.contains(event.relatedTarget)) return;
      dropZone.classList.remove("crmp-drop-before", "crmp-drop-after");
      delete dropZone.dataset.dropPosition;
    });
    dropZone.addEventListener("drop", (event) => {
      if (!compatibleReorder(state.drag, reference) || state.drag === reference) return;
      event.preventDefault();
      const source = state.drag;
      const position = dropZone.dataset.dropPosition === "before" ? "before" : "after";
      state.drag = null;
      state.dragJustEndedAt = performance.now();
      clearDropIndicators();
      void invokeNativeReorder(source, reference, position);
    });
    sourceElement.addEventListener("dragend", () => {
      state.drag = null;
      state.dragJustEndedAt = performance.now();
      clearDropIndicators();
    });
  }

  function nativeProjectAction(project) {
    return nativeProjectItem(project)?.querySelector('button[aria-label^="Project actions for "]') ?? null;
  }

  function nativeProjectNewAction(project) {
    return nativeProjectItem(project)?.querySelector('button[aria-label^="Start new chat in "]') ?? null;
  }

  function nativeGlobalNewChatAction() {
    return [...document.querySelectorAll("button")].find((item) => {
      if (item.closest(`#${PANEL_ID}`)) return false;
      const label = item.getAttribute("aria-label") || (item.textContent || "").replace(/\s+/gu, " ").trim();
      return label === "New chat" && !item.disabled;
    }) ?? null;
  }

  function nativeProjectButtonTemplate(project, actionName) {
    const prefix = actionName === "new" ? "Start new chat in " : "Project actions for ";
    const own = nativeProjectItem(project)?.querySelector(`button[aria-label^="${prefix}"]`);
    return own ?? document.querySelector(`[data-sidebar-project-kind="local"][role="listitem"] button[aria-label^="${prefix}"]`);
  }

  function nativeProjectRowTemplate(project) {
    const action = nativeProjectButtonTemplate(project, "actions");
    return action?.closest('[class*="group/folder-row"]') ?? null;
  }

  function cloneNativeButton(template, customClass, fallbackText) {
    const clone = template?.cloneNode(true) ?? button("", fallbackText);
    clone.type = "button";
    clone.removeAttribute("id");
    clone.removeAttribute("data-state");
    clone.removeAttribute("aria-controls");
    clone.removeAttribute("aria-describedby");
    clone.classList.add(customClass);
    return clone;
  }

  function folderIconFromRow(row) {
    return [...(row?.querySelectorAll("svg") ?? [])].find((icon) => !icon.closest(".crmp-project-action,.crmp-project-new,[data-app-action-sidebar-project-menu]")) ?? null;
  }

  function plainFolderIcon(expanded) {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("width", "16");
    svg.setAttribute("height", "16");
    svg.setAttribute("viewBox", "0 0 16 16");
    svg.setAttribute("fill", "none");
    svg.classList.add("icon-xs", "shrink-0");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("fill-rule", "evenodd");
    path.setAttribute("clip-rule", "evenodd");
    path.setAttribute("fill", "currentColor");
    path.setAttribute("d", expanded ? LOCAL_FOLDER_PATH.open : LOCAL_FOLDER_PATH.closed);
    svg.append(path);
    return svg;
  }

  function nativeFolderIcon(project, expanded) {
    const row = nativeProjectRowTemplate(project);
    const ownIcon = folderIconFromRow(row);
    if (!ownIcon) return plainFolderIcon(expanded);
    // Use the current package's actual glyph when its state matches.
    // Do not overwrite native path data with an older release's icon.
    if (row.getAttribute("aria-expanded") === String(expanded)) return ownIcon.cloneNode(true);
    const item = row.closest("[data-sidebar-project-kind]");
    const nativeKind = item?.getAttribute("data-sidebar-project-kind");
    const desiredCollapsed = String(!expanded);
    const template = [...document.querySelectorAll(`[data-sidebar-project-kind="${CSS.escape(nativeKind || "local")}"] [data-app-action-sidebar-project-collapsed="${desiredCollapsed}"]`)]
      .map(folderIconFromRow)
      .find(Boolean);
    if (template) return template.cloneNode(true);
    const icon = ownIcon.cloneNode(true);
    const paths = [...icon.querySelectorAll("path")];
    const folderPath = paths.at(-1);
    folderPath?.setAttribute("d", expanded ? LOCAL_FOLDER_PATH.open : LOCAL_FOLDER_PATH.closed);
    return icon;
  }

  function nativeProjectCommands(project) {
    const action = nativeProjectAction(project);
    let fiber = action ? getFiber(action) : null;
    for (let level = 0; fiber && level < 16; level += 1, fiber = fiber.return) {
      const factory = fiber.memoizedProps?.getNativeItems;
      if (typeof factory === "function") {
        const commands = factory();
        return Array.isArray(commands) ? commands : [];
      }
    }
    return [];
  }

  function nativeProjectCallback(project, callbackName) {
    const action = nativeProjectAction(project);
    let fiber = action ? getFiber(action) : null;
    for (let level = 0; fiber && level < 20; level += 1, fiber = fiber.return) {
      const callback = fiber.memoizedProps?.[callbackName];
      if (typeof callback === "function") return callback;
    }
    return null;
  }

  function findCompactHookFunction(value, predicate, depth = 0, seen = new WeakSet()) {
    if (typeof value === "function") return predicate(value) ? value : null;
    if (!value || typeof value !== "object" || depth > 8 || seen.has(value) || value.nodeType) return null;
    seen.add(value);
    const entries = Array.isArray(value) ? value.slice(0, 40).entries() : Object.entries(value).slice(0, 80);
    for (const [name, item] of entries) {
      if (["alternate", "child", "return", "sibling", "stateNode"].includes(String(name))) continue;
      const found = findCompactHookFunction(item, predicate, depth + 1, seen);
      if (found) return found;
    }
    return null;
  }

  function isTwoArgumentDispatcherProxy(candidate) {
    if (typeof candidate !== "function") return false;
    const source = Function.prototype.toString.call(candidate);
    return /^e=>\{[A-Za-z_$][\w$]*\(t,e\)\}$/u.test(source);
  }

  function nativeStartThreadDispatcher() {
    const item = document.querySelector('[data-sidebar-project-kind="local"][role="listitem"]')
      ?? document.querySelector('[data-sidebar-project-kind][role="listitem"]')
      ?? document.querySelector(ROW_SELECTOR);
    let fiber = item ? getFiber(item) : null;
    for (let level = 0; fiber && level < 12; level += 1, fiber = fiber.return) {
      const direct = fiber.memoizedState?.next?.next?.memoizedState?.next?.deps?.[0];
      if (isTwoArgumentDispatcherProxy(direct)) return direct;
      for (const candidate of [fiber.memoizedState, fiber.updateQueue]) {
        const found = findCompactHookFunction(candidate, (fn) => {
          const source = Function.prototype.toString.call(fn);
          return source.length < 180 && (source.includes("xbl(") || source.includes("Tyl("));
        });
        if (found) return found;
      }
    }
    return null;
  }

  function nativeNavigationDispatcher() {
    const item = document.querySelector('[data-sidebar-project-kind="local"][role="listitem"]')
      ?? document.querySelector('[data-sidebar-project-kind][role="listitem"]')
      ?? document.querySelector(ROW_SELECTOR);
    let fiber = item ? getFiber(item) : null;
    for (let level = 0; fiber && level < 12; level += 1, fiber = fiber.return) {
      const direct = fiber.updateQueue?.memoCache?.data?.[1]?.[1];
      if (isTwoArgumentDispatcherProxy(direct)) return direct;
      for (const candidate of [fiber.memoizedState, fiber.updateQueue]) {
        const found = findCompactHookFunction(candidate, (fn) => {
          const source = Function.prototype.toString.call(fn);
          return source.length < 180 && (source.includes("M0(") || source.includes("j0(")) && !source.includes("xbl(") && !source.includes("Tyl(");
        });
        if (found) return found;
      }
    }
    return null;
  }

  function nativeThreadAction(task, actionName) {
    const labels = actionName === "pin" ? ["Pin chat", "Unpin chat"] : ["Archive chat"];
    return [...(task.originalRow?.querySelectorAll("button[aria-label]") ?? [])].find((item) => labels.includes(item.getAttribute("aria-label"))) ?? null;
  }

  function invokeNativeThreadAction(task, actionName) {
    const action = nativeThreadAction(task, actionName);
    if (!action) {
      state.lastAction = { actionName, found: false, hostId: task.hostId, task: task.title };
      return;
    }
    try {
      const invoked = invokeNativeElement(action);
      state.lastAction = { actionName, found: true, hostId: task.hostId, invoked, task: task.title };
    } catch (error) {
      state.lastAction = { actionName, error: error?.message || String(error), found: true, hostId: task.hostId, invoked: false, task: task.title };
    }
  }

  async function openNativeTask(task) {
    const nativeRow = nativeThreadRow(task) ?? task.originalRow;
    if (nativeRow?.isConnected) {
      return invokeNativeElement(nativeRow);
    }
    const conversationId = task.conversationId || rawConversationId(task.conversationKey);
    const manager = state.threadManagers.get(task.hostId);
    try {
      if (task.sourceThread && typeof manager?.upsertConversationFromThread === "function") manager.upsertConversationFromThread(task.sourceThread);
      manager?.activateThreadSummary?.(conversationId, { addToRecent: false });
      manager?.ensureRecentConversationId?.(conversationId);
      if (manager) {
        try {
          const hydratedRow = await waitFor(() => nativeThreadRow(task), 3000);
          hydratedRow.click();
          return true;
        } catch {}
      }
      const markRead = manager?.markConversationAsRead?.(conversationId);
      if (markRead?.catch) void markRead.catch(() => {});
      if (typeof state.navigationBridge?.navigateToLocalConversation !== "function") throw new Error("Native conversation navigation is unavailable");
      state.navigationBridge.navigateToLocalConversation(conversationId, task.hostId === "local" ? undefined : task.hostId);
      task.unread = false;
      state.lastAction = { commandId: "open-thread", conversationId, found: true, hostId: task.hostId, invoked: true };
      return true;
    } catch (error) {
      state.lastAction = { commandId: "open-thread", conversationId, error: error?.message || String(error), found: true, hostId: task.hostId, invoked: false };
      return false;
    }
  }

  function waitFor(check, timeoutMilliseconds = 15000) {
    const deadline = Date.now() + timeoutMilliseconds;
    return new Promise((resolve, reject) => {
      const poll = () => {
        try {
          const result = check();
          if (result) return resolve(result);
        } catch {}
        if (Date.now() >= deadline) return reject(new Error("Timed out waiting for the native remote-project flow"));
        setTimeout(poll, 100);
      };
      poll();
    });
  }

  function setNativeInputValue(input, value) {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")?.set;
    if (!setter) throw new Error("Native input value setter is unavailable");
    setter.call(input, value);
    input.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function remoteProjectDialog() {
    return [...document.querySelectorAll('[role="dialog"],.codex-dialog')]
      .find((item) => /New remote project/i.test(item.innerText || "")) ?? null;
  }

  function dismissAutoRegistrationDialog(dialog) {
    if (!dialog?.isConnected) return false;
    const cancel = [...dialog.querySelectorAll("button")]
      .find((item) => /^(Cancel|Close)$/i.test((item.innerText || item.getAttribute("aria-label") || "").trim()));
    if (!cancel) return false;
    cancel.click();
    return true;
  }

  async function registerRemoteProjectAndOpen(project, navigate, onDialog = null) {
    navigate({
      activeProject: null,
      pendingRemoteProjectHostId: project.hostId,
      pendingViewAction: "open-create-remote-project-modal",
      prefillComposerMode: "local",
    });
    const dialog = await waitFor(remoteProjectDialog);
    onDialog?.(dialog);
    const inputs = [...dialog.querySelectorAll("input")];
    const nameInput = inputs.find((input) => /project name/i.test(input.placeholder || "")) ?? null;
    const sourceLabel = [...dialog.querySelectorAll("label")].find((label) => /source folder/i.test(label.innerText || "")) ?? null;
    const pathInput = sourceLabel?.querySelector("input") ?? inputs.find((input) => input !== nameInput) ?? null;
    if (!nameInput || !pathInput || !project.cwd) throw new Error("Native remote-project fields were not found");
    setNativeInputValue(nameInput, project.name);
    setNativeInputValue(pathInput, project.cwd);
    pathInput.dispatchEvent(new FocusEvent("blur", { bubbles: true }));
    const submit = await waitFor(() => {
      const candidate = [...dialog.querySelectorAll('button[type="submit"],button')]
        .find((item) => /^Add project$/i.test((item.innerText || "").trim()));
      return candidate && !candidate.disabled ? candidate : null;
    }, 20000);
    submit.click();
    await waitFor(() => !document.contains(dialog), 30000);
    await waitForRegisteredProject(project);
  }

  function autoRegistrationCandidate(model) {
    if (!readBoolean(AUTO_ENABLED_KEY)
      || state.autoRegistrationPending
      || state.autoReconciliationPending
      || state.localRegisteredProjectsPending
      || state.localRegisteredProjectsError
      || !state.localRegisteredProjectsFetchedAt
      || Date.now() - state.localRegisteredProjectsFetchedAt > LOCAL_REMOTE_PROJECTS_TTL_MS
      || remoteProjectDialog()) return null;
    const now = Date.now();
    return model.projects.find((project) => {
      const identity = projectIdentity(project);
      const retryAfter = identity ? state.autoRegistrationFailures.get(identity) : null;
      const host = model.hosts.find((item) => item.id === project.hostId);
      const inventory = authoritativeInventory(project.hostId);
      return project.hostId !== "local"
        && host?.availabilityKnown === true
        && host.available === true
        && inventoryContainsProject(inventory, project)
        && !project.projectId
        && Boolean(project.cwd)
        && (project.tasks.length > 0 || project.source === "host-projects")
        && !hasRecord(AUTO_MANAGED_KEY, project)
        && !hasRecord(AUTO_SUPPRESSED_KEY, project)
        && (!retryAfter || retryAfter <= now);
    }) ?? null;
  }

  async function setGlobalStateValue(key, value) {
    if (typeof state.localFetchFromHost !== "function") throw new Error("Local project-state bridge is unavailable");
    const result = await fetchFromHostWithTimeout(state.localFetchFromHost, "set-global-state", { params: { key, value } });
    if (result?.success === false) throw new Error(`Failed to update ${key}`);
  }

  function threadActivityTime(thread) {
    const values = [thread?.updatedAt, thread?.recencyAt, thread?.createdAt].map((value) => {
      if (typeof value === "number") return value < 100000000000 ? value * 1000 : value;
      if (typeof value === "string") return Date.parse(value);
      return Number.NaN;
    }).filter(Number.isFinite);
    return values.length ? Math.max(...values) : Number.NaN;
  }

  function lexicalAbsolutePath(value) {
    const canonical = canonicalRemotePath(value);
    if (!canonical) return null;
    const slashPath = canonical.replace(/\\/gu, "/");
    const windowsDrive = slashPath.match(/^([a-z]:)(?:\/|$)/iu);
    const uncParts = slashPath.startsWith("//") ? slashPath.slice(2).split("/").filter(Boolean) : [];
    const isUnc = uncParts.length >= 2;
    const isPosix = !windowsDrive && !isUnc && slashPath.startsWith("/");
    if (!windowsDrive && !isUnc && !isPosix) return null;
    const root = windowsDrive ? windowsDrive[1]
      : isUnc ? `//${uncParts[0]}/${uncParts[1]}`
      : "";
    const remainder = windowsDrive ? slashPath.slice(windowsDrive[0].length)
      : isUnc ? uncParts.slice(2).join("/")
      : slashPath.slice(1);
    const segments = [];
    for (const segment of remainder.split("/")) {
      if (!segment || segment === ".") continue;
      if (segment === "..") {
        if (!segments.length) return null;
        segments.pop();
      } else {
        segments.push(segment);
      }
    }
    const normalized = `${root}/${segments.join("/")}`.replace(/\/+$/u, "") || "/";
    const caseInsensitive = Boolean(windowsDrive || isUnc);
    return { caseInsensitive, value: caseInsensitive ? normalized.toLocaleLowerCase() : normalized };
  }

  function maintenanceThreadPathManaged(thread, archived, requirePath = archived === true) {
    const threadPath = typeof thread?.path === "string" && thread.path.trim() ? thread.path : null;
    if (!threadPath || !state.localCodexHome) return requirePath !== true;
    const home = lexicalAbsolutePath(state.localCodexHome);
    const candidate = lexicalAbsolutePath(threadPath);
    if (!home || !candidate || home.caseInsensitive !== candidate.caseInsensitive) return false;
    const directory = archived ? "archived_sessions" : "sessions";
    const root = `${home.value}/${directory}`;
    return candidate.value === root || candidate.value.startsWith(`${root}/`);
  }

  function unmanagedMaintenanceThreadCount(threads, archived) {
    return threads.filter((thread) => !maintenanceThreadPathManaged(thread, archived, archived === true)).length;
  }

  function sanitizedMaintenanceFailure(operation, error) {
    const message = String(error?.message ?? error ?? "");
    const action = operation === "delete" ? "Delete" : "Archive";
    if (/timed out|bounded deadline/iu.test(message)) return `${action} timed out`;
    if (/runtime changed/iu.test(message)) return `${action} stopped because the local runtime changed`;
    if (/outside|rollout path|sessions directory/iu.test(message)) return `${action} skipped a chat outside the managed Codex sessions directory`;
    if (/not found/iu.test(message)) return `${action} could not find the chat`;
    if (/permission|access denied|unauthorized|forbidden/iu.test(message)) return `${action} was denied by the local app-server`;
    return `${action} was rejected by the local app-server`;
  }

  function maintenanceDeadlineError(phase) {
    return new Error(`${phase} reached its bounded deadline`);
  }

  function remainingRequestTimeout(deadline, phase) {
    if (!Number.isFinite(deadline)) return 30000;
    const remaining = Math.floor(deadline - Date.now());
    if (remaining <= 0) throw maintenanceDeadlineError(phase);
    return Math.max(1, Math.min(30000, remaining));
  }

  function quarantineLocalThreadListClient(requestClient, runtimeGeneration, settlement) {
    const existing = state.localThreadListQuarantines.get(requestClient);
    if (existing) return existing;
    const quarantine = { runtimeGeneration, settlement };
    state.localThreadListQuarantines.set(requestClient, quarantine);
    sharedThreadListRegistry.activeQuarantineCount += 1;
    markLocalThreadListRecoveryPending("Local app-server request recovery is waiting for a distinct client");
    if (state.localRuntime?.requestClient === requestClient && state.localRuntimeGeneration === runtimeGeneration) {
      state.localRuntimeGeneration += 1;
      state.localRuntime = null;
      state.remoteRuntimeScannedAt = 0;
    }
    void settlement.finally(() => {
      if (state.localThreadListQuarantines.get(requestClient) === quarantine) {
        state.localThreadListQuarantines.delete(requestClient);
        sharedThreadListRegistry.activeQuarantineCount = Math.max(0, sharedThreadListRegistry.activeQuarantineCount - 1);
        state.remoteRuntimeScannedAt = 0;
        if (!state.disposed) schedule();
      }
    });
    return quarantine;
  }

  function markLocalThreadListRecoveryPending(reason) {
    sharedThreadListRegistry.recoveryPending = true;
    sharedThreadListRegistry.recoveryReason = reason;
    const previousInventory = state.threadInventories.get("local");
    state.threadInventories.set("local", {
      ...(previousInventory ?? {}),
      error: reason,
      fetchedAt: Date.now(),
      hostId: "local",
      pages: previousInventory?.pages ?? 0,
      retryAt: Date.now() + NATIVE_INVENTORY_ERROR_RETRY_MS,
      threads: previousInventory?.threads ?? [],
    });
    state.inventoryHydrationError = reason;
  }

  function clearLocalThreadListRecovery(requestClient, runtimeGeneration) {
    if (!sharedThreadListRegistry.recoveryPending
      || sharedThreadListRegistry.legacySuspects.has(requestClient)
      || state.localThreadListQuarantines.has(requestClient)
      || state.localRuntime?.requestClient !== requestClient
      || state.localRuntimeGeneration !== runtimeGeneration) return;
    sharedThreadListRegistry.recoveryPending = false;
    sharedThreadListRegistry.recoveryReason = null;
    const localInventory = state.threadInventories.get("local");
    if (localInventory) state.threadInventories.set("local", { ...localInventory, error: null, retryAt: 0 });
    state.inventoryHydrationError = null;
  }

  function enqueueLocalThreadList(requestClient, runtimeGeneration, deadline, phase, operation) {
    if (typeof requestClient?.sendRequest !== "function") return Promise.reject(new Error(`${phase}: local app-server bridge is unavailable`));
    if (state.localThreadListQuarantines.has(requestClient)) {
      return Promise.reject(new Error(`${phase}: local app-server request client is quarantined until its timed-out request settles`));
    }
    const token = { cancelled: false };
    const pendingRequestSettlements = [];
    let gateRecord = state.localThreadListGates.get(requestClient);
    if (!gateRecord || gateRecord.runtimeGeneration !== runtimeGeneration) {
      gateRecord = { gate: Promise.resolve(), runtimeGeneration };
      state.localThreadListGates.set(requestClient, gateRecord);
    }
    const predecessor = Promise.resolve(gateRecord.gate).catch(() => {});
    const execution = predecessor.then(async () => {
      if (token.cancelled || Date.now() >= deadline) throw maintenanceDeadlineError(`${phase} while waiting for the local thread/list gate`);
      if (state.localRuntime?.requestClient !== requestClient || state.localRuntimeGeneration !== runtimeGeneration) {
        throw new Error(`${phase}: local app-server runtime changed before listing`);
      }
      return operation((params) => {
        if (token.cancelled) throw maintenanceDeadlineError(phase);
        if (state.localRuntime?.requestClient !== requestClient || state.localRuntimeGeneration !== runtimeGeneration) {
          throw new Error(`${phase}: local app-server runtime changed during listing`);
        }
        const timeoutMilliseconds = remainingRequestTimeout(deadline, phase);
        let underlyingSettled = false;
        const underlying = Promise.resolve().then(() => requestClient.sendRequest("thread/list", params));
        const settlement = underlying.then(
          () => { underlyingSettled = true; },
          () => { underlyingSettled = true; },
        );
        let activeRequests = sharedThreadListRegistry.activeRequests.get(requestClient);
        if (!activeRequests) {
          activeRequests = new Set();
          sharedThreadListRegistry.activeRequests.set(requestClient, activeRequests);
        }
        activeRequests.add(settlement);
        state.localThreadListActiveClients.add(requestClient);
        void settlement.finally(() => {
          activeRequests.delete(settlement);
          if (!activeRequests.size) {
            sharedThreadListRegistry.activeRequests.delete(requestClient);
            state.localThreadListActiveClients.delete(requestClient);
          }
        });
        pendingRequestSettlements.push(settlement);
        return withTimeout(underlying, `thread/list (${phase})`, timeoutMilliseconds).catch((error) => {
          if (!underlyingSettled && error?.code === "CODEX_REMOTE_REQUEST_TIMEOUT") {
            quarantineLocalThreadListClient(requestClient, runtimeGeneration, settlement);
          }
          throw error;
        });
      });
    });
    gateRecord.gate = execution
      .then(() => Promise.allSettled(pendingRequestSettlements), () => Promise.allSettled(pendingRequestSettlements))
      .then(() => undefined, () => undefined);
    if (!Number.isFinite(deadline)) return execution;
    const waitMilliseconds = Math.max(1, deadline - Date.now());
    let timer = null;
    const timeout = new Promise((resolve, reject) => {
      timer = setTimeout(() => {
        token.cancelled = true;
        if (pendingRequestSettlements.length) {
          quarantineLocalThreadListClient(requestClient, runtimeGeneration, Promise.allSettled(pendingRequestSettlements));
        }
        reject(maintenanceDeadlineError(phase));
      }, waitMilliseconds);
    });
    return Promise.race([execution, timeout]).finally(() => {
      if (timer !== null) clearTimeout(timer);
    });
  }

  async function listAllRuntimeThreads(requestClient, archived = false, deadline = Number.POSITIVE_INFINITY, includeInternalSources = false, requestThreadList = null, phase = "thread inventory") {
    if (typeof requestClient?.sendRequest !== "function") throw new Error("App-server bridge is unavailable");
    const threads = [];
    const threadIds = new Set();
    const cursors = new Set();
    let cursor = null;
    for (let page = 0; page < MAX_THREAD_LIST_PAGES; page += 1) {
      if (Date.now() >= deadline) throw maintenanceDeadlineError(phase);
      const params = {
        archived: archived === true,
        cursor,
        limit: 49,
        sourceKinds: includeInternalSources ? MAINTENANCE_THREAD_SOURCE_KINDS : USER_VISIBLE_THREAD_SOURCE_KINDS,
        sortDirection: "desc",
        sortKey: "updated_at",
      };
      if (includeInternalSources) params.useStateDbOnly = true;
      const result = requestThreadList
        ? await requestThreadList(params)
        : await sendRequestWithTimeout(requestClient, "thread/list", params, remainingRequestTimeout(deadline, phase));
      if (state.disposed) return { pages: page + 1, threads: [] };
      if (!result || typeof result !== "object" || !Array.isArray(result.data)) throw new Error("thread/list returned malformed data");
      if (!(result.nextCursor === null || (typeof result.nextCursor === "string" && result.nextCursor.length > 0))) {
        throw new Error("thread/list returned a malformed pagination cursor");
      }
      for (const thread of result.data) {
        if (!thread || typeof thread !== "object") throw new Error("thread/list returned a malformed thread entry");
        const threadId = rawConversationId(thread?.id ?? thread?.conversationId ?? "");
        if (!threadId) throw new Error("thread/list returned a thread without an identity");
        if (includeInternalSources) {
          const status = typeof thread.status === "string" ? thread.status : thread?.status?.type;
          if (typeof status !== "string" || !status.trim()) throw new Error("thread/list returned a thread without an authoritative status");
        }
        if (threadIds.has(threadId)) continue;
        threadIds.add(threadId);
        threads.push(thread);
      }
      const nextCursor = result.nextCursor;
      if (!nextCursor) return { pages: page + 1, threads };
      if (cursors.has(nextCursor)) throw new Error("thread/list returned a repeated pagination cursor");
      cursors.add(nextCursor);
      cursor = nextCursor;
    }
    if (includeInternalSources) throw new Error("thread/list exceeded the bounded page limit");
    return { pages: MAX_THREAD_LIST_PAGES, threads, truncated: true };
  }

  async function listAllLocalThreadInventory(requestClient, archived = false, deadline = Number.POSITIVE_INFINITY, includeInternalSources = true, phase = "local thread listing", runtimeGeneration = state.localRuntimeGeneration) {
    const result = await enqueueLocalThreadList(requestClient, runtimeGeneration, deadline, phase, async (requestThreadList) => (
      listAllRuntimeThreads(requestClient, archived, deadline, includeInternalSources, requestThreadList, phase)
    ));
    if (includeInternalSources === false && archived === false) {
      sharedThreadListRegistry.lastLocalInventory = {
        fetchedAt: Date.now(),
        pages: result.pages,
        threads: Array.isArray(result.threads) ? result.threads : [],
        truncated: result.truncated === true,
      };
      clearLocalThreadListRecovery(requestClient, runtimeGeneration);
    }
    return result;
  }

  async function listAllLocalThreads(requestClient, archived = false, deadline = Number.POSITIVE_INFINITY, includeInternalSources = true, phase = "local thread listing", runtimeGeneration = state.localRuntimeGeneration) {
    return listAllLocalThreadInventory(requestClient, archived, deadline, includeInternalSources, phase, runtimeGeneration)
      .then((result) => result.threads);
  }

  function updateActivityFailureReason(error) {
    const message = String(error?.message ?? error ?? "");
    if (/timed out|bounded deadline/iu.test(message)) return "Authoritative activity scan timed out";
    if (/quarantined|recovery|runtime changed/iu.test(message)) return "Local app-server activity is recovering";
    return "Authoritative activity state is unavailable";
  }

  async function updateActivity() {
    state.counters.updateActivityScans += 1;
    const requestClient = state.localRuntime?.requestClient;
    const runtimeGeneration = state.localRuntimeGeneration;
    if (state.disposed || typeof requestClient?.sendRequest !== "function") {
      return { busy: false, known: false, reason: "Local app-server runtime is unavailable" };
    }
    if (sharedThreadListRegistry.recoveryPending || state.localThreadListQuarantines.has(requestClient)) {
      return { busy: false, known: false, reason: "Local app-server activity is recovering" };
    }
    try {
      const deadline = Date.now() + 30000;
      const result = await listAllLocalThreadInventory(requestClient, false, deadline, true, "update activity snapshot", runtimeGeneration);
      if (state.disposed || state.localRuntime?.requestClient !== requestClient || state.localRuntimeGeneration !== runtimeGeneration) {
        return { busy: false, known: false, reason: "Local app-server runtime changed during activity scan" };
      }
      if (result.truncated === true) return { busy: false, known: false, reason: "Authoritative activity inventory is incomplete" };
      let busy = false;
      for (const thread of result.threads) {
        const statusObject = thread?.status && typeof thread.status === "object" ? thread.status : null;
        const flags = statusObject?.activeFlags;
        if (Array.isArray(flags) && flags.some((flag) => flag === "waitingOnApproval" || flag === "waitingOnUserInput")) {
          busy = true;
          continue;
        }
        const rawStatus = typeof thread?.status === "string" ? thread.status : statusObject?.type;
        const status = typeof rawStatus === "string" ? rawStatus.replace(/[_-]/gu, "").toLowerCase() : "";
        if (ACTIVITY_BUSY_STATUSES.has(status)) busy = true;
        else if (!ACTIVITY_IDLE_STATUSES.has(status)) {
          return { busy: false, known: false, reason: "Authoritative activity status is unknown" };
        }
      }
      return { busy, known: true };
    } catch (error) {
      return { busy: false, known: false, reason: updateActivityFailureReason(error) };
    }
  }

  function eligibleAutoArchiveThreads(threads, pinnedThreadIds = new Set(), relatedThreads = threads) {
    const cutoff = Date.now() - AUTO_ARCHIVE_DAYS * 24 * 60 * 60 * 1000;
    const parentsWithActiveChildren = new Set(relatedThreads
      .map((thread) => typeof thread?.parentThreadId === "string" ? thread.parentThreadId : null)
      .filter(Boolean));
    const protectedIds = new Set([...document.querySelectorAll(ROW_SELECTOR)]
      .filter((row) => row.getAttribute("data-app-action-sidebar-thread-selected") === "true" || metadataFromRow(row).statusType === "loading")
      .map((row) => rawConversationId(row.getAttribute("data-app-action-sidebar-thread-id")))
      .filter(Boolean));
    return threads.filter((thread) => {
      const threadId = typeof thread?.id === "string" ? thread.id : null;
      const statusType = typeof thread?.status === "string" ? thread.status : thread?.status?.type;
      const activityAt = threadActivityTime(thread);
      return Boolean(threadId)
        && maintenanceThreadPathManaged(thread, false)
        && !parentsWithActiveChildren.has(threadId)
        && !protectedIds.has(threadId)
        && !pinnedThreadIds.has(threadId)
        && thread.selected !== true
        && thread.isSelected !== true
        && thread.isPinned !== true
        && thread.pinned !== true
        && statusType === "notLoaded"
        && Number.isFinite(activityAt)
        && activityAt < cutoff;
    });
  }

  function synchronizeTrackedArchivedThreads(archivedThreads, persist = true) {
    const records = readRecords(AUTO_ARCHIVED_RECORDS_KEY);
    const archivedIds = new Set(archivedThreads.map((thread) => thread?.id).filter((id) => typeof id === "string"));
    let changed = false;
    for (const threadId of Object.keys(records)) {
      if (!archivedIds.has(threadId)) {
        delete records[threadId];
        changed = true;
      }
    }
    const now = Date.now();
    for (const threadId of archivedIds) {
      if (!Number.isFinite(Number(records[threadId]))) {
        records[threadId] = now;
        changed = true;
      }
    }
    if (changed && persist) writeRecords(AUTO_ARCHIVED_RECORDS_KEY, records);
    return records;
  }

  function eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords, minimumArchivedAgeMs = AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000, pinnedThreadIds = new Set()) {
    const cutoff = Date.now() - minimumArchivedAgeMs;
    const parentsWithKnownChildren = new Set([...activeThreads, ...archivedThreads]
      .map((thread) => typeof thread?.parentThreadId === "string" ? thread.parentThreadId : null)
      .filter(Boolean));
    return archivedThreads.filter((thread) => {
      const threadId = typeof thread?.id === "string" ? thread.id : null;
      const statusType = typeof thread?.status === "string" ? thread.status : thread?.status?.type;
      const archivedAt = Number(archiveRecords?.[threadId]);
      return Boolean(threadId)
        && maintenanceThreadPathManaged(thread, true, true)
        && !parentsWithKnownChildren.has(threadId)
        && !pinnedThreadIds.has(threadId)
        && thread.selected !== true
        && thread.isSelected !== true
        && thread.isPinned !== true
        && thread.pinned !== true
        && statusType === "notLoaded"
        && Number.isFinite(archivedAt)
        && archivedAt < cutoff;
    });
  }

  async function previewAutoArchive() {
    const requestClient = state.localRuntime?.requestClient;
    const runtimeGeneration = state.localRuntimeGeneration;
    const deadline = Date.now() + AUTO_MAINTENANCE_RUN_LIMIT_MS;
    if (typeof requestClient?.sendRequest !== "function") throw new Error("Local app-server bridge is unavailable");
    const activeThreads = await listAllLocalThreads(requestClient, false, deadline, true, "maintenance preview active snapshot", runtimeGeneration);
    const archivedThreads = await listAllLocalThreads(requestClient, true, deadline, true, "maintenance preview archived snapshot", runtimeGeneration);
    const pinnedResult = typeof state.localFetchFromHost === "function"
      ? await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "pinned-thread-ids" } }).catch(() => ({ value: [] }))
      : { value: [] };
    const pinnedThreadIds = new Set(Array.isArray(pinnedResult?.value) ? pinnedResult.value : []);
    const archiveEligible = eligibleAutoArchiveThreads(activeThreads, pinnedThreadIds, [...activeThreads, ...archivedThreads]).length;
    const archiveRecords = readRecords(AUTO_ARCHIVED_RECORDS_KEY);
    const deleteEligible = eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords, AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000, pinnedThreadIds).length;
    return {
      archiveEligible,
      archivedScanned: archivedThreads.length,
      deleteEligible,
      untrackedArchived: archivedThreads.filter((thread) => typeof thread?.id === "string" && !Number.isFinite(Number(archiveRecords[thread.id]))).length,
      eligible: archiveEligible,
      scanned: activeThreads.length,
      unmanagedActiveSkipped: unmanagedMaintenanceThreadCount(activeThreads, false),
      unmanagedArchivedSkipped: unmanagedMaintenanceThreadCount(archivedThreads, true),
    };
  }

  async function runAutoArchiveWithLease() {
    if (state.autoArchivePending || state.disposed) return state.autoArchiveLastResult ?? { archived: 0, eligible: 0 };
    if (!readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) return { archived: 0, eligible: 0, skipped: "auto-archive-disabled" };
    const requestClient = state.localRuntime?.requestClient;
    const runtimeGeneration = state.localRuntimeGeneration;
    const fetchFromHost = state.localFetchFromHost;
    if (typeof requestClient?.sendRequest !== "function") {
      state.autoArchiveError = "Local app-server bridge is unavailable";
      scheduleAutoArchive(AUTO_ARCHIVE_RETRY_MS);
      return { archived: 0, eligible: 0, error: state.autoArchiveError };
    }
    if (!acquireAutoArchiveLease()) {
      scheduleAutoArchive(AUTO_ARCHIVE_RETRY_MS);
      return { archived: 0, deleted: 0, eligible: 0, skipped: "maintenance-running-in-another-window" };
    }
    const generation = state.autoArchiveGeneration;
    const runDeadline = Date.now() + AUTO_MAINTENANCE_RUN_LIMIT_MS;
    let leaseLost = false;
    let timeLimitReached = false;
    let maintenanceContinuationNeeded = false;
    state.autoArchiveLeaseTimer = setInterval(() => {
      if (!acquireAutoArchiveLease()) {
        leaseLost = true;
        state.autoArchiveGeneration += 1;
      }
    }, 30000);
    state.autoArchivePending = true;
    state.autoArchiveError = null;
    const archiveFailures = [];
    const deleteFailures = [];
    let archived = 0;
    let deleted = 0;
    const assertCapturedRuntime = (phase) => {
      if (state.localRuntime?.requestClient !== requestClient || state.localRuntimeGeneration !== runtimeGeneration) {
        throw new Error(`Local app-server runtime changed ${phase}`);
      }
    };
    try {
      const activeThreads = await listAllLocalThreads(requestClient, false, runDeadline, true, "maintenance active snapshot", runtimeGeneration);
      const archivedThreads = await listAllLocalThreads(requestClient, true, runDeadline, true, "maintenance archived snapshot", runtimeGeneration);
      if (typeof fetchFromHost !== "function") throw new Error("Local project-state bridge is unavailable for pinned-chat protection");
      const pinnedResult = await fetchFromHostWithTimeout(fetchFromHost, "get-global-state", { params: { key: "pinned-thread-ids" } }, remainingRequestTimeout(runDeadline, "maintenance pinned-chat snapshot"));
      if (!Array.isArray(pinnedResult?.value)) throw new Error("Pinned chat state did not contain a valid thread list");
      const pinnedThreadIds = new Set(pinnedResult.value.filter((id) => typeof id === "string"));
      const archiveRecords = synchronizeTrackedArchivedThreads(archivedThreads, false);
      const deleteCandidates = eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords, AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000, pinnedThreadIds).slice(0, AUTO_MAINTENANCE_BATCH_LIMIT);
      const archiveCandidates = eligibleAutoArchiveThreads(activeThreads, pinnedThreadIds, [...activeThreads, ...archivedThreads]).slice(0, AUTO_MAINTENANCE_BATCH_LIMIT);
      const deleteThread = deleteCandidates[0] ?? null;
      const archiveThread = deleteThread ? null : archiveCandidates[0] ?? null;
      maintenanceContinuationNeeded = deleteCandidates.length + archiveCandidates.length > 1;
      if ((deleteThread || archiveThread) && Date.now() >= runDeadline) timeLimitReached = true;
      if (deleteThread && Date.now() < runDeadline && !state.disposed && generation === state.autoArchiveGeneration && readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) {
        try {
          if (!acquireAutoArchiveLease()) {
            leaseLost = true;
          } else {
            assertCapturedRuntime("before delete revalidation");
            const currentPinnedResult = await fetchFromHostWithTimeout(fetchFromHost, "get-global-state", { params: { key: "pinned-thread-ids" } }, remainingRequestTimeout(runDeadline, "maintenance delete pinned-chat check"));
            if (!Array.isArray(currentPinnedResult?.value)) throw new Error("Pinned chat state became unavailable during cleanup");
            const currentPinned = new Set(currentPinnedResult.value);
            const currentActive = await listAllLocalThreads(requestClient, false, runDeadline, true, "maintenance delete active revalidation", runtimeGeneration);
            const currentArchived = await listAllLocalThreads(requestClient, true, runDeadline, true, "maintenance delete archived revalidation", runtimeGeneration);
            assertCapturedRuntime("after delete revalidation");
            const currentArchiveRecords = readRecords(AUTO_ARCHIVED_RECORDS_KEY);
            const currentDomTask = [...document.querySelectorAll(ROW_SELECTOR)].map(metadataFromRow).find((task) => task.conversationId === deleteThread.id);
            const currentDeleteEligible = eligibleAutoDeleteThreads(currentArchived, currentActive, currentArchiveRecords, AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000, currentPinned);
            const currentArchiveEligible = eligibleAutoArchiveThreads(currentActive, currentPinned, [...currentActive, ...currentArchived]);
            const stillEligible = !currentPinned.has(deleteThread.id)
              && !currentDomTask?.selected
              && currentDomTask?.statusType !== "loading"
              && currentDeleteEligible.some((candidate) => candidate.id === deleteThread.id);
            maintenanceContinuationNeeded ||= currentDeleteEligible.length + currentArchiveEligible.length > (stillEligible ? 1 : 0);
            if (stillEligible) {
              if (!acquireAutoArchiveLease()) {
                leaseLost = true;
              } else if (Date.now() >= runDeadline || generation !== state.autoArchiveGeneration) {
                timeLimitReached = true;
              } else {
                assertCapturedRuntime("before delete");
                await sendRequestWithTimeout(requestClient, "thread/delete", { threadId: deleteThread.id }, remainingRequestTimeout(runDeadline, "maintenance delete"));
                assertCapturedRuntime("after delete");
                delete archiveRecords[deleteThread.id];
                deleted = 1;
              }
            }
          }
        } catch (error) {
          assertCapturedRuntime("during delete cleanup");
          deleteFailures.push({ error: sanitizedMaintenanceFailure("delete", error) });
        }
      }
      if (archiveThread && Date.now() < runDeadline && !state.disposed && generation === state.autoArchiveGeneration && readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) {
        try {
          if (!acquireAutoArchiveLease()) {
            leaseLost = true;
          } else {
            assertCapturedRuntime("before archive revalidation");
            const currentPinnedResult = await fetchFromHostWithTimeout(fetchFromHost, "get-global-state", { params: { key: "pinned-thread-ids" } }, remainingRequestTimeout(runDeadline, "maintenance archive pinned-chat check"));
            if (!Array.isArray(currentPinnedResult?.value)) throw new Error("Pinned chat state became unavailable during cleanup");
            const currentPinned = new Set(currentPinnedResult.value);
            const currentActive = await listAllLocalThreads(requestClient, false, runDeadline, true, "maintenance archive active revalidation", runtimeGeneration);
            const currentArchived = await listAllLocalThreads(requestClient, true, runDeadline, true, "maintenance archive archived revalidation", runtimeGeneration);
            assertCapturedRuntime("after archive revalidation");
            const currentDomTask = [...document.querySelectorAll(ROW_SELECTOR)].map(metadataFromRow).find((task) => task.conversationId === archiveThread.id);
            const currentDeleteEligible = eligibleAutoDeleteThreads(currentArchived, currentActive, readRecords(AUTO_ARCHIVED_RECORDS_KEY), AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000, currentPinned);
            const currentArchiveEligible = eligibleAutoArchiveThreads(currentActive, currentPinned, [...currentActive, ...currentArchived]);
            const stillEligible = !currentPinned.has(archiveThread.id)
              && !currentDomTask?.selected
              && currentDomTask?.statusType !== "loading"
              && currentArchiveEligible.some((candidate) => candidate.id === archiveThread.id);
            maintenanceContinuationNeeded ||= currentDeleteEligible.length + currentArchiveEligible.length > (stillEligible ? 1 : 0);
            if (stillEligible) {
              if (!acquireAutoArchiveLease()) {
                leaseLost = true;
              } else if (Date.now() >= runDeadline || generation !== state.autoArchiveGeneration) {
                timeLimitReached = true;
              } else {
                assertCapturedRuntime("before archive");
                await sendRequestWithTimeout(requestClient, "thread/archive", { threadId: archiveThread.id }, remainingRequestTimeout(runDeadline, "maintenance archive"));
                assertCapturedRuntime("after archive");
                archiveRecords[archiveThread.id] = Date.now();
                archived = 1;
              }
            }
          }
        } catch (error) {
          assertCapturedRuntime("during archive cleanup");
          archiveFailures.push({ error: sanitizedMaintenanceFailure("archive", error) });
        }
      }
      if (generation === state.autoArchiveGeneration && readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY) && !state.disposed) {
        writeRecords(AUTO_ARCHIVED_RECORDS_KEY, archiveRecords);
      }
      state.autoArchiveLastRunAt = Date.now();
      state.autoArchiveLastResult = {
        archived,
        archiveEligible: archiveCandidates.length,
        archiveFailed: archiveFailures.length,
        archivedScanned: archivedThreads.length,
        deleted,
        deleteEligible: deleteCandidates.length,
        deleteFailed: deleteFailures.length,
        eligible: archiveCandidates.length,
        failed: archiveFailures.length + deleteFailures.length,
        scanned: activeThreads.length,
        unmanagedActiveSkipped: unmanagedMaintenanceThreadCount(activeThreads, false),
        unmanagedArchivedSkipped: unmanagedMaintenanceThreadCount(archivedThreads, true),
        continuationScheduled: maintenanceContinuationNeeded,
      };
      const failureCount = archiveFailures.length + deleteFailures.length;
      const firstOperationError = deleteFailures[0]?.error ?? archiveFailures[0]?.error ?? null;
      if (firstOperationError) state.autoArchiveLastResult.operationError = firstOperationError;
      state.autoArchiveError = leaseLost
        ? "Automatic cleanup lost its cross-window lease and will retry"
        : timeLimitReached ? "Automatic cleanup reached its bounded run limit and will continue on retry"
        : failureCount ? `${firstOperationError} (${failureCount} failed operation${failureCount === 1 ? "" : "s"})` : null;
      state.lastAction = { commandId: "auto-maintain-old-chats", found: true, invoked: true, ...state.autoArchiveLastResult };
      void state.queryClient?.invalidateQueries?.();
      return state.autoArchiveLastResult;
    } catch (error) {
      state.autoArchiveError = String(error?.message ?? error).slice(0, 240);
      state.autoArchiveLastResult = { archived, deleted, eligible: 0, error: state.autoArchiveError };
      state.lastAction = { commandId: "auto-maintain-old-chats", error: state.autoArchiveError, found: true, invoked: false };
      return state.autoArchiveLastResult;
    } finally {
      if (state.autoArchiveLeaseTimer !== null) clearInterval(state.autoArchiveLeaseTimer);
      state.autoArchiveLeaseTimer = null;
      releaseAutoArchiveLease();
      state.autoArchivePending = false;
      if (!state.disposed) {
        scheduleAutoArchive(state.autoArchiveError || maintenanceContinuationNeeded ? AUTO_ARCHIVE_RETRY_MS : AUTO_ARCHIVE_INTERVAL_MS);
        schedule();
      }
    }
  }

  async function runAutoArchiveNow() {
    if (state.autoArchivePending || state.disposed) return state.autoArchiveLastResult ?? { archived: 0, deleted: 0, eligible: 0 };
    if (!readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) return { archived: 0, deleted: 0, eligible: 0, skipped: "auto-archive-disabled" };
    if (typeof globalThis.navigator?.locks?.request !== "function") {
      const result = { archived: 0, deleted: 0, eligible: 0, error: "Exclusive maintenance lock is unavailable" };
      state.autoArchiveError = result.error;
      state.autoArchiveLastResult = result;
      scheduleAutoArchive(AUTO_ARCHIVE_RETRY_MS);
      return result;
    }
    try {
      return await globalThis.navigator.locks.request("codex-remote-mobile-auto-maintenance-v1", { ifAvailable: true, mode: "exclusive" }, async (lock) => {
        if (!lock) {
          scheduleAutoArchive(AUTO_ARCHIVE_RETRY_MS);
          return { archived: 0, deleted: 0, eligible: 0, skipped: "maintenance-running-in-another-window" };
        }
        return runAutoArchiveWithLease();
      });
    } catch {
      const result = { archived: 0, deleted: 0, eligible: 0, error: "Exclusive maintenance lock request failed" };
      state.autoArchiveError = result.error;
      state.autoArchiveLastResult = result;
      scheduleAutoArchive(AUTO_ARCHIVE_RETRY_MS);
      return result;
    }
  }

  function scheduleAutoArchive(delay = null) {
    if (state.disposed || !readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY) || state.autoArchivePending || state.autoArchiveTimer !== null) return;
    const elapsed = Date.now() - state.autoArchiveLastRunAt;
    const dueIn = delay ?? (state.autoArchiveLastRunAt ? Math.max(1000, AUTO_ARCHIVE_INTERVAL_MS - elapsed) : 10000);
    state.autoArchiveTimer = setTimeout(() => {
      state.autoArchiveTimer = null;
      if (!state.disposed && readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) void runAutoArchiveNow();
    }, dueIn);
  }

  function setAutoArchive(enabled) {
    state.autoArchiveGeneration += 1;
    writeBoolean(AUTO_ARCHIVE_ENABLED_KEY, enabled === true);
    if (enabled !== true && state.autoArchiveTimer !== null) {
      clearTimeout(state.autoArchiveTimer);
      state.autoArchiveTimer = null;
    }
    if (enabled !== true) writeRecords(AUTO_ARCHIVED_RECORDS_KEY, {});
    state.lastAction = { commandId: "set-auto-archive", invoked: true, enabled: enabled === true };
    if (enabled === true) scheduleAutoArchive(1000);
    return render();
  }

  function staleMirroredProjects(model) {
    return model.projects.filter((project) => {
      if (project.hostId === "local" || !project.projectId || !hasRecord(AUTO_MANAGED_KEY, project)) return false;
      const inventory = directCompleteInventory(project.hostId);
      return inventory && !inventoryContainsProject(inventory, project);
    });
  }

  async function reconcileAutoRegisteredProjects() {
    if (state.autoReconciliationPending || state.autoRegistrationPending || typeof state.localFetchFromHost !== "function") return { removed: 0 };
    state.autoReconciliationPending = true;
    try {
      const model = collectModel();
      const staleProjects = staleMirroredProjects(model);
      const staleIds = new Set(staleProjects.map((project) => project.projectId));
      const managedBefore = readRecords(AUTO_MANAGED_KEY);
      for (const project of state.localRegisteredProjects.values()) {
        const inventory = directCompleteInventory(project.hostId);
        if (project.projectId && hasRecord(AUTO_MANAGED_KEY, project) && inventory && !inventoryContainsProject(inventory, project)) {
          staleIds.add(project.projectId);
        }
      }
      if (staleIds.size) {
        const remoteProjectsResult = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "remote-projects" } });
        if (!Array.isArray(remoteProjectsResult?.value)) throw new Error("Remote project state did not contain a valid project list");
        const remoteProjects = remoteProjectsResult.value;
        await setGlobalStateValue("remote-projects", remoteProjects.filter((project) => !staleIds.has(project?.id)));
        for (const key of ["project-order", "pinned-project-ids"]) {
          const result = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key } });
          if (Array.isArray(result?.value)) await setGlobalStateValue(key, result.value.filter((id) => !staleIds.has(id)));
        }
        const selectedResult = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "selected-project" } });
        if (selectedResult?.value?.type === "remote" && staleIds.has(selectedResult.value.projectId)) {
          await setGlobalStateValue("selected-project", null);
        }
        await state.queryClient?.invalidateQueries?.();
      }

      const managed = managedBefore;
      for (const [identity, record] of Object.entries(managed)) {
        const inventory = directCompleteInventory(normalizeHostId(record.hostId));
        if (inventory && !inventoryContainsProject(inventory, record)) delete managed[identity];
      }
      writeRecords(AUTO_MANAGED_KEY, managed);
      state.lastAction = { commandId: "reconcile-auto-projects", found: true, invoked: true, removed: staleIds.size };
      return { removed: staleIds.size };
    } catch (error) {
      state.lastAction = { commandId: "reconcile-auto-projects", error: error?.message || String(error), found: true, invoked: false };
      return { error: error?.message || String(error), removed: 0 };
    } finally {
      state.autoReconciliationPending = false;
      schedule();
    }
  }

  function scheduleAutoReconciliation(model) {
    if (state.disposed || !readBoolean(AUTO_ENABLED_KEY) || state.autoReconciliationTimer !== null || state.autoReconciliationPending) return;
    const managed = Object.values(readRecords(AUTO_MANAGED_KEY));
    const hasStaleManaged = managed.some((record) => {
      const inventory = directCompleteInventory(normalizeHostId(record?.hostId));
      return inventory && !inventoryContainsProject(inventory, record);
    });
    if (!staleMirroredProjects(model).length && !hasStaleManaged) return;
    state.autoReconciliationTimer = setTimeout(() => {
      state.autoReconciliationTimer = null;
      if (!state.disposed) void reconcileAutoRegisteredProjects();
    }, 500);
  }

  async function autoRegisterProject(project) {
    const identity = projectIdentity(project);
    const navigate = nativeNavigationDispatcher();
    if (!identity || !navigate || state.autoRegistrationPending) return;
    state.autoRegistrationPending = identity;
    let ownedDialog = null;
    try {
      await registerRemoteProjectAndOpen(project, navigate, (dialog) => { ownedDialog = dialog; });
      setRecord(AUTO_MANAGED_KEY, project, true);
      setRecord(AUTO_SUPPRESSED_KEY, project, false);
      state.autoRegistrationFailures.delete(identity);
      state.lastAction = { commandId: "auto-register-remote-project", found: true, hostId: project.hostId, invoked: true, project: project.name };
    } catch (error) {
      dismissAutoRegistrationDialog(ownedDialog);
      state.autoRegistrationFailures.set(identity, Date.now() + 120000);
      state.lastAction = { commandId: "auto-register-remote-project", error: error?.message || String(error), found: true, hostId: project.hostId, invoked: false, project: project.name };
    } finally {
      state.autoRegistrationPending = null;
      schedule();
    }
  }

  function scheduleAutoRegistration(model) {
    if (state.disposed || state.autoRegistrationTimer !== null) return;
    const candidate = autoRegistrationCandidate(model);
    if (!candidate || !nativeNavigationDispatcher()) return;
    const identity = projectIdentity(candidate);
    state.autoRegistrationTimer = setTimeout(() => {
      state.autoRegistrationTimer = null;
      if (state.disposed) return;
      const current = autoRegistrationCandidate(collectModel());
      if (current && projectIdentity(current) === identity) void autoRegisterProject(current);
      else schedule();
    }, 1500);
  }

  function allowAutoRegistration(project) {
    setRecord(AUTO_SUPPRESSED_KEY, project, false);
    state.autoRegistrationFailures.delete(projectIdentity(project));
    state.lastAction = { commandId: "allow-auto-registration", found: true, hostId: project.hostId, invoked: true, project: project.name };
    render();
  }

  function invokeNativeProjectCommand(project, commandId) {
    const command = nativeProjectCommands(project).find((item) => item?.id === commandId && typeof item?.onSelect === "function");
    if (!command || command.enabled === false) {
      state.lastAction = { commandId, found: false, hostId: project.hostId, project: project.name };
      return false;
    }
    state.actionCardKey = null;
    state.contextProjectKey = null;
    state.contextPoint = null;
    try {
      command.onSelect();
      if (commandId === "remove-project" && project.hostId !== "local") {
        setRecord(AUTO_MANAGED_KEY, project, false);
        setRecord(AUTO_SUPPRESSED_KEY, project, true);
      }
      state.lastAction = { commandId, found: true, hostId: project.hostId, invoked: true, project: project.name };
    } catch (error) {
      state.lastAction = { commandId, error: error?.message || String(error), found: true, hostId: project.hostId, invoked: false, project: project.name };
    }
    render();
    return state.lastAction?.invoked === true;
  }

  async function removeAllAutoRegistered() {
    const managed = readRecords(AUTO_MANAGED_KEY);
    const removedIdentities = new Set();
    let removed = 0;
    if (typeof state.localFetchFromHost === "function" && Object.keys(managed).length) {
      const result = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "remote-projects" } });
      if (!Array.isArray(result?.value)) throw new Error("Remote project state did not contain a valid project list");
      const remoteProjects = result.value;
      const removedIds = new Set();
      const kept = remoteProjects.filter((project) => {
        const candidate = { cwd: project?.remotePath, hostId: normalizeHostId(project?.hostId), name: project?.label };
        const remove = hasRecord(AUTO_MANAGED_KEY, candidate);
        if (remove && typeof project?.id === "string") {
          removedIds.add(project.id);
          removedIdentities.add(projectIdentity(candidate));
        }
        return !remove;
      });
      if (removedIds.size) {
        await setGlobalStateValue("remote-projects", kept);
        for (const key of ["project-order", "pinned-project-ids"]) {
          const current = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key } });
          if (Array.isArray(current?.value)) await setGlobalStateValue(key, current.value.filter((id) => !removedIds.has(id)));
        }
        const selected = await fetchFromHostWithTimeout(state.localFetchFromHost, "get-global-state", { params: { key: "selected-project" } });
        if (selected?.value?.type === "remote" && removedIds.has(selected.value.projectId)) await setGlobalStateValue("selected-project", null);
        await state.queryClient?.invalidateQueries?.();
        removed = removedIds.size;
      }
    } else {
      const projects = collectModel().projects.filter((project) => {
        return project.hostId !== "local" && project.projectId && hasRecord(AUTO_MANAGED_KEY, project);
      });
      for (const project of projects) {
        if (invokeNativeProjectCommand(project, "remove-project")) {
          removed += 1;
          removedIdentities.add(projectIdentity(project));
        }
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }
    for (const [identity, record] of Object.entries(managed)) {
      if (!removedIdentities.has(identity)) continue;
      const placeholder = { cwd: record.cwd, hostId: record.hostId, name: record.name };
      setRecord(AUTO_SUPPRESSED_KEY, placeholder, true);
      delete managed[identity];
    }
    writeRecords(AUTO_MANAGED_KEY, managed);
    state.lastAction = { commandId: "remove-all-auto-registered", found: true, invoked: true, removed };
    render();
    return { removed };
  }

  async function startNativeProjectThread(project) {
    if (state.pendingNewThreads.has(project.key)) return;
    const nativeAction = nativeProjectNewAction(project);
    if (nativeAction) {
      const invoked = invokeNativeElement(nativeAction);
      state.lastAction = { commandId: "start-new-thread", found: true, hostId: project.hostId, invoked, mode: "native-project-button", project: project.name };
      return;
    }
    const localCallback = project.hostId === "local" ? nativeProjectCallback(project, "onStartNewThread") : null;
    const projectDispatcher = project.projectId ? nativeStartThreadDispatcher() : null;
    const globalNewChat = project.projectId && typeof state.localFetchFromHost === "function" ? nativeGlobalNewChatAction() : null;
    const navigationDispatcher = project.hostId !== "local" && !project.projectId ? nativeNavigationDispatcher() : null;
    if (!localCallback && !projectDispatcher && !globalNewChat && !navigationDispatcher) {
      state.lastAction = { commandId: "start-new-thread", found: false, hostId: project.hostId, project: project.name };
      return;
    }
    state.pendingNewThreads.add(project.key);
    let ownedDialog = null;
    try {
      if (localCallback) localCallback();
      else if (projectDispatcher) projectDispatcher({ projectId: project.projectId, projectKind: project.hostId === "local" ? "local" : "remote" });
      else if (globalNewChat) {
        invokeNativeElement(globalNewChat);
        await new Promise((resolve) => setTimeout(resolve, 0));
        await setGlobalStateValue("selected-project", { projectId: project.projectId, type: project.hostId === "local" ? "local" : "remote" });
        void state.queryClient?.invalidateQueries?.();
      }
      else await registerRemoteProjectAndOpen(project, navigationDispatcher, (dialog) => { ownedDialog = dialog; });
      state.lastAction = { commandId: "start-new-thread", found: true, hostId: project.hostId, invoked: true, mode: globalNewChat && !localCallback && !projectDispatcher ? "global-composer-project-selection" : project.hostId !== "local" && !project.projectId ? "registered-remote-project" : "open-composer", project: project.name };
    } catch (error) {
      dismissAutoRegistrationDialog(ownedDialog);
      state.lastAction = { commandId: "start-new-thread", error: error?.message || String(error), found: true, hostId: project.hostId, invoked: false, project: project.name };
    } finally {
      state.pendingNewThreads.delete(project.key);
      schedule();
    }
  }

  function projectCard(project) {
    const commands = new Map(nativeProjectCommands(project).map((command) => [command.id, command]));
    const enabled = (id) => commands.get(id)?.enabled !== false && typeof commands.get(id)?.onSelect === "function";
    const card = document.createElement("div");
    card.id = CARD_ID;
    card.className = "crmp-project-card";
    card.setAttribute("role", "dialog");
    card.setAttribute("aria-label", `Project details for ${project.name}`);
    card.tabIndex = -1;
    isolateOverlay(card);
    bindOverlayKeyboard(card);
    const head = document.createElement("div");
    head.className = "crmp-project-card-row crmp-project-card-head";
    const icon = document.createElement("span");
    icon.className = "crmp-project-card-icon";
    icon.textContent = "▱";
    const label = document.createElement("span");
    label.textContent = project.name;
    const spacer = document.createElement("span");
    spacer.className = "crmp-project-card-spacer";
    const pin = button("crmp-project-card-row crmp-project-card-pin", "⌖");
    setFocusKey(pin, "card", project.key, "pin-project");
    const pinLabel = typeof commands.get("pin-project")?.label === "string" ? commands.get("pin-project").label : "Pin or unpin project";
    pin.setAttribute("aria-label", pinLabel);
    pin.title = pinLabel;
    pin.disabled = !enabled("pin-project");
    bindActivation(pin, () => invokeNativeProjectCommand(project, "pin-project"));
    head.append(icon, label, spacer, pin);
    card.appendChild(head);

    const count = document.createElement("div");
    count.className = "crmp-project-card-row";
    count.innerHTML = `<span class="crmp-project-card-icon">◯</span><span>${project.tasks.length} ${project.tasks.length === 1 ? "task" : "tasks"}</span>`;
    card.append(count, divider());

    const path = button("crmp-project-card-row crmp-project-card-path", "");
    setFocusKey(path, "card", project.key, "reveal-project-folder");
    path.title = "Open in Explorer";
    path.disabled = !enabled("reveal-project-folder");
    path.innerHTML = '<span class="crmp-project-card-icon">▱</span>';
    const pathText = document.createElement("span");
    pathText.textContent = project.cwd || "Project folder unavailable";
    path.appendChild(pathText);
    bindActivation(path, () => invokeNativeProjectCommand(project, "reveal-project-folder"));
    card.append(path, divider());

    const edit = button("crmp-project-card-row", "");
    setFocusKey(edit, "card", project.key, "edit-project");
    edit.innerHTML = '<span class="crmp-project-card-icon">⚙</span><span>Edit project</span>';
    edit.disabled = !enabled("edit-project");
    if (edit.disabled) edit.title = "Project editing is unavailable in the native sidebar";
    bindActivation(edit, () => invokeNativeProjectCommand(project, "edit-project"));
    card.appendChild(edit);
    return card;
  }

  function divider() {
    const element = document.createElement("div");
    element.className = "crmp-project-card-divider";
    return element;
  }

  function projectContextMenu(project) {
    const commands = new Map(nativeProjectCommands(project).map((command) => [command.id, command]));
    const suppressed = hasRecord(AUTO_SUPPRESSED_KEY, project);
    const menu = document.createElement("div");
    menu.id = CONTEXT_ID;
    menu.setAttribute("role", "menu");
    menu.setAttribute("aria-label", `Project actions for ${project.name}`);
    menu.tabIndex = -1;
    isolateOverlay(menu);
    bindOverlayKeyboard(menu, true);
    if (!commands.size && !suppressed) {
      const note = document.createElement("div");
      note.className = "crmp-context-note";
      note.textContent = `${project.hostName} project actions are not exposed by the native sidebar.`;
      menu.appendChild(note);
    }
    const definitions = [
      ...(suppressed ? [["allow-auto-registration", "↻", "Allow auto-registration"], null] : []),
      ["pin-project", "⌖", "Pin"],
      ["edit-project", "⌕", "Edit"],
      null,
      ["reveal-project-folder", "▱", "Open in Explorer"],
      null,
      ["archive-project-threads", "▣", "Archive chats"],
      null,
      ["remove-project", "×", "Remove project"],
    ];
    for (const definition of definitions) {
      if (!definition) {
        const separator = document.createElement("div");
        separator.className = "crmp-context-separator";
        separator.setAttribute("role", "separator");
        menu.appendChild(separator);
        continue;
      }
      const [id, icon, label] = definition;
      const item = button("crmp-context-item", "");
      setFocusKey(item, "context", project.key, id);
      item.setAttribute("role", "menuitem");
      item.innerHTML = `<span aria-hidden="true">${icon}</span><span>${label}</span>`;
      const custom = id === "allow-auto-registration";
      const command = commands.get(id);
      const commandLabel = typeof command?.label === "string" && command.label.trim() ? command.label : label;
      item.lastElementChild.textContent = commandLabel;
      item.setAttribute("aria-label", commandLabel);
      item.tabIndex = -1;
      item.disabled = !custom && (!command || command.enabled === false || typeof command.onSelect !== "function");
      if (item.disabled) item.title = "This command is unavailable in the native sidebar";
      bindActivation(item, () => custom ? allowAutoRegistration(project) : invokeNativeProjectCommand(project, id));
      menu.appendChild(item);
    }
    return menu;
  }

  function positionProjectCard() {
    const card = document.getElementById(CARD_ID);
    const action = state.panel?.querySelector(`.crmp-project[data-project-key="${CSS.escape(state.actionCardKey || "")}"] .crmp-project-action`);
    if (!card || !action) return;
    const sidebar = state.panel.closest("nav") || state.panel.parentElement || state.panel;
    const sidebarRect = sidebar.getBoundingClientRect();
    const actionRect = action.getBoundingClientRect();
    const gap = 7;
    const preferredLeft = sidebarRect.right + gap;
    const availableRight = globalThis.innerWidth - preferredLeft - 8;
    const width = Math.max(240, Math.min(320, availableRight));
    const left = availableRight >= 240 ? preferredLeft : Math.max(8, sidebarRect.left - width - gap);
    card.style.width = `${width}px`;
    card.style.left = `${left}px`;
    card.style.top = `${Math.max(8, Math.min(actionRect.top, globalThis.innerHeight - card.offsetHeight - 8))}px`;
  }

  function positionProjectContextMenu() {
    const menu = document.getElementById(CONTEXT_ID);
    if (!menu || !state.contextPoint) return;
    const left = Math.max(8, Math.min(state.contextPoint.x, globalThis.innerWidth - menu.offsetWidth - 8));
    const top = Math.max(8, Math.min(state.contextPoint.y, globalThis.innerHeight - menu.offsetHeight - 8));
    menu.style.left = `${left}px`;
    menu.style.top = `${top}px`;
  }

  function appendEmptyProjectState(tasks, project) {
    if (project.kind !== "project" || project.tasks.length || state.collapsed.has(project.key)) return;
    const nativeItem = nativeProjectItem(project);
    const nativeEmpty = [...(nativeItem?.querySelectorAll("div.text-codex-description.opacity-50") ?? [])]
      .find((element) => element.children.length === 0);
    const wrapper = document.createElement("div");
    wrapper.className = "pt-0.5 pb-2 crmp-empty-project";
    const content = document.createElement("div");
    const empty = nativeEmpty?.cloneNode(true) ?? document.createElement("div");
    empty.className = "crmp-help";
    empty.textContent = emptyInventoryMessage(project.hostId);
    content.appendChild(empty);
    wrapper.appendChild(content);
    tasks.appendChild(wrapper);
  }

  function appendGroup(fragment, project) {
    const nativeToggle = nativeProjectItem(project)?.querySelector('[data-app-action-sidebar-project-collapsed]');
    if (nativeToggle) {
      if (nativeToggle.getAttribute("data-app-action-sidebar-project-collapsed") === "true") state.collapsed.add(project.key);
      else state.collapsed.delete(project.key);
    }
    const section = document.createElement("section");
    section.className = "crmp-project";
    section.dataset.hostId = project.hostId;
    section.dataset.projectKey = project.key;
    const head = document.createElement("div");
    const nativeHeadClass = nativeProjectRowTemplate(project)?.className;
    head.className = `${nativeHeadClass || "sidebar-item group relative"} crmp-project-head`;
    head.dataset.actionsOpen = String(state.actionCardKey === project.key || state.contextProjectKey === project.key);
    const toggle = button("crmp-project-toggle", "");
    setFocusKey(toggle, "project", project.key, "toggle");
    toggle.title = project.cwd || project.name;
    toggle.setAttribute("aria-expanded", String(!state.collapsed.has(project.key)));
    const folder = document.createElement("span");
    folder.className = "crmp-folder";
    folder.dataset.remoteInventory = String(project.hostId !== "local" && !nativeProjectItem(project));
    const expanded = !state.collapsed.has(project.key);
    const folderIcon = project.kind === "recent" ? null : nativeFolderIcon(project, expanded);
    if (folderIcon) folder.appendChild(folderIcon);
    else folder.textContent = project.kind === "recent" ? "◷" : "▱";
    const name = document.createElement("span");
    name.className = "crmp-project-name";
    name.textContent = project.name;
    const suffix = document.createElement("span");
    suffix.className = "crmp-project-host";
    suffix.textContent = state.filter === "all" ? project.hostName : (state.collapsed.has(project.key) ? "›" : "⌄");
    toggle.append(folder, name, suffix);
    toggle.addEventListener("click", () => {
      if (performance.now() - state.dragJustEndedAt < 250) return;
      if (nativeToggle) {
        nativeToggle.click();
        schedule();
        return;
      }
      if (state.collapsed.has(project.key)) state.collapsed.delete(project.key); else state.collapsed.add(project.key);
      render();
    });
    bindReorder(toggle, head, reorderReference("project", project));
    toggle.addEventListener("keydown", (event) => {
      if (project.kind !== "project" || (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10"))) return;
      event.preventDefault();
      event.stopPropagation();
      openProjectContextMenu(project, toggle);
    });
    head.addEventListener("contextmenu", (event) => {
      if (project.kind !== "project") return;
      if (event.target.closest(".crmp-project-action,.crmp-project-new")) return;
      event.preventDefault();
      event.stopPropagation();
      openProjectContextMenu(project, toggle, { x: event.clientX, y: event.clientY });
    });
    head.appendChild(toggle);
    const groupStatus = projectStatusIndicator(project, expanded);
    if (groupStatus) head.appendChild(groupStatus);
    if (project.kind === "project") {
      const create = cloneNativeButton(nativeProjectButtonTemplate(project, "new"), "crmp-project-new", "✎");
      setFocusKey(create, "project", project.key, "new");
      create.setAttribute("aria-label", `Start new chat in ${project.name}`);
      create.title = `Start new chat in ${project.name}`;
      const exactNativeNewAction = nativeProjectNewAction(project);
      create.disabled = state.pendingNewThreads.has(project.key) || nativeElementDisabled(exactNativeNewAction) || (!exactNativeNewAction && (project.hostId === "local"
        ? !nativeProjectCallback(project, "onStartNewThread") && !(project.projectId && (nativeStartThreadDispatcher() || (typeof state.localFetchFromHost === "function" && nativeGlobalNewChatAction())))
        : !project.cwd || !(project.projectId ? nativeStartThreadDispatcher() || (typeof state.localFetchFromHost === "function" && nativeGlobalNewChatAction()) : nativeNavigationDispatcher())));
      bindActivation(create, () => startNativeProjectThread(project));
      head.appendChild(create);
      const actions = cloneNativeButton(nativeProjectButtonTemplate(project, "actions"), "crmp-project-action", "⋯");
      setFocusKey(actions, "project", project.key, "details");
      actions.setAttribute("aria-label", `Open project details for ${project.name}`);
      actions.setAttribute("aria-haspopup", "dialog");
      actions.setAttribute("aria-expanded", String(state.actionCardKey === project.key));
      if (state.actionCardKey === project.key) actions.setAttribute("aria-controls", CARD_ID);
      actions.title = "Project details and settings";
      bindActivation(actions, () => {
        if (state.actionCardKey === project.key) {
          closeProjectOverlays();
          return;
        }
        state.contextProjectKey = null;
        state.contextPoint = null;
        state.actionCardKey = project.key;
        state.overlayFocusReturnKey = actions.dataset.crmpFocusKey;
        state.pendingOverlayFocus = { id: CARD_ID };
        render();
      });
      head.appendChild(actions);
    }
    if (!project.flatRecent) section.appendChild(head);
    if (project.flatRecent || !state.collapsed.has(project.key)) {
      const tasks = document.createElement("div");
      tasks.className = "crmp-tasks";
      if (project.tasks.length && !project.flatRecent) tasks.style.padding = "2px 0 8px";
      appendEmptyProjectState(tasks, project);
      for (const task of project.tasks) {
        const taskRow = document.createElement("div");
        taskRow.className = "crmp-task-row group";
        const taskButton = button(`${task.originalRow?.className || ""} crmp-task`, task.title);
        setFocusKey(taskButton, "task", task.hostId, task.conversationKey);
        taskButton.disabled = nativeElementDisabled(task.originalRow);
        if (project.flatRecent) taskButton.style.paddingInlineStart = "8px";
        if (task.originalRow) {
          const nativeStyle = getComputedStyle(task.originalRow);
          for (const property of ["fontSize", "fontWeight", "lineHeight", "color"]) taskButton.style[property] = nativeStyle[property];
          if (task.selected) taskButton.style.backgroundColor = nativeStyle.backgroundColor;
        }
        const working = task.statusType === "loading";
        const stateLabel = taskStatusLabel(task);
        if (stateLabel) taskButton.setAttribute("aria-label", `${task.title}, ${stateLabel}`);
        taskButton.title = `${task.title}\n${task.cwd || project.cwd || "No project folder"}\n${project.hostName}`;
        taskButton.dataset.appActionSidebarThreadSelected = String(task.selected);
        if (task.selected) taskButton.setAttribute("aria-current", "page");
        taskButton.addEventListener("click", async () => {
          if (performance.now() - state.dragJustEndedAt >= 250) {
            const acknowledge = task.unread && task.hostId !== "local";
            const opened = await openNativeTask(task);
            if (opened && acknowledge) acknowledgeRemoteUnread(task);
            render();
          }
        });
        taskButton.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          if (!task.originalRow) return;
          task.originalRow.dispatchEvent(new MouseEvent("contextmenu", {
            bubbles: true,
            button: 2,
            clientX: event.clientX,
            clientY: event.clientY,
            view: globalThis,
          }));
        });
        bindReorder(taskButton, taskRow, reorderReference("task", task, project.key));
        taskRow.appendChild(taskButton);
        const statusIndicator = taskStatusIndicator(task);
        if (statusIndicator) {
          taskRow.appendChild(statusIndicator);
          queueMicrotask(() => reserveTaskStatusSpace(taskButton, statusIndicator));
        }
        const taskActions = document.createElement("div");
        const railTemplate = nativeThreadAction(task, "pin")?.closest('div[class*="absolute"][class*="end-0"]')
          ?? nativeThreadAction(task, "archive")?.closest('div[class*="absolute"][class*="end-0"]');
        taskActions.className = `${railTemplate?.className || ""} crmp-task-actions`;
        for (const actionName of ["pin", "archive"]) {
          const nativeAction = nativeThreadAction(task, actionName);
          if (!nativeAction) continue;
          const actionLabel = nativeAction.getAttribute("aria-label") || (actionName === "pin" ? "Pin chat" : "Archive chat");
          const actionButton = cloneNativeButton(nativeAction, "crmp-task-action", actionName === "pin" ? "⌖" : "▣");
          setFocusKey(actionButton, "task", task.hostId, task.conversationKey, actionName);
          actionButton.setAttribute("aria-label", actionLabel);
          actionButton.title = actionLabel;
          bindActivation(actionButton, () => invokeNativeThreadAction(task, actionName));
          taskActions.appendChild(actionButton);
        }
        taskRow.appendChild(taskActions);
        tasks.appendChild(taskRow);
      }
      section.appendChild(tasks);
    }
    fragment.appendChild(section);
  }

  function readiness() {
    const localInventory = state.threadInventories.get("local");
    const mounted = Boolean(state.panel?.isConnected && state.nativeContainer?.isConnected);
    const localRuntimeReady = typeof state.localRuntime?.requestClient?.sendRequest === "function";
    const authoritativeInventoryReady = Boolean(localInventory
      && !localInventory.error
      && localInventory.truncated !== true
      && Number.isFinite(localInventory.fetchedAt)
      && Array.isArray(localInventory.threads));
    const publisherReady = state.localInventoryPublishedAt > 0 && !state.localInventoryPublisherError;
    const ready = mounted && localRuntimeReady && authoritativeInventoryReady && publisherReady;
    const error = ready ? null
      : !mounted ? "Mobile project view is not mounted"
      : !localRuntimeReady ? "Local app-server runtime is unavailable"
      : !authoritativeInventoryReady ? (localInventory?.error || "Authoritative local inventory is not ready")
      : (state.localInventoryPublisherError || "Local inventory publisher is not ready");
    return { authoritativeInventoryReady, error, localRuntimeReady, mounted, publisherReady, ready };
  }

  function renderReport(model = null) {
    return {
      active: state.active,
      hosts: model?.hosts?.length ?? 0,
      projects: model?.projects?.length ?? 0,
      readiness: readiness(),
      tasks: model?.tasks?.length ?? 0,
      updateStatus: readUpdateStatus(),
      version: VERSION,
      view: state.view,
    };
  }

  function render() {
    state.counters.renders += 1;
    const focus = captureSidebarFocus();
    state.scrollSnapshot = [];
    for (let parent = state.panel?.parentElement; parent; parent = parent.parentElement) {
      if (parent.scrollHeight > parent.clientHeight) state.scrollSnapshot.push([parent, parent.scrollTop]);
    }
    state.scheduledFrame = null;
    document.getElementById(CARD_ID)?.remove();
    document.getElementById(CONTEXT_ID)?.remove();
    if (!state.active) return renderReport();
    const model = collectModel();
    state.displayedHosts = model.hosts;
    // Current Codex separates Projects and Recents into sibling sections.
    // Include both sets so the replacement covers the complete native list.
    const nextNative = nativeListContainer(model.rows, model.nativeProjectItems);
    if (!nextNative) {
      if (state.mountRetryTimer === null) {
        state.mountRetryTimer = setTimeout(() => {
          state.mountRetryTimer = null;
          schedule();
        }, state.mountRetryDelay);
        state.mountRetryDelay = Math.min(30000, state.mountRetryDelay * 2);
      }
      return renderReport(model);
    }
    state.mountRetryDelay = 500;

    if (state.nativeContainer !== nextNative) {
      if (state.nativeContainer?.isConnected) state.nativeContainer.style.display = state.originalDisplay;
      state.nativeContainer = nextNative;
      state.originalDisplay = nextNative.style.display;
      nextNative.parentElement?.insertBefore(state.panel, nextNative);
    }
    observeSidebarMutations(nextNative.closest?.("nav,aside") ?? nextNative.parentElement ?? document.body);

    const fragment = document.createDocumentFragment();
    const modes = document.createElement("div");
    modes.className = "crmp-modes";
    for (const [id, label] of [["mobile", "Device projects"], ["native", "Native sidebar"]]) {
      const mode = button("crmp-mode", label);
      setFocusKey(mode, "mode", id);
      mode.setAttribute("aria-pressed", String(state.view === id));
      mode.addEventListener("click", () => setView(id));
      modes.appendChild(mode);
    }
    const settingsToggle = button("crmp-mode", "Settings");
    settingsToggle.setAttribute("aria-expanded", String(state.settingsOpen));
    settingsToggle.setAttribute("aria-controls", `${PANEL_ID}-settings`);
    setFocusKey(settingsToggle, "settings");
    settingsToggle.addEventListener("click", () => { state.settingsOpen = !state.settingsOpen; render(); });
    modes.appendChild(settingsToggle);
    fragment.appendChild(modes);
    const update = readUpdateStatus();
    announceUpdate(update);
    if (update.state !== "current") fragment.appendChild(updateStatusPanel(update));
    const settings = document.createElement("section");
    settings.id = `${PANEL_ID}-settings`;
    settings.className = "crmp-settings";
    settings.setAttribute("aria-label", "Remote Enabler settings");
    settings.hidden = !state.settingsOpen;
    const autoControls = document.createElement("div");
    autoControls.className = "crmp-auto-controls";
    const autoEnabled = readBoolean(AUTO_ENABLED_KEY);
    const autoToggle = button("crmp-auto-control", autoEnabled ? "Auto-register: on" : "Auto-register: off");
    setFocusKey(autoToggle, "auto", "register");
    autoToggle.setAttribute("aria-pressed", String(autoEnabled));
    autoToggle.title = "Mirror active projects published by connected injected devices";
    autoToggle.addEventListener("click", () => setAutoRegistration(!autoEnabled));
    autoControls.appendChild(autoToggle);
    const managedCount = Object.keys(readRecords(AUTO_MANAGED_KEY)).length;
    const removeManaged = button("crmp-auto-control", `Remove auto projects (${managedCount})`);
    setFocusKey(removeManaged, "auto", "remove-projects");
    removeManaged.disabled = managedCount === 0;
    removeManaged.title = managedCount
      ? "Remove only projects created by this client's automatic registration"
      : "This client has no automation-created project registrations to remove";
    removeManaged.addEventListener("click", () => {
      if (globalThis.confirm(`Remove ${managedCount} auto-registered remote ${managedCount === 1 ? "project" : "projects"} from this client? Chats and folders are not deleted.`)) {
        void removeAllAutoRegistered();
      }
    });
    autoControls.appendChild(removeManaged);
    const autoArchiveEnabled = readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY);
    const autoArchive = button("crmp-auto-control", autoArchiveEnabled ? "Auto-cleanup: on" : "Auto-cleanup: off");
    setFocusKey(autoArchive, "auto", "cleanup");
    autoArchive.setAttribute("aria-pressed", String(autoArchiveEnabled));
    autoArchive.title = autoArchiveEnabled
      ? "Archive inactive local chats after 7 days and permanently delete them after 7 more archived days; click to disable"
      : "Optionally archive inactive local chats after 7 days and permanently delete them after 7 more archived days";
    autoArchive.addEventListener("click", () => {
      if (autoArchiveEnabled) {
        setAutoArchive(false);
        return;
      }
      if (globalThis.confirm("Enable automatic chat cleanup on this device? Inactive, unpinned local chats move to Archived chats after seven days. After seven more days in Archived chats they are permanently deleted. Working, selected, pinned, remote, and insufficiently dated chats are skipped.")) {
        setAutoArchive(true);
      }
    });
    autoControls.appendChild(autoArchive);
    settings.appendChild(autoControls);

    const cleanupSummary = document.createElement("p");
    cleanupSummary.className = "crmp-help";
    cleanupSummary.textContent = autoArchiveEnabled
      ? "Cleanup is enabled on this device: inactive local chats are archived after 7 days, then permanently deleted after 7 more archived days."
      : "Cleanup is off. Enabling it archives inactive local chats after 7 days, then permanently deletes them after 7 more archived days.";
    settings.appendChild(cleanupSummary);
    const maintenanceSummary = document.createElement("p");
    maintenanceSummary.className = "crmp-help";
    maintenanceSummary.textContent = "Startup maintenance runs only while the app is closed. It maintains local databases and diagnostic logs.";
    settings.appendChild(maintenanceSummary);
    if (update.state === "current") settings.appendChild(updateStatusControl());
    const check = button("crmp-auto-control", "Check for updates");
    check.disabled = !["current", "error", "unavailable"].includes(update.state) || typeof globalThis[UPDATE_SLOT]?.request !== "function";
    setFocusKey(check, "settings", "check");
    check.addEventListener("click", () => { void requestUpdateAction("check"); });
    settings.appendChild(check);
    fragment.appendChild(settings);

    scheduleLocalProjectInventoryPublication();
    scheduleLocalPeerCacheInventory(model.hosts);
    scheduleLocalRegisteredProjectsRefresh();
    scheduleRemoteProjectInventory(model.remoteRuntimes);
    scheduleAutoRegistration(model);
    scheduleAutoReconciliation(model);
    scheduleAutoArchive();
    scheduleNativeInventoryHydration();

    if (state.view === "native") {
      state.nativeContainer.style.display = state.originalDisplay;
      state.panel.replaceChildren(fragment);
      restoreRenderedFocus(focus);
      return renderReport(model);
    }
    state.nativeContainer.style.setProperty("display", "none", "important");

    if (state.filter !== "all" && !model.hosts.some((host) => host.id === state.filter)) state.filter = "all";
    const filters = document.createElement("div");
    filters.className = "crmp-filters";
    filters.setAttribute("role", "group");
    filters.setAttribute("aria-label", "Filter tasks by device");
    const filterItems = [{ id: "all", name: "All" }, ...model.hosts];
    for (const host of filterItems) {
      const chip = button("crmp-chip", host.name);
      setFocusKey(chip, "filter", host.id);
      chip.style.maxWidth = "100%";
      chip.style.overflow = "hidden";
      chip.style.textOverflow = "ellipsis";
      chip.title = host.name;
      chip.setAttribute("aria-label", host.id === "all" ? "All devices" : `${host.name}, ${connectionLabel(host)}`);
      chip.setAttribute("aria-pressed", String(state.filter === host.id));
      if (host.id !== "all") {
        const dot = document.createElement("span");
        dot.className = `crmp-dot${host.availabilityKnown && host.available === false ? " crmp-dot-unavailable" : ""}`;
        if (!host.availabilityKnown) {
          dot.style.background = "#888";
          chip.title = `${host.name} — connection status unknown`;
        }
        chip.prepend(dot);
      }
      chip.addEventListener("click", () => { state.filter = host.id; render(); });
      filters.appendChild(chip);
    }

    fragment.appendChild(filters);
    const devices = document.createElement("details");
    devices.className = "crmp-devices";
    devices.open = state.deviceDetailsOpen;
    devices.addEventListener("toggle", () => { state.deviceDetailsOpen = devices.open; });
    const deviceSummary = document.createElement("summary");
    deviceSummary.textContent = "Device details";
    setFocusKey(deviceSummary, "devices");
    devices.appendChild(deviceSummary);
    for (const host of model.hosts) {
      const entry = document.createElement("p");
      entry.className = "crmp-help";
      entry.textContent = `${host.name} — ${connectionLabel(host)}. ${inventoryLabel(host.id)}`;
      devices.appendChild(entry);
    }
    fragment.appendChild(devices);
    const unavailableInventoryHosts = model.hosts.filter((host) => host.id !== "local" && state.remoteProjectInventories.get(host.id)?.error);
    if (unavailableInventoryHosts.length) {
      const status = document.createElement("div");
      status.className = "crmp-inventory-status";
      status.textContent = `Project sync paused: waiting for a current inventory from ${unavailableInventoryHosts.map((host) => host.name).join(", ")}.`;
      fragment.appendChild(status);
    }
    const panelTitle = document.createElement("div");
    panelTitle.className = "crmp-title text-base font-medium text-tertiary opacity-75";
    panelTitle.textContent = "Projects";
    fragment.appendChild(panelTitle);
    const visibleProjects = model.projects.filter((project) => state.filter === "all" || project.hostId === state.filter);
    const visibleRecents = model.recents.filter((project) => state.filter === "all" || project.hostId === state.filter);
    const projectList = document.createElement("div");
    projectList.className = "crmp-project-list";
    for (const project of visibleProjects) appendGroup(projectList, project);
    fragment.appendChild(projectList);
    if (visibleRecents.length) {
      const recentsTitle = document.createElement("div");
      recentsTitle.className = "crmp-title text-base font-medium text-tertiary opacity-75";
      recentsTitle.textContent = "Recents";
      fragment.appendChild(recentsTitle);
      const recentList = document.createElement("div");
      recentList.className = "crmp-project-list";
      for (const recent of visibleRecents) appendGroup(recentList, { ...recent, flatRecent: visibleRecents.length === 1 });
      fragment.appendChild(recentList);
    }
    if (!visibleProjects.length && !visibleRecents.length) {
      const empty = document.createElement("div");
      empty.className = "crmp-empty";
      empty.textContent = state.filter === "all"
        ? "No projects or tasks to show yet. Connect a device using Remote to load its projects."
        : emptyInventoryMessage(state.filter, true);
      fragment.appendChild(empty);
    }
    state.panel.replaceChildren(fragment);
    const cardProject = [...visibleProjects, ...visibleRecents].find((project) => project.key === state.actionCardKey);
    if (cardProject?.kind === "project") document.body.appendChild(projectCard(cardProject));
    const contextProject = visibleProjects.find((project) => project.key === state.contextProjectKey);
    if (contextProject) document.body.appendChild(projectContextMenu(contextProject));
    positionProjectCard();
    positionProjectContextMenu();
    restoreRenderedFocus(focus);
    return renderReport(model);
  }

  function mutationNodeContainsThreadRow(node) {
    return node instanceof Element && (node.matches?.(ROW_SELECTOR) || Boolean(node.querySelector?.(ROW_SELECTOR)));
  }

  function mutationsChangeThreadMembership(mutations) {
    return Boolean(mutations?.some((mutation) => mutation.type === "childList"
      && !state.panel?.contains(mutation.target)
      && [...mutation.addedNodes, ...mutation.removedNodes].some(mutationNodeContainsThreadRow)));
  }

  function observeSidebarMutations(target) {
    if (!target || typeof MutationObserver !== "function" || state.observerTarget === target) return;
    state.observer?.disconnect();
    state.observer ??= new MutationObserver(schedule);
    state.observer.observe(target, {
      attributeFilter: ["data-app-action-sidebar-thread-selected", "data-app-action-sidebar-thread-title", "data-app-action-sidebar-project-collapsed", "aria-expanded", "disabled"],
      attributes: true,
      childList: true,
      subtree: true,
    });
    state.observerTarget = target;
  }

  function schedule(mutations) {
    if (state.disposed) return;
    if (mutations?.length && mutations.every((mutation) => {
      if (state.panel?.contains(mutation.target)) return true;
      const changed = [...mutation.addedNodes, ...mutation.removedNodes].filter((node) => node instanceof Element);
      return changed.length > 0 && changed.every((node) => [CARD_ID, CONTEXT_ID].includes(node.id));
    })) return;
    if (mutations?.length) {
      state.hostDiscoveryDirty = true;
      if (mutationsChangeThreadMembership(mutations)) {
        state.counters.inventoryDirtyRequests += 1;
        state.inventoryHydrationDirty = true;
        scheduleNativeInventoryHydration();
      }
    }
    if (state.scheduledFrame !== null) return;
    state.scheduledFrame = requestAnimationFrame(render);
  }

  function dismissOverlays(event) {
    if (event.button !== 0 || (!state.actionCardKey && !state.contextProjectKey)) return;
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest(`#${CARD_ID},#${CONTEXT_ID},.crmp-project-action`)) return;
    state.actionCardKey = null;
    state.contextProjectKey = null;
    state.contextPoint = null;
    render();
  }

  function dismissOnEscape(event) {
    if (event.key !== "Escape" || (!state.actionCardKey && !state.contextProjectKey)) return;
    event.preventDefault();
    event.stopPropagation();
    closeProjectOverlays();
  }

  function probe(model = null) {
    state.counters.fullProbeRuns += 1;
    model ??= collectModel();
    const expansionControls = nativeThreadListExpansionControls();
    const tasksByHost = Object.fromEntries(model.hosts.map((host) => [host.name, model.tasks.filter((task) => task.hostId === host.id).length]));
    const authoritativeThreadsByHost = Object.fromEntries([...state.threadInventories].map(([hostId, inventory]) => [hostId, inventory.threads?.length ?? 0]));
    const remoteThreadInventories = Object.fromEntries([...state.remoteProjectInventories].map(([hostId, inventory]) => [hostId, {
      error: inventory.error ?? null,
      pending: inventory.pending === true,
      sourcePeerHostId: inventory.sourcePeerHostId ?? null,
      sourcePeerCache: inventory.sourcePeerCache === true,
      threadsTruncated: inventory.threadsTruncated === true,
      threads: inventory.threads?.length ?? 0,
      threadsAuthoritative: inventory.threadsAuthoritative === true,
      threadScope: inventory.threadScope ?? null,
    }]));
    const visibleGroups = model.groups.filter((project) => state.filter === "all" || project.hostId === state.filter);
    const visibleProjects = visibleGroups.filter((project) => project.kind === "project");
    const visibleRecents = visibleGroups.filter((project) => project.kind === "recent");
    return {
      active: state.active,
      autoArchiveEnabled: readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY),
      autoArchiveError: state.autoArchiveError,
      autoArchiveLastResult: state.autoArchiveLastResult,
      autoArchivePending: state.autoArchivePending,
      autoManagedProjects: Object.keys(readRecords(AUTO_MANAGED_KEY)).length,
      autoRegistrationFailures: state.autoRegistrationFailures.size,
      autoRegistrationEnabled: readBoolean(AUTO_ENABLED_KEY),
      autoRegistrationPending: state.autoRegistrationPending,
      autoReconciliationPending: state.autoReconciliationPending,
      autoSuppressedProjects: Object.keys(readRecords(AUTO_SUPPRESSED_KEY)).length,
      counters: { ...state.counters },
      filter: state.filter,
      hosts: model.hosts.length,
      hostNames: model.hosts.map((host) => host.name),
      hostAvailability: Object.fromEntries(model.hosts.map((host) => [host.name, { available: host.available, known: host.availabilityKnown }])),
      inventoryHydrationPending: state.inventoryHydrationPending,
      inventoryHydrationError: state.inventoryHydrationError,
      inventoryHydrationPhase: state.inventoryHydrationPhase,
      inventoryHydrationRounds: state.inventoryHydrationRounds,
      inventoryHydrationExpansionControls: expansionControls.length,
      inventoryHydrationExpansionControlsCollapsed: expansionControls.filter((control) => !control.expanded).length,
      inventoryHydrationExpansionControlsExpanded: expansionControls.filter((control) => control.expanded).length,
      inventoryHydrationExpansionSnapshot: 0,
      inventoryHydrationTruncated: state.inventoryHydrationTruncated,
      authoritativeThreadHosts: state.threadInventories.size,
      authoritativeThreads: [...state.threadInventories.values()].reduce((total, inventory) => total + (inventory.threads?.length ?? 0), 0),
      authoritativeThreadErrors: [...state.threadInventories.values()].filter((inventory) => inventory.error).length,
      authoritativeThreadsByHost,
      remoteThreadInventories,
      hostInventoryErrors: [...state.remoteProjectInventories.values()].filter((inventory) => inventory.error).length,
      hostInventoryPending: [...state.remoteProjectInventories.values()].filter((inventory) => inventory.pending).length,
      hostInventoryProjects: [...state.remoteProjectInventories.keys()].reduce((count, hostId) => count + (freshInventory(hostId)?.projects?.length ?? 0), 0),
      hostInventoryTaskStates: [...state.remoteProjectInventories.keys()].reduce((count, hostId) => count + (freshInventory(hostId)?.tasks?.size ?? 0), 0),
      projects: model.projects.length,
      readiness: readiness(),
      localInventoryPublished: state.localInventoryPublishedAt > 0,
      localInventoryProjects: state.localInventoryProjects.length,
      localInventoryPublisherError: state.localInventoryPublisherError,
      localInventoryPublisherPending: state.localInventoryPublisherPending,
      localThreadListQuarantineActive: sharedThreadListRegistry.activeQuarantineCount > 0,
      localThreadListRecoveryPending: sharedThreadListRegistry.recoveryPending === true,
      localThreadListRecoveryReason: sharedThreadListRegistry.recoveryReason,
      localRegisteredProjects: state.localRegisteredProjects.size,
      localRegisteredProjectsError: state.localRegisteredProjectsError,
      localRegisteredProjectsPending: state.localRegisteredProjectsPending,
      localStateBridgeAvailable: typeof state.localFetchFromHost === "function",
      projectServiceAvailable: typeof state.projectService?.removeRemote === "function",
      queryClientAvailable: typeof state.queryClient?.invalidateQueries === "function",
      staleMirroredProjects: staleMirroredProjects(model).length,
      emptyProjects: model.projects.filter((project) => project.tasks.length === 0).length,
      recentGroups: model.recents.length,
      lastAction: state.lastAction,
      nativeArchiveActions: model.tasks.filter((task) => Boolean(nativeThreadAction(task, "archive"))).length,
      nativeConnectionGroupingActive: nativeConnectionGroupingActive(),
      nativeGlobalNewChatAvailable: Boolean(nativeGlobalNewChatAction()),
      nativeLoadMoreActions: nativeLoadMoreButtons().length,
      nativePinActions: model.tasks.filter((task) => Boolean(nativeThreadAction(task, "pin"))).length,
      nativeProjectNewActions: model.projects.filter((project) => Boolean(nativeProjectNewAction(project))).length,
      nativeProjectReorderItems: model.projects.filter((project) => Boolean(nativeKeyboardReorder(nativeProjectItem(project)) && sortableSnapshot(nativeProjectItem(project)))).length,
      nativeTaskReorderItems: model.tasks.filter((task) => Boolean(nativeKeyboardReorder(task.originalRow) && sortableSnapshot(task.originalRow))).length,
      mobileProjectNewActions: state.panel?.querySelectorAll(".crmp-project-new").length ?? 0,
      mobileProjectNewActionsEnabled: state.panel ? [...state.panel.querySelectorAll(".crmp-project-new")].filter((item) => !item.disabled).length : 0,
      remoteProjectComposerAvailable: Boolean(nativeStartThreadDispatcher()),
      remoteProjectRegistrationAvailable: Boolean(nativeNavigationDispatcher()),
      remoteProjectRemoveActions: model.projects.filter((project) => project.hostId !== "local" && project.projectId && nativeProjectCommands(project).some((command) => command?.id === "remove-project" && command.enabled !== false)).length,
      remoteProjectsWithId: model.projects.filter((project) => project.hostId !== "local" && project.projectId).length,
      unregisteredRemoteProjects: model.projects.filter((project) => project.hostId !== "local" && !project.projectId && Boolean(project.cwd)).length,
      tasks: model.tasks.length,
      tasksByHost,
      syntheticTasks: model.tasks.filter((task) => !task.originalRow).length,
      syntheticNavigableTasks: model.tasks.filter((task) => !task.originalRow && (state.threadManagers.has(task.hostId) || typeof state.navigationBridge?.navigateToLocalConversation === "function")).length,
      unreadTasks: model.tasks.filter((task) => task.unread).length,
      updateStatus: readUpdateStatus(),
      verifiedThreadHosts: state.verifiedThreadIds.size,
      verifiedThreads: [...state.verifiedThreadIds.values()].reduce((total, record) => total + record.ids.size, 0),
      version: VERSION,
      view: state.view,
      visibleProjects: visibleProjects.length,
      visibleRecentGroups: visibleRecents.length,
      visibleTasks: visibleGroups.reduce((count, project) => count + project.tasks.length, 0),
      workingTasks: model.tasks.filter((task) => task.statusType === "loading").length,
    };
  }

  function install() {
    ensureStyle();
    state.panel ??= document.createElement("div");
    state.panel.id = PANEL_ID;
    state.liveRegion ??= document.createElement("div");
    state.liveRegion.className = "crmp-sr-only";
    state.liveRegion.setAttribute("role", "status");
    state.liveRegion.setAttribute("aria-live", "polite");
    state.liveRegion.setAttribute("aria-atomic", "true");
    document.body.appendChild(state.liveRegion);
    state.active = true;
    state.disposed = false;
    document.addEventListener("pointerdown", dismissOverlays);
    document.addEventListener("keydown", dismissOnEscape);
    document.addEventListener(UPDATE_EVENT, handleUpdateStatus);
    if (globalThis !== document && typeof globalThis.addEventListener === "function") globalThis.addEventListener(UPDATE_EVENT, handleUpdateStatus);
    if (!state.mountObserver) {
      state.mountObserver = new MutationObserver((mutations) => {
        if (!state.observerTarget?.isConnected || !state.nativeContainer?.isConnected) schedule(mutations);
      });
      state.mountObserver.observe(document.body, { childList: true, subtree: true });
    }
    observeSidebarMutations(state.nativeContainer?.parentElement ?? document.body);
    return render();
  }

  function setFilter(hostId) {
    state.filter = typeof hostId === "string" ? hostId : "all";
    return render();
  }

  function setAutoRegistration(enabled) {
    writeBoolean(AUTO_ENABLED_KEY, enabled === true);
    if (enabled !== true && state.autoRegistrationTimer !== null) {
      clearTimeout(state.autoRegistrationTimer);
      state.autoRegistrationTimer = null;
    }
    state.lastAction = { commandId: "set-auto-registration", invoked: true, enabled: enabled === true };
    return render();
  }

  function setView(view) {
    state.view = view === "native" ? "native" : "mobile";
    return render();
  }

  function uninstall() {
    state.disposed = true;
    state.autoArchiveGeneration += 1;
    state.localRuntimeGeneration += 1;
    for (const requestClient of state.localThreadListActiveClients) {
      const activeRequests = sharedThreadListRegistry.activeRequests.get(requestClient);
      if (activeRequests?.size) {
        quarantineLocalThreadListClient(requestClient, state.localRuntimeGeneration - 1, Promise.allSettled([...activeRequests]));
      }
    }
    document.removeEventListener("pointerdown", dismissOverlays);
    document.removeEventListener("keydown", dismissOnEscape);
    document.removeEventListener(UPDATE_EVENT, handleUpdateStatus);
    if (globalThis !== document && typeof globalThis.removeEventListener === "function") globalThis.removeEventListener(UPDATE_EVENT, handleUpdateStatus);
    state.observer?.disconnect();
    state.observer = null;
    state.observerTarget = null;
    state.mountObserver?.disconnect();
    state.mountObserver = null;
    if (state.scheduledFrame !== null) cancelAnimationFrame(state.scheduledFrame);
    state.scheduledFrame = null;
    if (state.autoRegistrationTimer !== null) clearTimeout(state.autoRegistrationTimer);
    state.autoRegistrationTimer = null;
    if (state.autoReconciliationTimer !== null) clearTimeout(state.autoReconciliationTimer);
    state.autoReconciliationTimer = null;
    if (state.autoArchiveTimer !== null) clearTimeout(state.autoArchiveTimer);
    state.autoArchiveTimer = null;
    if (state.autoArchiveLeaseTimer !== null) clearInterval(state.autoArchiveLeaseTimer);
    state.autoArchiveLeaseTimer = null;
    if (state.localInventoryPublisherTimer !== null) clearTimeout(state.localInventoryPublisherTimer);
    state.localInventoryPublisherTimer = null;
    if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
    state.inventoryHydrationTimer = null;
    if (state.mountRetryTimer !== null) clearTimeout(state.mountRetryTimer);
    state.mountRetryTimer = null;
    if (state.nativeContainer?.isConnected) state.nativeContainer.style.display = state.originalDisplay;
    state.nativeContainer = null;
    state.panel?.remove();
    state.liveRegion?.remove();
    document.getElementById(CARD_ID)?.remove();
    document.getElementById(CONTEXT_ID)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    state.active = false;
    const report = renderReport();
    for (const collection of [state.autoRegistrationFailures, state.collapsed, state.hostConnectivity, state.localRegisteredProjects, state.localRuntimeHostIds, state.peerCacheStates, state.remoteCodexHomes, state.remoteProjectInventories, state.remoteRuntimeCache, state.threadInventories, state.threadManagers, state.verifiedThreadIds]) collection.clear();
    state.localFetchFromHost = null;
    state.hostDiscoveryCache = null;
    state.hostDiscoveryDirty = true;
    state.localRuntime = null;
    state.navigationBridge = null;
    state.projectService = null;
    state.queryClient = null;
    return report;
  }

  loadVerifiedThreadIds();
  const api = Object.freeze({ install, previewAutoArchive, previewAutoMaintenance: previewAutoArchive, probe, reconcileAutoRegisteredProjects, removeAllAutoRegistered, runAutoArchiveNow, runAutoMaintenanceNow: runAutoArchiveNow, setAutoArchive, setAutoMaintenance: setAutoArchive, setAutoRegistration, setFilter, setView, uninstall, updateActivity, version: VERSION });
  Object.defineProperty(globalThis, API_SLOT, { configurable: true, enumerable: false, value: api });
  return install();
})();
