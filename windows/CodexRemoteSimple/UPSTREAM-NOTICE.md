# Provenance and attribution

This repository documents and implements a Windows-oriented compatibility
workflow for `naipi11/Codex-Control-other-devices-Windows`. It combines the
public runtime technique credited below with read-only inspection of the locally
installed Codex Desktop package and Windows 11 testing recorded in
`VALIDATION.md`.

The root-cause identification and runtime technique were published in
hunterbeach's public Gist,
[`dc4b74bda0e045e33f308099182b4f80`](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80),
which identified the inverted Statsig gate and the missing Windows device-key
backend. That Gist states that its main-process approach was derived from
[`zdaar/codex-hacks`](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)
and that its renderer injection pattern was adapted from
[brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).

The runtime in this bundle was taken from
`naipi11/Codex-Control-other-devices-Windows` tag `v2.3.1`. The included
`UPSTREAM-LICENSE.txt` applies to that upstream work. The local renderer and
orchestrator now contain the documented, narrowly scoped second-gate extension
described in `UPSTREAM-COMPARISON.md`.

The local PowerShell wrapper, inventory, comparison, focused tests, and
non-persistent rollback workflow are additions to the upstream runtime. These
additions must not be confused with the upstream bug discovery or runtime
technique.

Referenced upstream works remain subject to their own rights and license terms.
No Codex executable, `app.asar`, OpenAI asset, or other file from the installed
application is redistributed.

OpenAI, ChatGPT, and Codex are trademarks of OpenAI. This project is unofficial
and is not endorsed by or affiliated with OpenAI.
