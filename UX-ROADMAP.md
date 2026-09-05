# Feature roadmap

Implemented in v1.5.36: compact main sidebar, utility controls behind Settings, native diagnostic Save As, local state-bridge recovery, and clearer cleanup/connection-refresh feedback.

Implemented in v1.5.34: device health with refresh/version evidence, cleanup preview/history, local device aliases, update details/history, and diagnostic export preview. See FEATURES.md for exact scope.

Implemented in v1.5.35: guided connection troubleshooting and a compatible inventory-transfer optimization pass (recipient echo removal, compact nullable fields, serialized latest-snapshot writes, and bounded retry). Live network speed measurements remain separate acceptance work.

Potential next features, in suggested order:

1. Search loaded project names and task titles, clearly indicating that unloaded content is not searched.
2. Working, Needs input, and Unread filters, plus saved views, without modifying native task state.
3. Opt-in completion/input notifications with per-device controls and deduplication.
4. Portable preferences export/import with a review step, excluding credentials, identities, and task content.
5. A user-triggered two-device transfer benchmark; consider a negotiated delta/compression protocol only after measuring the remaining bottleneck.

These are suggestions, not implemented capabilities or automatic commitments. Native macOS, real sign-in, full live-app update/relaunch, and assistive-technology acceptance remain separate validation work.
