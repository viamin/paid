# Migrating a Project from PAT to paid-agents GitHub App

This guide covers the exact steps to migrate a project currently using a Personal Access Token (PAT) to the `paid-agents` GitHub App. The app is already configured in Rails credentials.

## What changes after migration

- PRs and commits are authored by `paid-agents[bot]` instead of the PAT owner
- Credentials are short-lived installation tokens (1 hour, cached 50 min) instead of a long-lived PAT
- Rate limits become per-installation (5,000–12,500/hr) instead of per-user
- Branch protection rules like "require non-author review" work correctly because bot ≠ human
- Container agents continue to receive credentials through the secrets proxy (no agent changes needed)

## Prerequisites

### 1. Verify the paid-agents app is configured

The app credentials live in Rails encrypted credentials (`paid_agent_app_id`, `paid_agent_app_private_key`, `paid_agent_app_slug`). Verify in console:

```ruby
Github::AppRegistry.configured?  # => true
Github::AppRegistry.bot_login    # => "paid-agents[bot]"
Github::AppRegistry.install_url  # => "https://github.com/apps/paid-agents/installations/new"
```

If `configured?` returns `false`, the app ID or private key is missing from credentials.

### 2. Install the paid-agents GitHub App on the target org/account

The `paid-agents` app must be installed on the GitHub org or user account that owns the target repositories. This is done on GitHub's side:

1. Open the **Integrations** page (`/integrations`) in Paid
2. Click **"Install paid-agents"** — this opens `https://github.com/apps/paid-agents/installations/new` on GitHub
3. On GitHub, choose the org or user account to install on
4. Choose repository access:
   - **All repositories** — the app covers every repo in the org (simplest)
   - **Only select repositories** — pick only the repos you want to migrate (e.g., `paid`, `rad_org`)
5. Approve the permissions (Contents R/W, Pull requests R/W, Issues R/W, Metadata R, Checks R, Commit statuses R; Organization Members R)

After installation, GitHub assigns an **installation ID** (a numeric ID). You need this to create the `GithubInstallation` record in Paid.

### 3. Create the GithubInstallation record

Paid does not yet have a webhook handler that auto-creates `GithubInstallation` records when the app is installed. You need to create it manually via Rails console.

First, find the installation ID that GitHub assigned. You can get it from GitHub's app settings page (`github.com/settings/installations`), or query the GitHub API using the **app JWT**:

```ruby
jwt = Github::AppJwt.sign(
  app_id: Github::AppRegistry.app_id,
  private_key: Github::AppRegistry.private_key
)

response = Faraday.get(
  "https://api.github.com/app/installations",
  nil,
  "Authorization" => "Bearer #{jwt}",
  "Accept" => "application/vnd.github+json"
)

installations = JSON.parse(response.body)
# Find the one matching your org:
installations.each { |i| puts "#{i['id']} => #{i.dig('account', 'login')}" }
```

Then create the record. The steps differ depending on whether you chose **All repositories** or **Only select repositories** during the GitHub install. In both cases, you should populate `accessible_repositories` — the migration service and UI rely on it to verify which repos the installation can reach.

#### All repositories

When `repository_selection` is `"all"`, Paid's `covers_repository?` returns `true` for any repo under that org without consulting the `accessible_repositories` cache. However, the migration UI and service still need the repo list to verify access, so fetch it.

```ruby
account = Account.find(ACCOUNT_ID)
installation_id = GITHUB_INSTALLATION_ID

install_record = installations.find { |i| i["id"] == installation_id }

jwt = Github::AppJwt.sign(
  app_id: Github::AppRegistry.app_id,
  private_key: Github::AppRegistry.private_key
)

token_response = Faraday.post(
  "https://api.github.com/app/installations/#{installation_id}/access_tokens",
  "{}",
  "Authorization" => "Bearer #{jwt}",
  "Accept" => "application/vnd.github+json",
  "Content-Type" => "application/json"
)
installation_token = JSON.parse(token_response.body).fetch("token")

repos_response = Faraday.get(
  "https://api.github.com/installation/repositories",
  nil,
  "Authorization" => "Bearer #{installation_token}",
  "Accept" => "application/vnd.github+json"
)
accessible_repos = JSON.parse(repos_response.body)["repositories"].map { |r|
  {
    "id" => r["id"],
    "full_name" => r["full_name"],
    "name" => r["name"],
    "owner" => r.dig("owner", "login"),
    "default_branch" => r["default_branch"],
    "private" => r["private"]
  }
}

GithubInstallation.create!(
  account: account,
  github_installation_id: installation_id,
  account_login: install_record.dig("account", "login"),
  target_type: install_record.dig("account", "type") == "Organization" ? "Organization" : "User",
  repository_selection: install_record["repository_selection"],  # "all"
  accessible_repositories: accessible_repos
)
```

