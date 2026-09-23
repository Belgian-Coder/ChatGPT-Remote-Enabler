"use strict";

// A proxy changes the transport URL, not the target authenticated by the
// server's challenge. Only the exact launcher-owned bridge gets this mapping.
// The caller continues to validate token metadata and sign the original data.
module.exports = function matchesRemoteControlTarget(challenge, websocketUrl, environment = process.env) {
  try {
    let target = new URL(websocketUrl);
    if (websocketUrl === environment.CHATGPT_REMOTE_WS_URL) {
      if (target.protocol !== "ws:" || target.hostname !== "127.0.0.1" || !target.port ||
          target.username || target.password || target.search || target.hash ||
          !/^\/[a-f0-9]{32}\/backend-api\/codex\/remote\/control\/client$/u.test(target.pathname)) return false;
      target = new URL(environment.CRWU);
      if (target.protocol !== "wss:" || target.username || target.password || target.search || target.hash ||
          target.pathname !== "/backend-api/codex/remote/control/client") return false;
    }
    const protocol = target.protocol === "wss:" ? "https:" : target.protocol === "ws:" ? "http:" : null;
    return protocol !== null && challenge?.targetOrigin === `${protocol}//${target.host}` &&
      challenge.targetPath === target.pathname;
  } catch {
    return false;
  }
};
