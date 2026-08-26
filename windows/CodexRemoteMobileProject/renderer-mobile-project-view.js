"use strict";

(() => {
  const API_SLOT = "__CODEX_REMOTE_MOBILE_PROJECT_VIEW__";
  const CARD_ID = "codex-remote-mobile-project-card";
  const CONFIG_SLOT = "__CODEX_REMOTE_MOBILE_CONFIG__";
  const CONTEXT_ID = "codex-remote-mobile-project-context";
  const PANEL_ID = "codex-remote-mobile-project-panel";
  const STYLE_ID = "codex-remote-mobile-project-style";
  const ROW_SELECTOR = "[data-app-action-sidebar-thread-row]";
  const AUTO_ENABLED_KEY = "codex-remote-mobile-auto-register-enabled-v1";
  const AUTO_MANAGED_KEY = "codex-remote-mobile-auto-managed-v1";
  const AUTO_SUPPRESSED_KEY = "codex-remote-mobile-auto-suppressed-v1";
  const AUTO_ARCHIVE_ENABLED_KEY = "codex-remote-mobile-auto-archive-enabled-v1";
  const AUTO_ARCHIVED_RECORDS_KEY = "codex-remote-mobile-auto-archived-records-v1";
  const AUTO_ARCHIVE_DAYS = 7;
  const AUTO_DELETE_AFTER_ARCHIVE_DAYS = 7;
  const AUTO_ARCHIVE_INTERVAL_MS = 60 * 60 * 1000;
  const AUTO_ARCHIVE_RETRY_MS = 5 * 60 * 1000;
  const REMOTE_UNREAD_ACK_KEY = "codex-remote-mobile-unread-ack-v1";
  const REMOTE_UNREAD_ACK_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;
  const LOCAL_REMOTE_PROJECTS_TTL_MS = 15000;
  const NATIVE_INVENTORY_REFRESH_MS = 15000;
  const REMOTE_INVENTORY_FILENAME = "remote-project-inventory-v1.json";
  const REMOTE_INVENTORY_MAX_AGE_MS = 180000;
  const REMOTE_INVENTORY_ACTIVE_MS = 5000;
  const REMOTE_INVENTORY_IDLE_MS = 15000;
  const REMOTE_INVENTORY_FUTURE_SKEW_MS = 5 * 60 * 1000;
  const REMOTE_INVENTORY_RETRY_MS = 15000;
  const REMOTE_INVENTORY_ACTIVE_TTL_MS = 5000;
  const REMOTE_INVENTORY_IDLE_TTL_MS = 30000;
  const VERSION = 49;
  const LOCAL_FOLDER_PATH = Object.freeze({
    closed: "M5.55957 2.14136C6.06503 2.14136 6.55801 2.30207 6.9668 2.59937L7.81836 3.21851C8.04761 3.38513 8.32401 3.47534 8.60742 3.47534H12.1338C13.4545 3.47559 14.5254 4.54621 14.5254 5.86694V11.4666C14.5254 12.7873 13.4545 13.8579 12.1338 13.8582H3.86621C2.54554 13.8579 1.47461 12.7873 1.47461 11.4666V4.53296C1.47486 3.21244 2.54569 2.1416 3.86621 2.14136H5.55957ZM2.52539 7.85718V11.4666C2.52539 12.2074 3.12544 12.8081 3.86621 12.8083H12.1338C12.8746 12.8081 13.4746 12.2074 13.4746 11.4666V7.85718H2.52539ZM3.86621 3.19214C3.12559 3.19238 2.52564 3.79234 2.52539 4.53296V6.8064H13.4746V5.86694C13.4746 5.12611 12.8746 4.52539 12.1338 4.52515H8.60742C8.10203 4.52515 7.60895 4.36534 7.2002 4.06812L6.34863 3.448C6.11937 3.28135 5.84301 3.19214 5.55957 3.19214H3.86621Z",
    open: "M4.75488 2.1416C5.30942 2.14164 5.74594 2.23705 6.11816 2.38965C6.48323 2.53934 6.76728 2.73817 7.00391 2.9043L7.02148 2.91699C7.47057 3.23238 7.8162 3.47463 8.55176 3.47461H11.333C12.7194 3.47484 13.8311 4.61217 13.8311 6L13.875 6.38281H13.8594C14.8729 6.38292 15.5982 7.3629 15.3018 8.33203L14.0068 12.5586C13.7703 13.3297 13.0576 13.8563 12.251 13.8564H3.83984C3.4199 13.8564 3.04144 13.7174 2.73828 13.4883L2.67383 13.4346C1.99907 12.9811 1.55577 12.2065 1.55566 11.3311L0.941406 4.66699C0.941406 3.2792 2.05315 2.1419 3.43945 2.1416H4.75488ZM4.7627 7.42969C4.56039 7.42972 4.3807 7.5625 4.32129 7.75586L3.08594 11.7891C2.96123 12.1965 3.18214 12.6072 3.54883 12.7529C3.63476 12.7768 3.74102 12.7958 3.88184 12.8086H12.251C12.5974 12.8085 12.9033 12.5821 13.0049 12.251L14.2998 8.02539C14.3901 7.72947 14.1688 7.42979 13.8594 7.42969H4.7627ZM3.43945 3.19141C2.64724 3.1917 1.99121 3.84481 1.99121 4.66699L2.49316 10.1201L3.32031 7.44922C3.51452 6.81571 4.10008 6.38284 4.7627 6.38281H12.8252L12.7812 6C12.7812 5.22902 12.2045 4.607 11.4795 4.53223L11.333 4.52441H8.55176C8.05756 4.52442 7.64464 4.44062 7.2666 4.2793C6.91453 4.12896 6.6274 3.92345 6.41797 3.77637L6.40039 3.76367C6.16212 3.59639 5.96404 3.46151 5.71973 3.36133C5.54113 3.28812 5.32754 3.2289 5.05176 3.2041L4.75488 3.19141H3.43945Z",
  });

  const previous = globalThis[API_SLOT];
  previous?.uninstall?.();
  globalThis.__CODEX_REMOTE_PROJECT_LABELS__?.uninstall?.();

  const config = globalThis[CONFIG_SLOT] ?? {};
  const state = {
    active: false,
    actionCardKey: null,
    autoArchiveError: null,
    autoArchiveLastRunAt: 0,
    autoArchiveLastResult: null,
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
    drag: null,
    dragJustEndedAt: 0,
    disposed: false,
    filter: "all",
    hostConnectivity: new Map(),
    inventoryHydrationPending: false,
    inventoryHydrationError: null,
    inventoryHydrationMicrotask: false,
    inventoryHydrationPhase: "idle",
    inventoryHydrationRounds: 0,
    inventoryHydrationStarted: false,
    inventoryHydrationTimer: null,
    inventoryHydrationTruncated: false,
    lastAction: null,
    localFetchFromHost: null,
    localCodexHome: null,
    localInventoryPublishedAt: 0,
    localInventoryProjects: [],
    localInventoryPublisherError: null,
    localInventoryPublisherPending: false,
    localInventoryPublisherTimer: null,
    localInventoryStatusSignature: "",
    localRegisteredProjects: new Map(),
    localRegisteredProjectsError: null,
    localRegisteredProjectsFetchedAt: 0,
    localRegisteredProjectsPending: false,
    localRuntime: null,
    navigationBridge: null,
    nativeContainer: null,
    originalDisplay: "",
    observer: null,
    panel: null,
    pendingNewThreads: new Set(),
    peerCacheStates: new Map(),
    projectService: null,
    queryClient: null,
    remoteProjectInventories: new Map(),
    remoteCodexHomes: new Map(),
    remoteRuntimeCache: new Map(),
    remoteRuntimeScannedAt: 0,
    reorderPending: false,
    scheduledFrame: null,
    threadInventories: new Map(),
    threadManagers: new Map(),
    view: "mobile",
  };

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

  function remoteUnreadIdentity(hostId, conversationKey) {
    return `${normalizeHostId(hostId)}::${conversationKey}`;
  }

  function acknowledgeRemoteUnread(task) {
    if (!task?.conversationKey || task.hostId === "local") return;
    const records = readRecords(REMOTE_UNREAD_ACK_KEY);
    records[remoteUnreadIdentity(task.hostId, task.conversationId || task.conversationKey)] = { acknowledgedAt: Date.now() };
    writeRecords(REMOTE_UNREAD_ACK_KEY, records);
  }

  function remoteUnreadAcknowledged(task, authoritativeState) {
    if (!task?.conversationKey || task.hostId === "local") return false;
    const records = readRecords(REMOTE_UNREAD_ACK_KEY);
    const key = remoteUnreadIdentity(task.hostId, task.conversationId || task.conversationKey);
    const record = records[key];
    if (!record) return false;
    const acknowledgedAt = Number(record.acknowledgedAt);
    const expired = !Number.isFinite(acknowledgedAt) || Date.now() - acknowledgedAt > REMOTE_UNREAD_ACK_MAX_AGE_MS;
    const transitioned = !authoritativeState || authoritativeState.statusType === "loading" || authoritativeState.unread !== true;
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
    let statusType = "idle";
    let unread = false;
    const hostNames = new Map();
    let fiber = getFiber(row);
    for (let level = 0; fiber && level < 80; level += 1, fiber = fiber.return) {
      const props = fiber.memoizedProps;
      cwd ??= cwdFromProps(props);
      if (typeof props?.hoverCardProjectId === "string" && props.hoverCardProjectId) projectId ??= props.hoverCardProjectId;
      if (typeof props?.hoverCardProjectLabel === "string" && props.hoverCardProjectLabel.trim()) projectLabel ??= props.hoverCardProjectLabel.trim();
      if (isGrouped === null && typeof props?.isGrouped === "boolean") isGrouped = props.isGrouped;
      if (isProjectless === null && typeof props?.isProjectlessHoverCard === "boolean") isProjectless = props.isProjectlessHoverCard;
      if (props?.statusState && typeof props.statusState === "object") {
        if (statusType === "idle" && typeof props.statusState.type === "string") statusType = props.statusState.type;
        if (props.statusState.unread === true) unread = true;
      }
      if (props?.isUnread === true) unread = true;
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
    return { conversationId, conversationKey, cwd, hostDisplayName, hostId, hostNames, isGrouped, isProjectless, originalRow: row, projectId, projectLabel, selected, statusType, title, unread };
  }

  function commonAncestor(elements) {
    if (!elements.length) return null;
    let candidate = elements[0].parentElement;
    while (candidate && !elements.every((element) => candidate.contains(element))) {
      candidate = candidate.parentElement;
    }
    return candidate;
  }

  function discoverHostNames() {
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
          if (currentSeenAt === undefined || (Number.isFinite(seenAt) && (!Number.isFinite(currentSeenAt) || seenAt >= currentSeenAt))) {
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
      if (hostId === "local" && typeof value.fetchFromHost === "function") {
        const localRequestClient = typeof value.sendRequest === "function" ? value : value.requestClient;
        state.localFetchFromHost = value.fetchFromHost.bind(value);
        if (typeof localRequestClient?.sendRequest === "function") {
          state.localRuntime = { fetchFromHost: state.localFetchFromHost, requestClient: localRequestClient };
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
        for (const [key, item] of [...value.entries()].slice(0, 1000)) {
          scan(key, depth + 1);
          scan(item, depth + 1);
        }
        return;
      }
      if (value instanceof Set) {
        for (const item of [...value].slice(0, 1000)) scan(item, depth + 1);
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
        if (typeof group?.hostId === "string" && typeof group?.hostDisplayName === "string") {
          authoritativeNames.set(group.hostId, group.hostDisplayName);
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
        if (group?.projectKind === "remote" && typeof group.hostId === "string" && typeof group.hostDisplayName === "string") {
          names.set(group.hostId, group.hostDisplayName);
          break;
        }
      }
    }
    return { names, availability, registeredProjects, runtimes };
  }

  function discoverRemoteRuntimes(fallback) {
    const now = Date.now();
    if (now - state.remoteRuntimeScannedAt < 30000 && state.remoteRuntimeCache.size) return state.remoteRuntimeCache;
    const runtimes = new Map(fallback);
    const anchor = document.querySelector(ROW_SELECTOR)
      ?? document.querySelector('[data-sidebar-project-kind][role="listitem"]');
    let root = anchor ? getFiber(anchor) : null;
    while (root?.return) root = root.return;
    const fibers = [];
    const seenFibers = new Set();
    const queue = root ? [root] : [];
    while (queue.length && fibers.length < 20000) {
      const fiber = queue.shift();
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
        if (hostId === "local" && fetchFromHost) {
          const localRequestClient = typeof value.sendRequest === "function" ? value : value.requestClient;
          state.localFetchFromHost = fetchFromHost;
          if (typeof localRequestClient?.sendRequest === "function") state.localRuntime = { fetchFromHost, requestClient: localRequestClient };
        }
      } catch {}
      if (Array.isArray(value)) {
        for (const item of value.slice(0, 200)) scan(item, depth + 1);
        return;
      }
      if (value instanceof Map) {
        for (const [key, item] of [...value.entries()].slice(0, 1000)) {
          scan(key, depth + 1);
          scan(item, depth + 1);
        }
        return;
      }
      if (value instanceof Set) {
        for (const item of [...value].slice(0, 1000)) scan(item, depth + 1);
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
    const result = await state.localFetchFromHost("get-global-state", { params: { key: "remote-projects" } });
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
    if (!inventory?.fetchedAt || !Number.isFinite(inventory.generatedAt)) return null;
    const now = Date.now();
    if (now - inventory.fetchedAt > REMOTE_INVENTORY_MAX_AGE_MS || now - inventory.generatedAt > REMOTE_INVENTORY_MAX_AGE_MS) return null;
    return inventory;
  }

  function inventoryMatchesLocal(inventory) {
    const localThreads = state.threadInventories.get("local");
    if (localThreads && !localThreads.error && inventory?.threadsAuthoritative === true) {
      const localIds = new Set((localThreads.threads ?? []).map((thread) => rawConversationId(thread?.id ?? thread?.conversationId ?? "")).filter(Boolean));
      const remoteIds = new Set((inventory.threads ?? []).map((thread) => rawConversationId(thread?.id ?? "")).filter(Boolean));
      if (localIds.size > 0 && localIds.size === remoteIds.size && [...localIds].every((id) => remoteIds.has(id))) return true;
    }
    const localPaths = new Set(state.localInventoryProjects.map((project) => normalizePath(project.cwd)));
    const remotePaths = new Set((inventory?.projects ?? []).map((project) => normalizePath(project.cwd)));
    return localPaths.size > 0 && localPaths.size === remotePaths.size && [...localPaths].every((path) => remotePaths.has(path));
  }

  function removeGossipedLocalInventoryDuplicates() {
    for (const [hostId, inventory] of state.remoteProjectInventories) {
      if (inventory.sourcePeerHostId && inventoryMatchesLocal(inventory)) state.remoteProjectInventories.delete(hostId);
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

  function authoritativeInventory(hostId) {
    return freshInventory(hostId);
  }

  function inventoryContainsProject(inventory, project) {
    if (!inventory || !project?.cwd) return false;
    const path = normalizePath(project.cwd);
    return inventory.projects.some((candidate) => normalizePath(candidate.cwd) === path);
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
    if (Date.now() - generatedAt > REMOTE_INVENTORY_MAX_AGE_MS) throw new Error("Remote project inventory is stale");
    if (generatedAt - Date.now() > REMOTE_INVENTORY_FUTURE_SKEW_MS) throw new Error("Remote project inventory timestamp is in the future");
    const entries = Array.isArray(value.projects) ? value.projects.slice(0, 500) : [];
    const projects = new Map();
    for (const metadata of entries) {
      if (!metadata || typeof metadata !== "object" || !Array.isArray(metadata.rootPaths)) continue;
      const cwd = canonicalRemotePath(metadata.rootPaths[0]);
      if (!isRemoteProjectInventoryPath(cwd)) continue;
      const name = typeof metadata.name === "string" && metadata.name.trim()
        ? metadata.name.trim()
        : projectName(cwd);
      projects.set(normalizePath(cwd), { cwd, name, source: "host-projects" });
    }
    const tasks = new Map();
    for (const metadata of Array.isArray(value.tasks) ? value.tasks.slice(0, 2000) : []) {
      if (!metadata || typeof metadata !== "object" || typeof metadata.conversationKey !== "string" || !metadata.conversationKey) continue;
      const unread = metadata.unread === true;
      const statusType = metadata.statusType === "loading" ? "loading" : "idle";
      if (unread || statusType === "loading") tasks.set(metadata.conversationKey, { statusType, unread });
    }
    const threadsAuthoritative = Array.isArray(value.threads);
    const threads = (threadsAuthoritative ? value.threads : []).slice(0, 10000).flatMap((thread) => {
      const id = rawConversationId(thread?.id ?? "");
      if (!id) return [];
      return [{
        cwd: canonicalRemotePath(thread?.cwd),
        hasUnreadTurn: thread?.hasUnreadTurn === true,
        id,
        projectId: typeof thread?.projectId === "string" ? thread.projectId : null,
        status: typeof thread?.status === "string" ? thread.status : thread?.status?.type,
        title: typeof thread?.title === "string" ? thread.title : "Untitled task",
        updatedAt: thread?.updatedAt ?? null,
        workspaceKind: typeof thread?.workspaceKind === "string" ? thread.workspaceKind : null,
      }];
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
    return { generatedAt, peers, projects: [...projects.values()].sort((left, right) => left.name.localeCompare(right.name)), tasks, threads, threadsAuthoritative };
  }

  function parseRemoteProjectInventory(result) {
    if (typeof result?.dataBase64 !== "string") throw new Error("Remote project inventory did not contain file data");
    return parseInventoryPayload(JSON.parse(decodeText(result.dataBase64)), true);
  }

  function scheduleRemoteProjectInventory(runtimes) {
    if (state.disposed) return;
    const now = Date.now();
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
      const resolveCodexHome = state.remoteCodexHomes.has(hostId)
        ? Promise.resolve(state.remoteCodexHomes.get(hostId))
        : runtime.requestClient.sendRequest("config/read", { cwd: null, includeLayers: true }).then((configResult) => {
          const codexHome = findCodexHome(configResult);
          if (!codexHome) throw new Error("Remote Codex home was not reported");
          state.remoteCodexHomes.set(hostId, codexHome);
          return codexHome;
        });
      resolveCodexHome.then((codexHome) => runtime.requestClient.sendRequest("fs/readFile", { path: inventoryPath(codexHome) })).then((result) => {
        if (state.disposed) return;
        const parsed = parseRemoteProjectInventory(result);
        state.hostConnectivity.set(hostId, { available: true, checkedAt: Date.now() });
        const latest = state.remoteProjectInventories.get(hostId);
        if (Number.isFinite(latest?.generatedAt) && latest.generatedAt > parsed.generatedAt && latest.error == null) return;
        state.remoteProjectInventories.set(hostId, {
          error: null,
          fetchedAt: Date.now(),
          generatedAt: parsed.generatedAt,
          pending: false,
          projects: parsed.projects,
          retryAt: 0,
          tasks: parsed.tasks,
          threads: parsed.threads,
          threadsAuthoritative: parsed.threadsAuthoritative,
        });
        for (const [peerHostId, peer] of parsed.peers) {
          if (peerHostId === hostId) continue;
          if (inventoryMatchesLocal(peer)) continue;
          const existing = state.remoteProjectInventories.get(peerHostId);
          if (Number.isFinite(existing?.generatedAt) && existing.generatedAt >= peer.generatedAt && existing.error == null) continue;
          state.remoteProjectInventories.set(peerHostId, {
            error: null,
            fetchedAt: Date.now(),
            generatedAt: peer.generatedAt,
            pending: false,
            projects: peer.projects,
            retryAt: existing?.retryAt ?? 0,
            sourcePeerHostId: hostId,
            tasks: peer.tasks,
            threads: peer.threads,
            threadsAuthoritative: peer.threadsAuthoritative,
          });
        }
      }).catch((error) => {
        if (state.disposed) return;
        state.hostConnectivity.set(hostId, { available: false, checkedAt: Date.now() });
        state.remoteCodexHomes.delete(hostId);
        const latest = state.remoteProjectInventories.get(hostId);
        if (latest?.sourcePeerCache && freshInventory(hostId)) return;
        state.remoteProjectInventories.set(hostId, {
          error: error?.message || String(error),
          fetchedAt: latest?.fetchedAt ?? 0,
          generatedAt: latest?.generatedAt,
          pending: false,
          projects: latest?.projects ?? current.projects ?? [],
          retryAt: Date.now() + REMOTE_INVENTORY_RETRY_MS,
          sourcePeerCache: latest?.sourcePeerCache === true,
          sourcePeerHostId: latest?.sourcePeerHostId,
          tasks: latest?.tasks ?? current.tasks ?? new Map(),
          threads: latest?.threads ?? current.threads ?? [],
          threadsAuthoritative: latest?.threadsAuthoritative === true || current.threadsAuthoritative === true,
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
        : runtime.requestClient.sendRequest("config/read", { cwd: null, includeLayers: true }).then((configResult) => {
          const codexHome = findCodexHome(configResult);
          if (!codexHome) throw new Error("Remote Codex home was not reported");
          state.remoteCodexHomes.set(hostId, codexHome);
          return codexHome;
        });
      void resolveCodexHome
        .then((codexHome) => runtime.requestClient.sendRequest("fs/writeFile", {
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
      runtime.requestClient.sendRequest("fs/readFile", { path: peerInventoryPath(state.localCodexHome, host.name) }).then((result) => {
        if (state.disposed) return;
        const parsed = parseRemoteProjectInventory(result);
        const existing = state.remoteProjectInventories.get(host.id);
        if (!Number.isFinite(existing?.generatedAt) || parsed.generatedAt >= existing.generatedAt || existing.error) {
          state.remoteProjectInventories.set(host.id, {
            error: null,
            fetchedAt: Date.now(),
            generatedAt: parsed.generatedAt,
            pending: false,
            projects: parsed.projects,
            retryAt: existing?.retryAt ?? 0,
            sourcePeerCache: true,
            tasks: parsed.tasks,
            threads: parsed.threads,
            threadsAuthoritative: parsed.threadsAuthoritative,
          });
        }
        state.peerCacheStates.set(host.id, { error: null, fetchedAt: Date.now(), pending: false });
      }).catch((error) => {
        state.peerCacheStates.set(host.id, { error: error?.message || String(error), fetchedAt: Date.now(), pending: false });
      }).finally(() => { if (!state.disposed) schedule(); });
    }
  }

  function scheduleLocalProjectInventoryPublication() {
    const runtime = state.localRuntime;
    const now = Date.now();
    if (!runtime || state.disposed || state.localInventoryPublisherPending || !state.threadInventories.has("local")) return;
    const tasks = [...document.querySelectorAll(ROW_SELECTOR)]
      .filter((row) => !row.closest(`#${PANEL_ID}`))
      .map(metadataFromRow)
      .filter((task) => task.hostId === "local" && (task.unread || task.statusType === "loading"))
      .map((task) => ({ conversationKey: task.conversationId || rawConversationId(task.conversationKey), statusType: task.statusType, unread: task.unread }));
    const threads = (state.threadInventories.get("local")?.threads ?? []).flatMap((thread) => {
      const id = rawConversationId(thread?.id ?? thread?.conversationId ?? "");
      if (!id) return [];
      return [{
        cwd: canonicalRemotePath(thread?.cwd),
        hasUnreadTurn: thread?.hasUnreadTurn === true,
        id,
        projectId: typeof thread?.projectId === "string" ? thread.projectId : null,
        status: typeof thread?.status === "string" ? thread.status : thread?.status?.type,
        title: typeof thread?.title === "string" && thread.title.trim() ? thread.title.trim() : "Untitled task",
        updatedAt: thread?.updatedAt ?? null,
        workspaceKind: typeof thread?.workspaceKind === "string" ? thread.workspaceKind : null,
      }];
    });
    const peers = Object.fromEntries([...state.remoteProjectInventories].flatMap(([hostId]) => {
      const inventory = freshInventory(hostId);
      if (!inventory || inventory.threadsAuthoritative !== true) return [];
      return [[hostId, {
        generatedAt: new Date(inventory.generatedAt).toISOString(),
        projects: (inventory.projects ?? []).map((project) => ({ name: project.name, rootPaths: [project.cwd] })),
        schemaVersion: 1,
        tasks: [...(inventory.tasks ?? new Map())].map(([conversationKey, task]) => ({ conversationKey, statusType: task.statusType, unread: task.unread })),
        threads: inventory.threads ?? [],
      }]];
    }));
    const statusSignature = JSON.stringify({ peers, tasks, threads });
    const publishInterval = tasks.length ? REMOTE_INVENTORY_ACTIVE_MS : REMOTE_INVENTORY_IDLE_MS;
    const statusChanged = statusSignature !== state.localInventoryStatusSignature;
    if (!statusChanged && now - state.localInventoryPublishedAt < publishInterval) return;
    state.localInventoryPublisherPending = true;
    Promise.all([
      runtime.fetchFromHost("get-global-state", { params: { key: "local-projects" } }),
      runtime.requestClient.sendRequest("config/read", { cwd: null, includeLayers: true }),
    ]).then(([projectsResult, configResult]) => {
      const codexHome = findCodexHome(configResult);
      if (!codexHome) throw new Error("Local Codex home was not reported");
      state.localCodexHome = codexHome;
      const values = projectsResult?.value && typeof projectsResult.value === "object" && !Array.isArray(projectsResult.value)
        ? Object.values(projectsResult.value)
        : [];
      const projects = values.flatMap((project) => {
        if (!project || typeof project !== "object" || !Array.isArray(project.rootPaths) || !project.rootPaths.length) return [];
        const rootPaths = project.rootPaths.map(canonicalRemotePath).filter(Boolean);
        if (!rootPaths.length) return [];
        return [{
          id: typeof project.id === "string" ? project.id : null,
          name: typeof project.name === "string" && project.name.trim() ? project.name.trim() : projectName(rootPaths[0]),
          rootPaths,
        }];
      });
      state.localInventoryProjects = projects.map((project) => ({
        cwd: project.rootPaths[0],
        hostDisplayName: null,
        hostId: "local",
        item: null,
        label: project.name,
        projectId: project.id,
      })).filter((project) => project.projectId && project.cwd);
      const payload = JSON.stringify({ generatedAt: new Date().toISOString(), peers, projects, schemaVersion: 1, tasks, threads });
      const dataBase64 = encodeText(payload);
      return runtime.requestClient.sendRequest("fs/writeFile", { dataBase64, path: inventoryPath(codexHome) })
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
    return typeof value !== "string" || /^(?:Remote\s+)?(?:remote-control:)?env_/iu.test(value.trim());
  }

  function hostName(hostId, discoveredNames, singleRemoteHostId) {
    if (hostId === "local") return config.localDisplayName || "Local";
    const discovered = discoveredNames.get(hostId);
    if (!isSyntheticHostName(discovered)) return discovered;
    if (typeof config.hostDisplayNames?.[hostId] === "string") return config.hostDisplayNames[hostId];
    if (hostId === singleRemoteHostId && typeof config.singleRemoteDisplayName === "string") return config.singleRemoteDisplayName;
    return discovered || hostId.replace(/^remote-control:/u, "Remote ");
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
      const cwd = typeof group.path === "string" && group.path.trim() ? group.path : null;
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
      statusType: /^(?:active|inProgress|running|working)$/iu.test(runtimeStatus || "") ? "loading" : "idle",
      title: typeof thread?.title === "string" && thread.title.trim() ? thread.title.trim() : "Untitled task",
      unread: thread?.hasUnreadTurn === true || thread?.unread === true,
    };
  }

  function collectModel() {
    const rows = [...document.querySelectorAll(ROW_SELECTOR)].filter((row) => !row.closest(`#${PANEL_ID}`));
    const authoritativeIds = new Map();
    for (const [hostId, inventory] of state.threadInventories) {
      if (!inventory.error) authoritativeIds.set(hostId, new Set((inventory.threads ?? []).map((thread) => rawConversationId(thread?.id ?? thread?.conversationId ?? "")).filter(Boolean)));
    }
    for (const [hostId] of state.remoteProjectInventories) {
      const inventory = freshInventory(hostId);
      if (inventory?.threadsAuthoritative === true) authoritativeIds.set(hostId, new Set((inventory.threads ?? []).map((thread) => rawConversationId(thread?.id ?? "")).filter(Boolean)));
    }
    const taskMap = new Map();
    for (const task of rows.map(metadataFromRow).filter((task) => task.conversationId)) {
      if (authoritativeIds.has(task.hostId) && !authoritativeIds.get(task.hostId).has(task.conversationId)) continue;
      taskMap.set(`${task.hostId}::${task.conversationId}`, task);
    }
    for (const [hostId, inventory] of state.threadInventories) {
      for (const thread of inventory.threads ?? []) {
        const task = taskFromThread(thread, hostId);
        if (!task) continue;
        const key = `${hostId}::${task.conversationId}`;
        const nativeTask = taskMap.get(key);
        if (nativeTask) {
          nativeTask.cwd ??= task.cwd;
          nativeTask.projectId ??= task.projectId;
          nativeTask.projectLabel ??= task.projectLabel;
          nativeTask.sourceThread = thread;
          nativeTask.title = nativeTask.title === "Untitled task" ? task.title : nativeTask.title;
          nativeTask.unread ||= task.unread;
        } else {
          taskMap.set(key, task);
        }
      }
    }
    for (const [hostId] of state.remoteProjectInventories) {
      const inventory = freshInventory(hostId);
      for (const thread of inventory?.threads ?? []) {
        const task = taskFromThread(thread, hostId);
        if (!task) continue;
        const key = `${hostId}::${task.conversationId}`;
        const existing = taskMap.get(key);
        if (existing) {
          existing.cwd ??= task.cwd;
          existing.projectId ??= task.projectId;
          existing.title = existing.title === "Untitled task" ? task.title : existing.title;
          existing.unread ||= task.unread;
        } else {
          taskMap.set(key, task);
        }
      }
    }
    const tasks = [...taskMap.values()];
    const remoteInventoryProjects = inventoryProjects();
    const authoritativeProjectPaths = new Map();
    if (state.localInventoryPublishedAt > 0) authoritativeProjectPaths.set("local", new Set(state.localInventoryProjects.map((project) => normalizePath(project.cwd))));
    for (const project of remoteInventoryProjects) {
      if (!authoritativeProjectPaths.has(project.hostId)) authoritativeProjectPaths.set(project.hostId, new Set());
      authoritativeProjectPaths.get(project.hostId).add(normalizePath(project.cwd));
    }
    const projectIsAuthoritative = (project) => !authoritativeProjectPaths.has(project.hostId)
      || Boolean(project.cwd && authoritativeProjectPaths.get(project.hostId).has(normalizePath(project.cwd)));
    const domNativeProjects = [...document.querySelectorAll('[data-sidebar-project-kind][role="listitem"]')]
      .map(metadataFromNativeProject)
      .filter((project) => project && projectIsAuthoritative(project));
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
      if (!inventory) continue;
      const authoritativeState = inventory.tasks?.get(task.conversationKey) ?? inventory.tasks?.get(task.conversationId) ?? null;
      if (!authoritativeState) {
        remoteUnreadAcknowledged(task, null);
        continue;
      }
      task.statusType = authoritativeState.statusType;
      task.unread = authoritativeState.unread && !remoteUnreadAcknowledged(task, authoritativeState);
    }
    const names = hostDiscovery.names;
    const availability = hostDiscovery.availability;
    for (const [hostId, connectivity] of state.hostConnectivity) {
      if (typeof connectivity?.available === "boolean") availability.set(hostId, connectivity.available);
    }
    for (const task of tasks) {
      for (const [id, name] of task.hostNames) {
        if (!names.has(id)) names.set(id, name);
      }
      if (task.hostDisplayName && task.hostId !== "local" && !names.has(task.hostId)) names.set(task.hostId, task.hostDisplayName);
    }
    for (const project of nativeProjects) {
      if (project.hostDisplayName && project.hostId !== "local") names.set(project.hostId, project.hostDisplayName);
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
          available: availability.get(item.hostId) !== false,
          availabilityKnown: item.hostId === "local" || availability.has(item.hostId),
        });
      }
    }

    const groups = [];
    const groupsByKey = new Map();
    const projectByHostPath = new Map();
    for (const project of nativeProjects) {
      const key = `${project.hostId}::project:${project.projectId}`;
      if (groupsByKey.has(key)) continue;
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
      if (project.cwd) projectByHostPath.set(`${project.hostId}::${normalizePath(project.cwd)}`, group);
      groups.push(group);
    }
    for (const project of remoteInventoryProjects) {
      const pathKey = `${project.hostId}::${normalizePath(project.cwd)}`;
      if (projectByHostPath.has(pathKey)) continue;
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
      projectByHostPath.set(pathKey, group);
      groups.push(group);
    }
    for (const task of tasks) {
      const cwdKey = task.cwd ? normalizePath(task.cwd) : `unknown:${task.conversationKey}`;
      const matchingProject = task.cwd ? projectByHostPath.get(`${task.hostId}::${cwdKey}`) : null;
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
      nativeProjectItems: nativeProjects.map((project) => project.item),
      remoteRuntimes: discoverRemoteRuntimes(hostDiscovery.runtimes),
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
      #${PANEL_ID} .crmp-modes { display:flex; gap:4px; padding-bottom:2px; }
      #${PANEL_ID} .crmp-mode { border:0; border-radius:5px; padding:3px 6px; color:var(--color-text-tertiary,#888); background:transparent; font-size:10px; cursor:pointer; }
      #${PANEL_ID} .crmp-mode[aria-pressed="true"] { color:var(--color-text,#eee); background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-filters { display:flex; flex-wrap:wrap; gap:6px; padding:2px 0 6px; }
      #${PANEL_ID} .crmp-auto-controls { display:flex; align-items:center; flex-wrap:wrap; gap:6px; padding:0 0 4px; }
      #${PANEL_ID} .crmp-inventory-status { padding:2px 4px 6px; color:var(--color-text-tertiary,#888); font-size:11px; line-height:1.35; }
      #${PANEL_ID} .crmp-auto-control { border:1px solid var(--color-border-default,#555); border-radius:6px; padding:3px 7px; color:var(--color-text-tertiary,#888); background:transparent; font-size:10px; cursor:pointer; }
      #${PANEL_ID} .crmp-auto-control[aria-pressed="true"] { color:var(--color-text,#eee); background:var(--color-background-primary-hover,rgba(127,127,127,.15)); }
      #${PANEL_ID} .crmp-auto-control:disabled { cursor:not-allowed; opacity:.5; }
      #${PANEL_ID} .crmp-title { padding:0 4px 2px; color:var(--color-text,#eee); font-size:12px; font-weight:600; }
      #${PANEL_ID} .crmp-chip { flex:0 0 auto; border:1px solid var(--color-border-default,#555); border-radius:999px; padding:4px 9px; color:var(--color-text-secondary,#aaa); background:var(--color-background-secondary,transparent); font-size:11px; line-height:16px; text-align:left; white-space:nowrap; cursor:pointer; }
      #${PANEL_ID} .crmp-chip[aria-pressed="true"] { color:var(--color-text,#fff); background:var(--color-background-inverted,#333); border-color:transparent; }
      #${PANEL_ID} .crmp-dot { display:inline-block; width:7px; height:7px; margin-inline-end:5px; border-radius:50%; background:#24b47e; }
      #${PANEL_ID} .crmp-dot-unavailable { background:#d95757; }
      #${PANEL_ID} .crmp-project { display:flex; flex-direction:column; gap:1px; }
      #${PANEL_ID} .crmp-project-head { position:relative!important; display:flex!important; align-items:center; width:100%; min-height:var(--height-token-row,30px); }
      #${PANEL_ID} .crmp-project-toggle { display:grid; flex:1 1 auto; grid-template-columns:auto minmax(0,1fr) auto; align-items:center; gap:6px; min-width:0; height:100%; border:0; padding:5px 8px; color:inherit; background:transparent; text-align:left; cursor:pointer; }
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
      #${PANEL_ID} .crmp-folder { display:flex; width:16px; height:16px; align-items:center; justify-content:center; font-size:15px; }
      #${PANEL_ID} .crmp-folder svg { width:16px; height:16px; }
      #${PANEL_ID} .crmp-project-name { overflow:hidden; font-size:13px; font-weight:600; text-overflow:ellipsis; white-space:nowrap; }
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
      #${PANEL_ID} .crmp-task-status-loading svg { width:16px; height:16px; animation:crmp-task-spin 850ms linear infinite; }
      #${PANEL_ID} .crmp-task-unread-dot { display:block; width:7px; height:7px; border-radius:50%; background:#74b9ff; }
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

  function bindActivation(element, handler) {
    let handledByPointer = false;
    element.addEventListener("pointerup", (event) => {
      if (event.button > 0 || element.disabled) return;
      handledByPointer = true;
      event.preventDefault();
      event.stopImmediatePropagation();
      handler();
    });
    element.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (handledByPointer) {
        handledByPointer = false;
        return;
      }
      if (!element.disabled) handler();
    });
  }

  function invokeNativeElement(element) {
    if (!(element instanceof Element)) return false;
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

  async function hydrateNativeInventory() {
    if (state.inventoryHydrationPending) return;
    state.inventoryHydrationPending = true;
    state.inventoryHydrationError = null;
    state.inventoryHydrationPhase = "listing-threads";
    state.inventoryHydrationTruncated = false;
    try {
      discoverHostNames();
      const runtimes = new Map();
      if (state.localRuntime?.requestClient) runtimes.set("local", state.localRuntime);
      const tasks = [...runtimes].map(async ([hostId, runtime]) => {
        let timer = null;
        try {
          const manager = state.threadManagers.get(hostId);
          const request = typeof manager?.listAllThreads === "function"
            ? Promise.resolve(manager.listAllThreads({ archived: false, modelProviders: null })).then((threads) => ({ pages: 1, threads }))
            : listAllRuntimeThreads(runtime.requestClient, false);
          const timeout = new Promise((resolve, reject) => {
            timer = setTimeout(() => reject(new Error("Thread inventory timed out")), 12000);
          });
          const result = await Promise.race([request, timeout]);
          const inventory = { error: null, fetchedAt: Date.now(), hostId, pages: result.pages, threads: Array.isArray(result.threads) ? result.threads : [] };
          state.threadInventories.set(hostId, inventory);
          state.inventoryHydrationRounds += inventory.pages;
          if (hostId === "local") removeGossipedLocalInventoryDuplicates();
          if (!state.disposed) schedule();
          return inventory;
        } catch (error) {
          const inventory = { error: String(error?.message ?? error).slice(0, 240), fetchedAt: Date.now(), hostId, pages: 0, threads: state.threadInventories.get(hostId)?.threads ?? [] };
          state.threadInventories.set(hostId, inventory);
          if (!state.disposed) schedule();
          return inventory;
        } finally {
          if (timer !== null) clearTimeout(timer);
        }
      });
      const results = await Promise.all(tasks);
      const errors = results.filter((result) => result.error).map((result) => `${result.hostId}: ${result.error}`);
      state.inventoryHydrationError = errors.length ? errors.join("; ").slice(0, 240) : null;
      state.inventoryHydrationTruncated = results.some((result) => result.threads.length >= 9800);
    } catch (error) {
      state.inventoryHydrationError = String(error?.message ?? error).slice(0, 240);
    } finally {
      state.inventoryHydrationPending = false;
      state.inventoryHydrationPhase = "idle";
      if (!state.disposed) render();
    }
  }

  function scheduleNativeInventoryHydration() {
    if (state.inventoryHydrationPending || state.inventoryHydrationTimer !== null || !document.querySelector('[aria-label="Project sidebar options"]')) return;
    if (!state.inventoryHydrationStarted) {
      state.inventoryHydrationStarted = true;
      void hydrateNativeInventory();
      return;
    }
    const delay = NATIVE_INVENTORY_REFRESH_MS;
    state.inventoryHydrationStarted = true;
    state.inventoryHydrationTimer = setTimeout(() => {
      state.inventoryHydrationTimer = null;
      void hydrateNativeInventory();
    }, delay);
  }

  function taskStatusIndicator(task) {
    const working = task.statusType === "loading";
    if (!working && !task.unread) return null;
    const status = document.createElement("span");
    status.className = `crmp-task-status ${working ? "crmp-task-status-loading" : "crmp-task-status-unread"}`;
    status.setAttribute("aria-hidden", "true");
    if (working) {
      const nativeSpinner = [...(task.originalRow?.querySelectorAll("svg") ?? [])]
        .find((svg) => !svg.closest("button") && svg.classList.contains("icon-xs"));
      if (nativeSpinner) {
        status.appendChild(nativeSpinner.cloneNode(true));
      } else {
        status.innerHTML = '<svg viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path opacity="0.3" d="M18 12a6 6 0 1 1-6-6 6 6 0 0 1 6 6Zm2 0a8 8 0 1 0-8 8 8 8 0 0 0 8-8Z" fill="currentColor"/><path d="M12 4a8 8 0 0 1 8 8h-2a6 6 0 0 0-6-6V4Z" fill="currentColor"/></svg>';
      }
    } else {
      const dot = document.createElement("span");
      dot.className = "crmp-task-unread-dot";
      status.appendChild(dot);
    }
    return status;
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
      const byId = items.find((item) => item.querySelector(`[data-app-action-sidebar-project-list-id="${CSS.escape(project.projectId)}"]`));
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
    const canDrag = !state.reorderPending && Boolean(nativeKeyboardReorder(reorderElement(reference)) && sortableSnapshot(reorderElement(reference)));
    sourceElement.draggable = canDrag;
    if (!canDrag) return;
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
    clone.classList.add(customClass);
    return clone;
  }

  function folderIconFromRow(row) {
    return [...(row?.querySelectorAll("svg") ?? [])].find((icon) => !icon.closest("button")) ?? null;
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
    const item = row.closest("[data-sidebar-project-kind]");
    const nativeKind = item?.getAttribute("data-sidebar-project-kind");
    const desiredCollapsed = String(!expanded);
    const template = [...document.querySelectorAll(`[data-sidebar-project-kind="${CSS.escape(nativeKind || "local")}"] [data-app-action-sidebar-project-collapsed="${desiredCollapsed}"]`)]
      .map(folderIconFromRow)
      .find(Boolean);
    const icon = (template ?? ownIcon).cloneNode(true);
    const paths = [...icon.querySelectorAll("path")];
    const folderPath = paths.at(-1);
    for (const decoration of paths.slice(0, -1)) decoration.remove();
    icon.style.removeProperty("--remote-host-globe-color");
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
      action.click();
      state.lastAction = { actionName, found: true, hostId: task.hostId, invoked: true, task: task.title };
    } catch (error) {
      state.lastAction = { actionName, error: error?.message || String(error), found: true, hostId: task.hostId, invoked: false, task: task.title };
    }
  }

  async function openNativeTask(task) {
    const nativeRow = nativeThreadRow(task) ?? task.originalRow;
    if (nativeRow?.isConnected) {
      nativeRow.click();
      return true;
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

  async function registerRemoteProjectAndOpen(project, navigate) {
    navigate({
      activeProject: null,
      pendingRemoteProjectHostId: project.hostId,
      pendingViewAction: "open-create-remote-project-modal",
      prefillComposerMode: "local",
    });
    const dialog = await waitFor(remoteProjectDialog);
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
    if (!readBoolean(AUTO_ENABLED_KEY) || state.autoRegistrationPending || state.autoReconciliationPending || remoteProjectDialog()) return null;
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
    const result = await state.localFetchFromHost("set-global-state", { params: { key, value } });
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

  async function listAllRuntimeThreads(requestClient, archived = false) {
    if (typeof requestClient?.sendRequest !== "function") throw new Error("App-server bridge is unavailable");
    const threads = [];
    const cursors = new Set();
    let cursor = null;
    for (let page = 0; page < 200; page += 1) {
      const result = await requestClient.sendRequest("thread/list", {
        archived: archived === true,
        cursor,
        limit: 49,
        sortDirection: "desc",
        sortKey: "updated_at",
      });
      if (state.disposed) return { pages: page + 1, threads: [] };
      if (Array.isArray(result?.data)) threads.push(...result.data);
      const nextCursor = typeof result?.nextCursor === "string" && result.nextCursor ? result.nextCursor : null;
      if (!nextCursor) return { pages: page + 1, threads };
      if (cursors.has(nextCursor)) throw new Error("thread/list returned a repeated pagination cursor");
      cursors.add(nextCursor);
      cursor = nextCursor;
    }
    throw new Error("thread/list exceeded the bounded page limit");
  }

  async function listAllLocalThreads(archived = false) {
    const requestClient = state.localRuntime?.requestClient;
    if (typeof requestClient?.sendRequest !== "function") throw new Error("Local app-server bridge is unavailable");
    return (await listAllRuntimeThreads(requestClient, archived)).threads;
  }

  function eligibleAutoArchiveThreads(threads) {
    const cutoff = Date.now() - AUTO_ARCHIVE_DAYS * 24 * 60 * 60 * 1000;
    const parentsWithActiveChildren = new Set(threads
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
        && !parentsWithActiveChildren.has(threadId)
        && !protectedIds.has(threadId)
        && thread.isPinned !== true
        && thread.pinned !== true
        && statusType === "notLoaded"
        && Number.isFinite(activityAt)
        && activityAt < cutoff;
    });
  }

  function synchronizeTrackedArchivedThreads(archivedThreads) {
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
    if (changed) writeRecords(AUTO_ARCHIVED_RECORDS_KEY, records);
    return records;
  }

  function eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords, minimumArchivedAgeMs = AUTO_DELETE_AFTER_ARCHIVE_DAYS * 24 * 60 * 60 * 1000) {
    const cutoff = Date.now() - minimumArchivedAgeMs;
    const parentsWithKnownChildren = new Set([...activeThreads, ...archivedThreads]
      .map((thread) => typeof thread?.parentThreadId === "string" ? thread.parentThreadId : null)
      .filter(Boolean));
    return archivedThreads.filter((thread) => {
      const threadId = typeof thread?.id === "string" ? thread.id : null;
      const statusType = typeof thread?.status === "string" ? thread.status : thread?.status?.type;
      const archivedAt = Number(archiveRecords?.[threadId]);
      return Boolean(threadId)
        && !parentsWithKnownChildren.has(threadId)
        && thread.isPinned !== true
        && thread.pinned !== true
        && statusType === "notLoaded"
        && Number.isFinite(archivedAt)
        && archivedAt < cutoff;
    });
  }

  async function previewAutoArchive() {
    const [activeThreads, archivedThreads] = await Promise.all([
      listAllLocalThreads(false),
      listAllLocalThreads(true),
    ]);
    const archiveEligible = eligibleAutoArchiveThreads(activeThreads).length;
    const archiveRecords = readRecords(AUTO_ARCHIVED_RECORDS_KEY);
    const deleteEligible = eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords).length;
    return {
      archiveEligible,
      archivedScanned: archivedThreads.length,
      deleteEligible,
      untrackedArchived: archivedThreads.filter((thread) => typeof thread?.id === "string" && !Number.isFinite(Number(archiveRecords[thread.id]))).length,
      eligible: archiveEligible,
      scanned: activeThreads.length,
    };
  }

  async function runAutoArchiveNow() {
    if (state.autoArchivePending || state.disposed) return state.autoArchiveLastResult ?? { archived: 0, eligible: 0 };
    if (!readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) return { archived: 0, eligible: 0, skipped: "auto-archive-disabled" };
    const requestClient = state.localRuntime?.requestClient;
    if (typeof requestClient?.sendRequest !== "function") {
      state.autoArchiveError = "Local app-server bridge is unavailable";
      return { archived: 0, eligible: 0, error: state.autoArchiveError };
    }
    state.autoArchivePending = true;
    state.autoArchiveError = null;
    const archiveFailures = [];
    const deleteFailures = [];
    let archived = 0;
    let deleted = 0;
    try {
      const [activeThreads, archivedThreads] = await Promise.all([
        listAllLocalThreads(false),
        listAllLocalThreads(true),
      ]);
      const archiveRecords = synchronizeTrackedArchivedThreads(archivedThreads);
      const deleteCandidates = eligibleAutoDeleteThreads(archivedThreads, activeThreads, archiveRecords);
      for (const thread of deleteCandidates) {
        if (state.disposed || !readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) break;
        try {
          await requestClient.sendRequest("thread/delete", { threadId: thread.id });
          delete archiveRecords[thread.id];
          deleted += 1;
        } catch (error) {
          deleteFailures.push({ id: thread.id, error: String(error?.message ?? error).slice(0, 160) });
        }
      }
      const archiveCandidates = eligibleAutoArchiveThreads(activeThreads);
      for (const thread of archiveCandidates) {
        if (state.disposed || !readOptionalBoolean(AUTO_ARCHIVE_ENABLED_KEY)) break;
        try {
          await requestClient.sendRequest("thread/archive", { threadId: thread.id });
          archiveRecords[thread.id] = Date.now();
          archived += 1;
        } catch (error) {
          archiveFailures.push({ id: thread.id, error: String(error?.message ?? error).slice(0, 160) });
        }
      }
      writeRecords(AUTO_ARCHIVED_RECORDS_KEY, archiveRecords);
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
      };
      const failureCount = archiveFailures.length + deleteFailures.length;
      state.autoArchiveError = failureCount ? `${failureCount} eligible chat maintenance operation(s) failed` : null;
      state.lastAction = { commandId: "auto-maintain-old-chats", found: true, invoked: true, ...state.autoArchiveLastResult };
      void state.queryClient?.invalidateQueries?.();
      return state.autoArchiveLastResult;
    } catch (error) {
      state.autoArchiveError = String(error?.message ?? error).slice(0, 240);
      state.autoArchiveLastResult = { archived, deleted, eligible: 0, error: state.autoArchiveError };
      state.lastAction = { commandId: "auto-maintain-old-chats", error: state.autoArchiveError, found: true, invoked: false };
      return state.autoArchiveLastResult;
    } finally {
      state.autoArchivePending = false;
      if (!state.disposed) {
        scheduleAutoArchive(state.autoArchiveError ? AUTO_ARCHIVE_RETRY_MS : AUTO_ARCHIVE_INTERVAL_MS);
        schedule();
      }
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
      if (project.hostId === "local" || !project.projectId) return false;
      const inventory = authoritativeInventory(project.hostId);
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
      if (staleIds.size) {
        const remoteProjectsResult = await state.localFetchFromHost("get-global-state", { params: { key: "remote-projects" } });
        const remoteProjects = Array.isArray(remoteProjectsResult?.value) ? remoteProjectsResult.value : [];
        await setGlobalStateValue("remote-projects", remoteProjects.filter((project) => !staleIds.has(project?.id)));
        for (const key of ["project-order", "pinned-project-ids"]) {
          const result = await state.localFetchFromHost("get-global-state", { params: { key } });
          if (Array.isArray(result?.value)) await setGlobalStateValue(key, result.value.filter((id) => !staleIds.has(id)));
        }
        const selectedResult = await state.localFetchFromHost("get-global-state", { params: { key: "selected-project" } });
        if (selectedResult?.value?.type === "remote" && staleIds.has(selectedResult.value.projectId)) {
          await setGlobalStateValue("selected-project", null);
        }
        await state.queryClient?.invalidateQueries?.();
      }

      const managed = readRecords(AUTO_MANAGED_KEY);
      for (const [identity, record] of Object.entries(managed)) {
        const inventory = authoritativeInventory(normalizeHostId(record.hostId));
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
    if (!staleMirroredProjects(model).length) return;
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
    try {
      await registerRemoteProjectAndOpen(project, navigate);
      setRecord(AUTO_MANAGED_KEY, project, true);
      setRecord(AUTO_SUPPRESSED_KEY, project, false);
      state.autoRegistrationFailures.delete(identity);
      state.lastAction = { commandId: "auto-register-remote-project", found: true, hostId: project.hostId, invoked: true, project: project.name };
    } catch (error) {
      dismissAutoRegistrationDialog(remoteProjectDialog());
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
    let removed = 0;
    if (typeof state.localFetchFromHost === "function" && Object.keys(managed).length) {
      const result = await state.localFetchFromHost("get-global-state", { params: { key: "remote-projects" } });
      const remoteProjects = Array.isArray(result?.value) ? result.value : [];
      const removedIds = new Set();
      const kept = remoteProjects.filter((project) => {
        const candidate = { cwd: project?.remotePath, hostId: normalizeHostId(project?.hostId), name: project?.label };
        const remove = hasRecord(AUTO_MANAGED_KEY, candidate);
        if (remove && typeof project?.id === "string") removedIds.add(project.id);
        return !remove;
      });
      if (removedIds.size) {
        await setGlobalStateValue("remote-projects", kept);
        for (const key of ["project-order", "pinned-project-ids"]) {
          const current = await state.localFetchFromHost("get-global-state", { params: { key } });
          if (Array.isArray(current?.value)) await setGlobalStateValue(key, current.value.filter((id) => !removedIds.has(id)));
        }
        const selected = await state.localFetchFromHost("get-global-state", { params: { key: "selected-project" } });
        if (selected?.value?.type === "remote" && removedIds.has(selected.value.projectId)) await setGlobalStateValue("selected-project", null);
        await state.queryClient?.invalidateQueries?.();
        removed = removedIds.size;
      }
    } else {
      const projects = collectModel().projects.filter((project) => {
        return project.hostId !== "local" && project.projectId && hasRecord(AUTO_MANAGED_KEY, project);
      });
      for (const project of projects) {
        if (invokeNativeProjectCommand(project, "remove-project")) removed += 1;
        await new Promise((resolve) => setTimeout(resolve, 250));
      }
    }
    for (const record of Object.values(managed)) {
      const placeholder = { cwd: record.cwd, hostId: record.hostId, name: record.name };
      setRecord(AUTO_SUPPRESSED_KEY, placeholder, true);
    }
    writeRecords(AUTO_MANAGED_KEY, {});
    state.lastAction = { commandId: "remove-all-auto-registered", found: true, invoked: true, removed };
    render();
    return { removed };
  }

  async function startNativeProjectThread(project) {
    if (state.pendingNewThreads.has(project.key)) return;
    const nativeAction = nativeProjectNewAction(project);
    if (nativeAction) {
      invokeNativeElement(nativeAction);
      state.lastAction = { commandId: "start-new-thread", found: true, hostId: project.hostId, invoked: true, mode: "native-project-button", project: project.name };
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
    try {
      if (localCallback) localCallback();
      else if (projectDispatcher) projectDispatcher({ projectId: project.projectId, projectKind: project.hostId === "local" ? "local" : "remote" });
      else if (globalNewChat) {
        invokeNativeElement(globalNewChat);
        await new Promise((resolve) => setTimeout(resolve, 0));
        await setGlobalStateValue("selected-project", { projectId: project.projectId, type: project.hostId === "local" ? "local" : "remote" });
        void state.queryClient?.invalidateQueries?.();
      }
      else await registerRemoteProjectAndOpen(project, navigationDispatcher);
      state.lastAction = { commandId: "start-new-thread", found: true, hostId: project.hostId, invoked: true, mode: globalNewChat && !localCallback && !projectDispatcher ? "global-composer-project-selection" : project.hostId !== "local" && !project.projectId ? "registered-remote-project" : "open-composer", project: project.name };
    } catch (error) {
      state.lastAction = { commandId: "start-new-thread", error: error?.message || String(error), found: true, hostId: project.hostId, invoked: false, project: project.name };
    } finally {
      state.pendingNewThreads.delete(project.key);
      schedule();
    }
  }

  function projectCard(project) {
    const hasNativeActions = Boolean(nativeProjectAction(project));
    const card = document.createElement("div");
    card.id = CARD_ID;
    card.className = "crmp-project-card";
    isolateOverlay(card);
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
    pin.setAttribute("aria-label", `Pin or unpin ${project.name}`);
    pin.title = "Pin or unpin project";
    pin.disabled = !hasNativeActions;
    bindActivation(pin, () => invokeNativeProjectCommand(project, "pin-project"));
    head.append(icon, label, spacer, pin);
    card.appendChild(head);

    const count = document.createElement("div");
    count.className = "crmp-project-card-row";
    count.innerHTML = `<span class="crmp-project-card-icon">◯</span><span>${project.tasks.length} ${project.tasks.length === 1 ? "task" : "tasks"}</span>`;
    card.append(count, divider());

    const path = button("crmp-project-card-row crmp-project-card-path", "");
    path.title = "Open in Explorer";
    path.disabled = !hasNativeActions;
    path.innerHTML = '<span class="crmp-project-card-icon">▱</span>';
    const pathText = document.createElement("span");
    pathText.textContent = project.cwd || "Project folder unavailable";
    path.appendChild(pathText);
    bindActivation(path, () => invokeNativeProjectCommand(project, "reveal-project-folder"));
    card.append(path, divider());

    const edit = button("crmp-project-card-row", "");
    edit.innerHTML = '<span class="crmp-project-card-icon">⚙</span><span>Edit project</span>';
    edit.disabled = !hasNativeActions;
    if (!hasNativeActions) edit.title = "Remote project editing is not exposed by the native desktop sidebar";
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
    isolateOverlay(menu);
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
      item.setAttribute("role", "menuitem");
      item.innerHTML = `<span aria-hidden="true">${icon}</span><span>${label}</span>`;
      const custom = id === "allow-auto-registration";
      const command = commands.get(id);
      item.disabled = !custom && (!command || command.enabled === false);
      if (item.disabled) item.title = "This command is not exposed for this remote project";
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

  function appendGroup(fragment, project) {
    const section = document.createElement("section");
    section.className = "crmp-project";
    section.dataset.hostId = project.hostId;
    section.dataset.projectKey = project.key;
    const head = document.createElement("div");
    const nativeHeadClass = nativeProjectRowTemplate(project)?.className;
    head.className = `${nativeHeadClass || "sidebar-item group relative"} crmp-project-head`;
    head.dataset.actionsOpen = String(state.actionCardKey === project.key || state.contextProjectKey === project.key);
    const toggle = button("crmp-project-toggle", "");
    toggle.title = project.cwd || project.name;
    toggle.setAttribute("aria-expanded", String(!state.collapsed.has(project.key)));
    const folder = document.createElement("span");
    folder.className = "crmp-folder";
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
      if (state.collapsed.has(project.key)) state.collapsed.delete(project.key); else state.collapsed.add(project.key);
      render();
    });
    bindReorder(toggle, head, reorderReference("project", project));
    head.addEventListener("contextmenu", (event) => {
      if (project.kind !== "project") return;
      event.preventDefault();
      event.stopPropagation();
      state.actionCardKey = null;
      state.contextProjectKey = project.key;
      state.contextPoint = { x: event.clientX, y: event.clientY };
      render();
    });
    head.appendChild(toggle);
    if (project.kind === "project") {
      const create = cloneNativeButton(nativeProjectButtonTemplate(project, "new"), "crmp-project-new", "✎");
      create.setAttribute("aria-label", `Start new chat in ${project.name}`);
      create.title = `Start new chat in ${project.name}`;
      const exactNativeNewAction = nativeProjectNewAction(project);
      create.disabled = state.pendingNewThreads.has(project.key) || (!exactNativeNewAction && (project.hostId === "local"
        ? !nativeProjectCallback(project, "onStartNewThread") && !(project.projectId && (nativeStartThreadDispatcher() || (typeof state.localFetchFromHost === "function" && nativeGlobalNewChatAction())))
        : !project.cwd || !(project.projectId ? nativeStartThreadDispatcher() || (typeof state.localFetchFromHost === "function" && nativeGlobalNewChatAction()) : nativeNavigationDispatcher())));
      bindActivation(create, () => startNativeProjectThread(project));
      head.appendChild(create);
      const actions = cloneNativeButton(nativeProjectButtonTemplate(project, "actions"), "crmp-project-action", "⋯");
      actions.setAttribute("aria-label", `Open project details for ${project.name}`);
      actions.setAttribute("aria-expanded", String(state.actionCardKey === project.key));
      actions.title = "Project details and settings";
      bindActivation(actions, () => {
        state.actionCardKey = state.actionCardKey === project.key ? null : project.key;
        render();
      });
      head.appendChild(actions);
    }
    section.appendChild(head);
    if (!state.collapsed.has(project.key)) {
      const tasks = document.createElement("div");
      tasks.className = "crmp-tasks";
      for (const task of project.tasks) {
        const taskRow = document.createElement("div");
        taskRow.className = "crmp-task-row group";
        const taskButton = button(`${task.originalRow?.className || ""} crmp-task`, task.title);
        const working = task.statusType === "loading";
        const stateLabel = working ? "working" : task.unread ? "completed, unread" : null;
        if (stateLabel) taskButton.setAttribute("aria-label", `${task.title}, ${stateLabel}`);
        taskButton.title = `${task.title}\n${task.cwd || project.cwd || "No project folder"}\n${project.hostName}`;
        taskButton.dataset.appActionSidebarThreadSelected = String(task.selected);
        if (task.selected) taskButton.setAttribute("aria-current", "page");
        taskButton.addEventListener("click", () => {
          if (performance.now() - state.dragJustEndedAt >= 250) {
            if (task.unread && task.hostId !== "local") acknowledgeRemoteUnread(task);
            void openNativeTask(task);
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
        if (statusIndicator) taskRow.appendChild(statusIndicator);
        const taskActions = document.createElement("div");
        const railTemplate = nativeThreadAction(task, "pin")?.closest('div[class*="absolute"][class*="end-0"]')
          ?? nativeThreadAction(task, "archive")?.closest('div[class*="absolute"][class*="end-0"]');
        taskActions.className = `${railTemplate?.className || ""} crmp-task-actions`;
        for (const actionName of ["pin", "archive"]) {
          const nativeAction = nativeThreadAction(task, actionName);
          if (!nativeAction) continue;
          const actionLabel = nativeAction.getAttribute("aria-label") || (actionName === "pin" ? "Pin chat" : "Archive chat");
          const actionButton = cloneNativeButton(nativeAction, "crmp-task-action", actionName === "pin" ? "⌖" : "▣");
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

  function render() {
    state.scheduledFrame = null;
    document.getElementById(CARD_ID)?.remove();
    document.getElementById(CONTEXT_ID)?.remove();
    if (!state.active) return probe();
    const model = collectModel();
    const nextNative = commonAncestor(model.rows.length ? model.rows : model.nativeProjectItems);
    if (!nextNative) return probe();

    if (state.nativeContainer !== nextNative) {
      if (state.nativeContainer?.isConnected) state.nativeContainer.style.display = state.originalDisplay;
      state.nativeContainer = nextNative;
      state.originalDisplay = nextNative.style.display;
      nextNative.parentElement?.insertBefore(state.panel, nextNative);
    }

    const fragment = document.createDocumentFragment();
    const modes = document.createElement("div");
    modes.className = "crmp-modes";
    for (const [id, label] of [["mobile", "Mobile projects"], ["native", "Native views"]]) {
      const mode = button("crmp-mode", label);
      mode.setAttribute("aria-pressed", String(state.view === id));
      mode.addEventListener("click", () => setView(id));
      modes.appendChild(mode);
    }
    fragment.appendChild(modes);

    scheduleLocalProjectInventoryPublication();
    scheduleLocalPeerCacheInventory(model.hosts);
    scheduleLocalRegisteredProjectsRefresh();
    scheduleRemoteProjectInventory(model.remoteRuntimes);
    scheduleAutoRegistration(model);
    scheduleAutoArchive();
    scheduleNativeInventoryHydration();

    if (state.view === "native") {
      state.nativeContainer.style.display = state.originalDisplay;
      state.panel.replaceChildren(fragment);
      return probe();
    }
    state.nativeContainer.style.setProperty("display", "none", "important");

    if (state.filter !== "all" && !model.hosts.some((host) => host.id === state.filter)) state.filter = "all";
    const filters = document.createElement("div");
    filters.className = "crmp-filters";
    filters.setAttribute("aria-label", "Filter tasks by device");
    const filterItems = [{ id: "all", name: "All" }, ...model.hosts];
    for (const host of filterItems) {
      const chip = button("crmp-chip", host.name);
      chip.setAttribute("aria-pressed", String(state.filter === host.id));
      if (host.id !== "all") {
        const dot = document.createElement("span");
        dot.className = `crmp-dot${host.available === false ? " crmp-dot-unavailable" : ""}`;
        chip.prepend(dot);
      }
      chip.addEventListener("click", () => { state.filter = host.id; render(); });
      filters.appendChild(chip);
    }

    fragment.appendChild(filters);
    const autoControls = document.createElement("div");
    autoControls.className = "crmp-auto-controls";
    const autoEnabled = readBoolean(AUTO_ENABLED_KEY);
    const autoToggle = button("crmp-auto-control", autoEnabled ? "Auto-register: on" : "Auto-register: off");
    autoToggle.setAttribute("aria-pressed", String(autoEnabled));
    autoToggle.title = "Mirror active projects published by connected injected devices";
    autoToggle.addEventListener("click", () => setAutoRegistration(!autoEnabled));
    autoControls.appendChild(autoToggle);
    const managedCount = Object.keys(readRecords(AUTO_MANAGED_KEY)).length;
    const removeManaged = button("crmp-auto-control", `Remove auto projects (${managedCount})`);
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
    fragment.appendChild(autoControls);
    const unavailableInventoryHosts = model.hosts.filter((host) => host.id !== "local" && state.remoteProjectInventories.get(host.id)?.error);
    if (unavailableInventoryHosts.length) {
      const status = document.createElement("div");
      status.className = "crmp-inventory-status";
      status.textContent = `Project sync paused: waiting for a current v46 inventory from ${unavailableInventoryHosts.map((host) => host.name).join(", ")}.`;
      fragment.appendChild(status);
    }
    const panelTitle = document.createElement("div");
    panelTitle.className = "crmp-title";
    panelTitle.textContent = "Projects";
    fragment.appendChild(panelTitle);
    const visibleProjects = model.projects.filter((project) => state.filter === "all" || project.hostId === state.filter);
    const visibleRecents = model.recents.filter((project) => state.filter === "all" || project.hostId === state.filter);
    for (const project of visibleProjects) appendGroup(fragment, project);
    if (visibleRecents.length) {
      const recentsTitle = document.createElement("div");
      recentsTitle.className = "crmp-title";
      recentsTitle.textContent = "Recents";
      fragment.appendChild(recentsTitle);
      for (const recent of visibleRecents) appendGroup(fragment, recent);
    }
    if (!visibleProjects.length && !visibleRecents.length) {
      const empty = document.createElement("div");
      empty.className = "crmp-empty";
      empty.textContent = "No loaded tasks for this device.";
      fragment.appendChild(empty);
    }
    state.panel.replaceChildren(fragment);
    const cardProject = [...visibleProjects, ...visibleRecents].find((project) => project.key === state.actionCardKey);
    if (cardProject?.kind === "project") document.body.appendChild(projectCard(cardProject));
    const contextProject = visibleProjects.find((project) => project.key === state.contextProjectKey);
    if (contextProject) document.body.appendChild(projectContextMenu(contextProject));
    positionProjectCard();
    positionProjectContextMenu();
    return probe();
  }

  function schedule(mutations) {
    if (state.disposed) return;
    if (mutations?.length && mutations.every((mutation) => state.panel?.contains(mutation.target))) return;
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
    state.actionCardKey = null;
    state.contextProjectKey = null;
    state.contextPoint = null;
    render();
  }

  function probe() {
    const model = collectModel();
    const expansionControls = nativeThreadListExpansionControls();
    const tasksByHost = Object.fromEntries(model.hosts.map((host) => [host.name, model.tasks.filter((task) => task.hostId === host.id).length]));
    const authoritativeThreadsByHost = Object.fromEntries([...state.threadInventories].map(([hostId, inventory]) => [hostId, inventory.threads?.length ?? 0]));
    const remoteThreadInventories = Object.fromEntries([...state.remoteProjectInventories].map(([hostId, inventory]) => [hostId, {
      error: inventory.error ?? null,
      pending: inventory.pending === true,
      sourcePeerHostId: inventory.sourcePeerHostId ?? null,
      sourcePeerCache: inventory.sourcePeerCache === true,
      threads: inventory.threads?.length ?? 0,
      threadsAuthoritative: inventory.threadsAuthoritative === true,
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
      localInventoryPublished: state.localInventoryPublishedAt > 0,
      localInventoryProjects: state.localInventoryProjects.length,
      localInventoryPublisherError: state.localInventoryPublisherError,
      localInventoryPublisherPending: state.localInventoryPublisherPending,
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
    state.active = true;
    state.disposed = false;
    document.addEventListener("pointerdown", dismissOverlays);
    document.addEventListener("keydown", dismissOnEscape);
    if (!state.observer) {
      state.observer = new MutationObserver(schedule);
      state.observer.observe(document.body, {
        attributeFilter: ["data-app-action-sidebar-thread-selected", "data-app-action-sidebar-thread-title"],
        attributes: true,
        childList: true,
        subtree: true,
      });
    }
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
    document.removeEventListener("pointerdown", dismissOverlays);
    document.removeEventListener("keydown", dismissOnEscape);
    state.observer?.disconnect();
    state.observer = null;
    if (state.scheduledFrame !== null) cancelAnimationFrame(state.scheduledFrame);
    state.scheduledFrame = null;
    if (state.autoRegistrationTimer !== null) clearTimeout(state.autoRegistrationTimer);
    state.autoRegistrationTimer = null;
    if (state.autoReconciliationTimer !== null) clearTimeout(state.autoReconciliationTimer);
    state.autoReconciliationTimer = null;
    if (state.autoArchiveTimer !== null) clearTimeout(state.autoArchiveTimer);
    state.autoArchiveTimer = null;
    if (state.localInventoryPublisherTimer !== null) clearTimeout(state.localInventoryPublisherTimer);
    state.localInventoryPublisherTimer = null;
    if (state.inventoryHydrationTimer !== null) clearTimeout(state.inventoryHydrationTimer);
    state.inventoryHydrationTimer = null;
    if (state.nativeContainer?.isConnected) state.nativeContainer.style.display = state.originalDisplay;
    state.nativeContainer = null;
    state.panel?.remove();
    document.getElementById(CARD_ID)?.remove();
    document.getElementById(CONTEXT_ID)?.remove();
    document.getElementById(STYLE_ID)?.remove();
    state.active = false;
    return probe();
  }

  const api = Object.freeze({ install, previewAutoArchive, previewAutoMaintenance: previewAutoArchive, probe, reconcileAutoRegisteredProjects, removeAllAutoRegistered, runAutoArchiveNow, runAutoMaintenanceNow: runAutoArchiveNow, setAutoArchive, setAutoMaintenance: setAutoArchive, setAutoRegistration, setFilter, setView, uninstall, version: VERSION });
  Object.defineProperty(globalThis, API_SLOT, { configurable: true, enumerable: false, value: api });
  return install();
})();