#### Only select repositories

When `repository_selection` is `"selected"`, Paid needs the repo list to determine which repos the installation covers. You must mint an installation token and fetch the repos.

```ruby
account = Account.find(ACCOUNT_ID)
installation_id = GITHUB_INSTALLATION_ID

install_record = installations.find { |i| i["id"] == installation_id }

jwt = Github::AppJwt.sign(
  app_id: Github::AppRegistry.app_id,
  private_key: Github::AppRegistry.private_key
)

# Mint an installation token — the app JWT alone is NOT sufficient for
# /installation/repositories.  You must exchange the JWT for a short-lived
# installation token first.
token_response = Faraday.post(
  "https://api.github.com/app/installations/#{installation_id}/access_tokens",
  "{}",
  "Authorization" => "Bearer #{jwt}",
  "Accept" => "application/vnd.github+json",
  "Content-Type" => "application/json"
)
installation_token = JSON.parse(token_response.body).fetch("token")

# Now use the installation token to list accessible repos
repos_response = Faraday.get(
  "https://api.github.com/installation/repositories",
  nil,
  "Authorization" => "Bearer #{installation_token}",
  "Accept" => "application/vnd.github+json"
)
repos_data = JSON.parse(repos_response.body)
accessible_repos = repos_data["repositories"].map { |r|
  {
    "id" => r["id"],
    "full_name" => r["full_name"],
    "name" => r["name"],
    "owner" => r.dig("owner", "login"),
    "default_branch" => r["default_branch"],
    "private" => r["private"]
  }
}

GithubInstallation.create!(
  account: account,
  github_installation_id: installation_id,
  account_login: install_record.dig("account", "login"),
  target_type: install_record.dig("account", "type") == "Organization" ? "Organization" : "User",
  repository_selection: install_record["repository_selection"],  # "selected"
  accessible_repositories: accessible_repos
)
```

### 4. Verify the installation covers the target repos

```ruby
installation = GithubInstallation.last

# Check the repos you want to migrate
installation.covers_repository?("viamin/paid")            # => true
installation.covers_repository?("rad_org/rad_org")   # => true

# Or list all covered repos
installation.accessible_repositories.map { |r| r["full_name"] }
```

If a repo returns `false` and `repository_selection` is `"selected"`, go to GitHub's app settings (`github.com/settings/installations`) and add the repo to the installation.

## Migration methods

Once the `GithubInstallation` record exists and covers the target repos, choose one of three migration methods:

### Option A: Per-project via the UI

Best for migrating one or two projects.

1. Navigate to **Projects → [project name] → Settings** (i.e., `/projects/:id/edit`)
2. Scroll to the **"GitHub Authentication"** fieldset
3. Select the **"Paid Agents App"** radio button
4. You should see a green banner: *"Paid Agents App detected — Installation #XXXXX covers this repository through YOUR_ORG"*
   - If you see an amber warning instead, the app isn't installed on that repo yet — go back to step 2 of the prerequisites
5. Click **Save**

The controller (`ProjectsController#assign_selected_github_credential`) will:

- Set `project.github_token = nil`
- Set `project.github_installation = <detected installation>`
- Invalidate cached GitHub data

Repeat for the second project.

### Option B: Bulk migration via the Installations page

Best when both projects use the same PAT and you want to migrate them together.

1. Navigate to **GitHub Apps** (`/github_installations`)
2. Click into the active installation
3. Click **"Migrate Projects"** (top-right)
4. This page shows all PAT-backed projects with access status (green check = accessible, amber = not accessible)
5. Select the source token from the dropdown
6. Click **Migrate** — this calls `Github::MigrationService.migrate_from_token`

This migrates **all** projects using that token. If the token is used by other projects you don't want to migrate yet, use Option A or C instead.

### Option C: Via Rails console

Best for scripting or when you need precise control.

