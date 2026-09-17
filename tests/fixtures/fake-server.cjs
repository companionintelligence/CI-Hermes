"use strict";

// A stand-in for server.cjs in tests/hub-handout-restart.test.sh. The real server
// spawns each terminal session with hubEnv.applyHubBootstrapEnv(process.env, …); this
// does the same with the real hub-env.cjs, records what that session resolves, then
// waits for the backgrounded dashboard to record before letting the entrypoint end.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const appDir = process.env.CI_HERMES_APP_DIR;
const { applyHubBootstrapEnv } = require(path.join(appDir, "hub-env.cjs"));

const home = process.env.HERMES_HOME;
const env = applyHubBootstrapEnv(process.env, path.join(home, ".env.hub-bootstrap"));
const session = spawnSync("hermes", ["terminal"], { env, stdio: "inherit" });
if (session.status !== 0) process.exit(session.status || 1);

const dashboard = path.join(process.env.FAKE_HERMES_OUT, "dashboard.json");
const deadline = Date.now() + 15000;
(function waitForDashboard() {
  if (fs.existsSync(dashboard)) process.exit(0);
  if (Date.now() > deadline) {
    console.error("fake-server: the dashboard never recorded");
    process.exit(1);
  }
  setTimeout(waitForDashboard, 50);
})();
