# Paid verification journeys

This guide is for an isolated Paid development or test checkout managed by
Paid. It reuses `.paid/screenshots.yml` for the authentication selectors and
route contract. `bin/paid-journey reset` creates only the narrow data slice
needed for this journey, rather than duplicating the screenshot gallery seed.
Do not use a production account, database, or credential.

## Project detail pilot

Use this journey when the changed surface affects sign-in, project navigation,
or project detail. Its maintenance check is:

```bash
bin/paid-journey check
```

From a clean isolated checkout:

```bash
bin/paid-journey setup
bin/paid-journey reset
bin/paid-journey credentials
```

Start the application directly with the Rails server, rather than the
repository's generic `bin/dev` preference: the agent's own execution
container ships the Ruby/Rails toolchain but not the `tmux`/Overmind
supervisor `bin/dev` requires, so `bin/dev` cannot start anything there.

```bash
mkdir -p tmp
(bundle exec bin/rails server -b 0.0.0.0 -p 3000) > tmp/paid-agent-verification-app.log 2>&1 &
echo $! > tmp/paid-agent-verification-app.pid
```

Using Playwright MCP, open `/users/sign_in`, submit the identity printed by
`bin/paid-journey credentials`, open `/projects`, then open **Paid Journey
Project**. Inspect that the project detail page renders the project name. Use
the route and form selectors from `.paid/screenshots.yml`; do not substitute
an unseeded account or manually infer credentials.

Record the actual navigation steps, observed project-detail result, and any
relevant screenshot, trace, and application-log paths in
`tmp/paid-agent-verification.json`. Include setup time, journey run time,
failure mode (or `none`), and operator effort in `details`. A screenshot or
agent claim is not sufficient proof of the journey. If setup, authentication,
the browser, or the assertion fails, record `failed`, `skipped`, or `not_run`
with the reason; never report the journey as passed.

When finished, stop the app using the PID file if it was created, then remove
the isolated seed data:

```bash
test ! -f tmp/paid-agent-verification-app.pid || kill "$(cat tmp/paid-agent-verification-app.pid)"
bin/paid-journey cleanup
```