```ruby
account = Account.find(ACCOUNT_ID)
installation = account.github_installations.active.first
actor = User.find(YOUR_USER_ID)

viamin = account.projects.find_by(full_name: "viamin/paid")
rad_org = account.projects.find_by(full_name: "rad_org/rad_org")

# Migrate individually
result1 = Github::MigrationService.migrate_project(
  project: viamin,
  github_installation: installation,
  actor: actor
)
puts "viamin: #{result1.success?} (#{result1.error || 'ok'})"

result2 = Github::MigrationService.migrate_project(
  project: rad_org,
  github_installation: installation,
  actor: actor
)
puts "rad_org: #{result2.success?} (#{result2.error || 'ok'})"

# Or bulk migrate all projects on the same token
token = viamin.github_token
result = Github::MigrationService.migrate_from_token(
  github_token: token,
  github_installation: installation,
  actor: actor
)
puts "Migrated #{result.successful}/#{result.total} projects"
result.each_failed { |r| puts "  FAILED: #{r.project.full_name} — #{r.error}" }
```

The migration service (`Github::MigrationService`) does the following within a transaction:

- Validates the installation is active and has access to the repo
- Sets `project.github_token = nil`, `project.github_installation = installation`
- Invalidates cached GitHub data
- Records an account activity event for the audit trail

## Post-migration verification

```ruby
[viamin, rad_org].each do |p|
  p.reload
  puts "#{p.full_name}:"
  puts "  github_installation_id = #{p.github_installation_id}"
  puts "  github_token_id = #{p.github_token_id.inspect}  (should be nil)"
  puts "  credential resolves: #{p.github_credential.present?}"
  puts "  client works: #{p.client&.repository_present?(p.full_name)}"
  puts "  author login: #{p.github_author_login}  (should be paid-agents[bot])"
end
```

Each project should show:

- `github_installation_id` = the installation's ID (not nil)
- `github_token_id` = nil
- `credential resolves` = true
- `client works` = true
- `author login` = `paid-agents[bot]`

## Rolling back

If you need to revert to PAT, edit the project settings and switch back to "Personal Access Token", or use the console:

```ruby
project = Project.find(PROJECT_ID)
token = GithubToken.find(TOKEN_ID)

project.update!(github_installation: nil, github_token: token)
```

The PAT path remains fully supported — it is not deprecated.

## Troubleshooting

**"GitHub App is not configured"** — The `paid_agent_app_id` or `paid_agent_app_private_key` is missing from Rails credentials. Check `Github::AppRegistry.configured?`.

**"Installation does not have access to repository"** — The app was installed with "Only select repositories" and the target repo was not included. Go to GitHub's app settings and add the repo.

**"GitHub App installation must be active"** — The `GithubInstallation` record has `suspended_at` or `revoked_at` set. Check `installation.active?` and `installation.suspended?`/`installation.revoked?`.

**"No active paid-agents installation detected"** on the project settings page — Either the `GithubInstallation` record doesn't exist yet (see step 3 of prerequisites), or it doesn't cover the project's repo. Check `installation.covers_repository?("org/repo")`.

**Amber warning on project settings page but installation exists** — The installation's `accessible_repositories` cache may be stale. Re-fetch and update it (note: you need an installation token, not the app JWT):

```ruby
installation = GithubInstallation.last
jwt = Github::AppJwt.sign(app_id: Github::AppRegistry.app_id, private_key: Github::AppRegistry.private_key)

# Mint an installation token first
token_res = Faraday.post(
  "https://api.github.com/app/installations/#{installation.github_installation_id}/access_tokens",
  "{}",
  "Authorization" => "Bearer #{jwt}",
  "Accept" => "application/vnd.github+json",
  "Content-Type" => "application/json"
)
installation_token = JSON.parse(token_res.body).fetch("token")

# Use the installation token to list repos
response = Faraday.get(
  "https://api.github.com/installation/repositories",
  nil,
  "Authorization" => "Bearer #{installation_token}",
  "Accept" => "application/vnd.github+json"
)
repos = JSON.parse(response.body)["repositories"].map { |r|
  { "id" => r["id"], "full_name" => r["full_name"], "name" => r["name"],
    "owner" => r.dig("owner", "login"), "default_branch" => r["default_branch"],
    "private" => r["private"] }
}
installation.update!(accessible_repositories: repos)
```
