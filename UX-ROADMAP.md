# Feature roadmap

Implemented in v1.5.54 / renderer v76: search loaded project names and chat
titles within device filters; temporary expansion of matching projects; concise
sync status with a Device health shortcut; and cleanup controls in a disclosure.
Search is local, debounced, and preserves saved expansion, input composition,
focus and drafts. Known remote projects no longer require the local project-state
bridge just to open; superseded or disposed task activations cannot navigate late.

Implemented in v1.5.50: quiet background discovery, Force refresh,
stale-sidebar recovery, and inline sync freshness. Published-package and actual
two-desktop acceptance remain separate from source and browser-fixture checks.

Implemented in v1.5.36: compact main sidebar, utility controls behind Settings, native diagnostic Save As, local state-bridge recovery, and clearer cleanup/connection-refresh feedback.

Implemented in v1.5.34: device health with refresh/version evidence, cleanup preview/history, local device aliases, update details/history, and diagnostic export preview. See FEATURES.md for exact scope.

Implemented in v1.5.35: guided connection troubleshooting and a compatible inventory-transfer optimization pass (recipient echo removal, compact nullable fields, serialized latest-snapshot writes, and bounded retry). Live network speed measurements remain separate acceptance work.

Potential next features, in suggested order:

1. Working, Needs input, and Unread filters, plus saved views, without modifying native task state.
2. Opt-in completion/input notifications with per-device controls and deduplication.
3. Portable preferences export/import with a review step, excluding credentials, identities, and task content.
4. A user-triggered two-device transfer benchmark; consider a negotiated delta/compression protocol only after measuring the remaining bottleneck.

These are suggestions, not implemented capabilities or automatic commitments. Native macOS, real sign-in, full live-app update/relaunch, and assistive-technology acceptance remain separate validation work.
