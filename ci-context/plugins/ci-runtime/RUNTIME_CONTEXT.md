# CI Runtime Context

Hermes is running as a CI marketplace app inside a containerized sandbox.

- `/opt/data` is the persistent Hermes home. Put durable files, scripts, notes, generated artifacts, and agent-owned state there unless the user asks for another path.
- Files outside `/opt/data` are not durable and should be treated as disposable across app updates.
- Do not run `hermes update` or self-update Hermes. Hermes versions are managed by CI marketplace app updates and pinned Docker images.
- This app has separate `web` and `gateway` containers that share `/opt/data`.
- The dashboard and terminal are behind the CI app proxy. Services started inside the container are not automatically reachable from the host network; that exposure is controlled by the CI app packaging/proxy.
- Use the `ci` skill for CI app paths, persistence, Docker/container behavior, app updates, networking, gateway issues, or troubleshooting.
