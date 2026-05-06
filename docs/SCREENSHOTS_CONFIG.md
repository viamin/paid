# Screenshot Configuration

Paid reads screenshot capture settings from `.paid/screenshots.yml` in the target repository.

## Schema

```yaml
driver: playwright          # optional: playwright | cuprite
base_url: http://localhost:3000
viewport:
  width: 1280
  height: 900

routes:                     # required, non-empty
  - path: /
    name: homepage
  - path: /dashboard
    name: dashboard
    requires_auth: true
  - path: /projects/:project_id
    name: project_show
    requires_auth: true
    seed_key: project

auth:                       # optional
  strategy: form            # none | form | token | custom
  login_path: /login
  fields:
    email: input[name="email"]
    password: input[name="password"]
    submit: button[type="submit"]
  credentials:
    email: admin@example.com
    password: password123

seed:                       # optional
  - model: User
    factory: admin
    key: user
  - model: Project
    factory: project
    key: project
    owner: user

setup:                      # optional
  - bin/rails db:prepare
  - bin/rails db:seed

services:                   # optional
  - postgres
  - redis

ui_patterns:                # optional
  - app/views/**/*
  - app/javascript/**/*
  - app/assets/stylesheets/**/*
  - app/components/**/*

ui_exclusions:              # optional
  - app/views/layouts/mailer/**/*
  - app/views/pwa/**/*
```

## Defaults

- `driver`: `playwright`
- `base_url`: `http://localhost:3000`
- `viewport.width`: `1280`
- `viewport.height`: `900`
- `auth.strategy`: `none`
- `seed`, `setup`, `services`: empty arrays
- `ui_patterns`: `app/views/**/*`, `app/javascript/**/*`, `app/assets/stylesheets/**/*`, `app/components/**/*`
- `ui_exclusions`: `app/views/layouts/mailer/**/*`, `app/views/pwa/**/*`

## Resolution Rules

Paid resolves screenshot configuration in this order:

1. Start with `Project.screenshot_settings` from the database.
2. Overlay `.paid/screenshots.yml` from the repository.
3. Re-apply database overrides for `enabled` and `driver`.

Repository config takes precedence for `routes`, `auth`, `seed`, and `setup`.
