# RDR-012: GitHub Integration Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: GitHub client tests, polling workflow tests

## Problem Statement

Paid needs to integrate with GitHub to:

1. **Detect work**: Find issues labeled for agent processing
2. **Track progress**: Update issues with agent status
3. **Create PRs**: Submit agent-generated code for review
4. **Organize work**: Use GitHub Projects for feature decomposition
5. **Collect feedback**: Detect PR comments, merges, closes

Key decisions:
- Polling vs. webhooks for event detection
- PAT vs. GitHub App for authentication
- How to handle rate limiting
- Graceful degradation when features unavailable

## Context

### Background

Paid is inspired by aidp's "watch mode" which polls GitHub for labeled issues. The web UI adds complexity: users manage projects and view status in Paid, not just terminal.

Initial deployment is self-hosted, which affects webhook viability (requires public endpoint).

### Technical Environment

- Self-hosted deployment (initially)
- Multiple repositories per account
- Temporal workflows for durable operations
- PostgreSQL for caching issue state

## Research Findings

### Investigation Process

1. Compared polling vs. webhooks
2. Evaluated PAT vs. GitHub App authentication
3. Analyzed rate limiting strategies
4. Tested GitHub Projects V2 API
5. Designed graceful degradation patterns

### Key Discoveries

**Polling vs. Webhooks:**

| Aspect | Polling | Webhooks |
|--------|---------|----------|
| Latency | Seconds-minutes | Real-time |
| Setup | Simple | Requires public endpoint |
| Reliability | Very reliable | Can miss events |
| Rate limits | Consumes API quota | Minimal API usage |
| Self-hosted | Works anywhere | Needs ingress |

For Phase 1 (self-hosted), **polling is simpler and more reliable**.

**GitHub API Rate Limits:**

| Limit Type | Rate | Period |
|------------|------|--------|
| Core API | 5,000 | per hour |
| Search API | 30 | per minute |
| GraphQL | 5,000 points | per hour |

Polling strategies:
- Use conditional requests (If-Modified-Since, ETag)
- Cache issue data locally
- Exponential backoff on rate limit
- Spread polling across repositories

**PAT vs. GitHub App:**

| Aspect | PAT | GitHub App |
|--------|-----|------------|
| Setup | User creates token | Install app on repos |
| Permissions | User's permissions | Fine-grained per install |
| Rate limits | User's quota | Higher limits |
| Multi-tenant | One per user | One app, many installs |

For Phase 1, **PAT is simpler**. Users can create fine-grained PATs with specific scopes.

**Required PAT Scopes:**

```
repo              - Full repository access
project           - GitHub Projects V2 (if used)
read:org          - Organization membership
```

**GitHub Projects V2 API (GraphQL):**

```graphql
# Create project item
mutation {
  addProjectV2ItemById(input: {
    projectId: "PVT_...",
    contentId: "I_..."  # Issue node ID
  }) {
    item { id }
  }
}

# Update item field
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "PVT_...",
    itemId: "PVTI_...",
    fieldId: "PVTF_...",
    value: { singleSelectOptionId: "..." }
  }) {
    projectV2Item { id }
  }
}
```

**Graceful Degradation:**

If GitHub Projects unavailable:
- Track sub-issues via parent issue references
- Use issue labels for status instead of project columns
- Link issues in descriptions

## Proposed Solution

### Approach

Implement **PAT-based polling** with:

1. **Temporal polling workflow**: Durable, long-running poll loop
2. **Local caching**: Cache issue state in PostgreSQL
3. **Conditional requests**: Use ETags to reduce API usage
4. **Exponential backoff**: Handle rate limits gracefully
5. **GitHub Projects V2**: Use when available, degrade gracefully

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      GITHUB INTEGRATION ARCHITECTURE                         │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         POLLING WORKFLOW                                 ││
│  │                                                                          ││
│  │  GitHubPollWorkflow (Temporal - runs continuously per project)          ││
│  │                                                                          ││
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                   ││
│  │  │ Fetch issues│──►│ Compare to  │──►│ Trigger     │                   ││
│  │  │ with labels │   │ cached state│   │ workflows   │                   ││
│  │  └─────────────┘   └─────────────┘   └─────────────┘                   ││
│  │         │                 │                 │                           ││
│  │         ▼                 ▼                 ▼                           ││
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                   ││
│  │  │ Rate limit  │   │ Update      │   │ Planning/   │                   ││
│  │  │ handling    │   │ cache       │   │ Execution   │                   ││
│  │  │ & backoff   │   │             │   │ workflows   │                   ││
│  │  └─────────────┘   └─────────────┘   └─────────────┘                   ││
│  │                                                                          ││
│  │  Sleep(poll_interval) ──► Loop                                          ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         GITHUB CLIENT                                    ││
│  │                                                                          ││
│  │  ┌───────────────────────────────────────────────────────────────────┐  ││
│  │  │ Octokit (REST)                                                     │  ││
│  │  │                                                                    │  ││
│  │  │ • Issues: list, create, update, comments                          │  ││
│  │  │ • Pull Requests: create, update                                   │  ││
│  │  │ • Labels: add, remove                                             │  ││
│  │  │ • Webhooks: (future)                                              │  ││
│  │  └───────────────────────────────────────────────────────────────────┘  ││
│  │                                                                          ││
│  │  ┌───────────────────────────────────────────────────────────────────┐  ││
│  │  │ GraphQL (Projects V2)                                              │  ││
│  │  │                                                                    │  ││
│  │  │ • Projects: list items, add items, update fields                  │  ││
│  │  │ • Issue node IDs: for project item linking                        │  ││
│  │  └───────────────────────────────────────────────────────────────────┘  ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         LOCAL CACHE (PostgreSQL)                         ││
│  │                                                                          ││
│  │  issues table:                                                          ││
│  │  • github_issue_id, github_number                                       ││
│  │  • title, body, state, labels (cached)                                  ││
│  │  • paid_state (new, planning, in_progress, etc.)                        ││
│  │  • etag (for conditional requests)                                      ││
│  │  • last_synced_at                                                       ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         RATE LIMIT HANDLING                              ││
│  │                                                                          ││
│  │  Rate limit response (403 or X-RateLimit-Remaining: 0):                 ││
│  │  1. Check X-RateLimit-Reset header                                      ││
│  │  2. Wait until reset time (or minimum backoff)                          ││
│  │  3. Use exponential backoff for repeated limits                         ││
│  │  4. Log warning for visibility                                          ││
│  │                                                                          ││
│  │  Conditional requests:                                                  ││
│  │  • Store ETag from response                                             ││
│  │  • Send If-None-Match on next request                                   ││
│  │  • 304 Not Modified doesn't count against limit                         ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Polling over webhooks**: Works in self-hosted without public endpoint
2. **PAT over GitHub App**: Simpler for Phase 1, users control permissions
3. **Temporal workflow**: Durable polling survives restarts
4. **Local caching**: Reduces API calls, enables faster UI
5. **Graceful degradation**: Works without Projects V2

### Implementation Example

```ruby
# app/services/github_service.rb
class GitHubService
  include Servo::Service

  class FetchLabeledIssues
    include Servo::Service

    input do
      attribute :project, Dry::Types["any"]
      attribute :labels, Dry::Types["array"].of(Dry::Types["string"])
    end

    output do
      attribute :issues, Dry::Types["array"]
      attribute :rate_limit_remaining, Dry::Types["integer"]
    end

    def call
      client = project.github_token.octokit_client

      # Build query with labels
      query = labels.map { |l| "label:#{l}" }.join(" ")

      issues = with_rate_limit_handling do
        client.search_issues(
          "repo:#{project.github_full_name} is:issue is:open #{query}",
          per_page: 100,
          headers: conditional_headers
        )
      end

      # Update cache
      issues.items.each { |issue| update_cache(issue) }

      success(
        issues: issues.items,
        rate_limit_remaining: client.rate_limit.remaining
      )
    rescue Octokit::RateLimitExceeded => e
      failure(error: "Rate limit exceeded", reset_at: e.response_headers["X-RateLimit-Reset"])
    rescue Octokit::Error => e
      failure(error: e.message)
    end

    private

    def conditional_headers
      cached = IssueCache.find_by(project_id: project.id)
      return {} unless cached&.etag

      { "If-None-Match" => cached.etag }
    end

    def update_cache(github_issue)
      Issue.find_or_initialize_by(
        project_id: project.id,
        github_issue_id: github_issue.id
      ).update!(
        github_number: github_issue.number,
        title: github_issue.title,
        body: github_issue.body,
        state: github_issue.state,
        labels: github_issue.labels.map(&:to_h),
        github_updated_at: github_issue.updated_at
      )
    end

    def with_rate_limit_handling(&block)
      block.call
    rescue Octokit::TooManyRequests => e
      reset_time = e.response_headers["X-RateLimit-Reset"].to_i
      wait_seconds = [reset_time - Time.current.to_i, 60].max
      Rails.logger.warn("GitHub rate limit hit, waiting #{wait_seconds}s")
      sleep(wait_seconds)
      retry
    end
  end

  class CreatePullRequest
    include Servo::Service

    input do
      attribute :project, Dry::Types["any"]
      attribute :branch_name, Dry::Types["strict.string"]
      attribute :title, Dry::Types["strict.string"]
      attribute :body, Dry::Types["strict.string"]
      attribute :issue_number, Dry::Types["integer"].optional
    end

    output do
      attribute :pr_number, Dry::Types["integer"]
      attribute :pr_url, Dry::Types["strict.string"]
    end

    def call
      client = project.github_token.octokit_client

      pr = client.create_pull_request(
        project.github_full_name,
        project.github_default_branch,
        branch_name,
        title,
        body
      )

      # Add labels
      client.add_labels_to_an_issue(
        project.github_full_name,
        pr.number,
        ["ai-generated", "needs-review"]
      )

      # Link to issue if provided
      if issue_number
        client.add_comment(
          project.github_full_name,
          issue_number,
          "PR created: ##{pr.number}"
        )
      end

      success(pr_number: pr.number, pr_url: pr.html_url)
    rescue Octokit::Error => e
      failure(error: e.message)
    end
  end

  class AddToProject
    include Servo::Service

    input do
      attribute :project, Dry::Types["any"]
      attribute :issue_node_id, Dry::Types["strict.string"]
    end

    def call
      return success if project.github_project_id.blank?

      client = project.github_token.graphql_client

      result = client.query(AddProjectItemMutation, variables: {
        projectId: project.github_project_id,
        contentId: issue_node_id
      })

      if result.errors.any?
        # Log but don't fail - Projects is optional
        Rails.logger.warn("Failed to add to project: #{result.errors.messages}")
      end

      success
    rescue => e
      # Graceful degradation - don't fail the workflow
      Rails.logger.warn("GitHub Projects error: #{e.message}")
      success
    end
  end
end

# app/workflows/github_poll_workflow.rb
class GitHubPollWorkflow
  include Temporalio::Workflow

  def execute(project_id)
    project = activity.fetch_project(project_id)

    loop do
      # Check if project is still active
      break if activity.project_deactivated?(project_id)

      # Fetch labeled issues
      result = activity.fetch_labeled_issues(
        project_id: project_id,
        labels: project.trigger_labels
      )

      if result[:error]
        # Rate limited - wait longer
        if result[:reset_at]
          wait_until = Time.at(result[:reset_at]) - Time.current
          workflow.sleep([wait_until, 60].max)
          next
        end
        # Other error - log and continue
        activity.log_poll_error(project_id, result[:error])
      else
        # Process new/changed issues
        result[:issues].each do |issue|
          handle_issue(project, issue)
        end
      end

      # Sleep until next poll
      workflow.sleep(project.poll_interval_seconds)
    end
  end

  private

  def handle_issue(project, github_issue)
    issue = activity.get_or_create_issue(project.id, github_issue)

    # Determine action based on labels
    labels = github_issue[:labels].map { |l| l[:name] }
    trigger_label = labels.find { |l| project.trigger_labels.include?(l) }

    return unless trigger_label
    return if issue.already_processing?

    case trigger_label
    when project.labels["plan"]
      workflow.start_child(PlanningWorkflow, issue_id: issue.id)
    when project.labels["build"]
      workflow.start_child(AgentExecutionWorkflow, issue_id: issue.id)
    end

    activity.mark_issue_processing(issue.id)
  end
end

# app/models/github_token.rb
class GithubToken < ApplicationRecord
  encrypts :token

  belongs_to :account
  belongs_to :created_by, class_name: "User", optional: true

  def octokit_client
    @octokit_client ||= Octokit::Client.new(access_token: token)
  end

  def graphql_client
    @graphql_client ||= Octokit::Client.new(access_token: token)
  end
end
```

## Alternatives Considered

### Alternative 1: Webhooks Primary

**Description**: Use GitHub webhooks as primary event source

**Pros**:
- Real-time updates
- Lower API usage
- Industry standard

**Cons**:
- Requires public endpoint
- Can miss events if endpoint down
- More complex setup
- Security considerations (signature validation)

**Reason for rejection**: Self-hosted deployments may not have public endpoints. Polling is more reliable. Can add webhooks later as optimization.

### Alternative 2: GitHub App

**Description**: Create a GitHub App instead of using PATs

**Pros**:
- Higher rate limits
- Fine-grained permissions per install
- Better for multi-tenant
- Can use webhooks easily

**Cons**:
- More complex setup
- Requires hosting callback endpoint
- Users must install app
- OAuth flow complexity

**Reason for rejection**: PATs are simpler for Phase 1. GitHub App is better for Phase 3 (SaaS) and can be added later.

### Alternative 3: GitHub Actions Trigger

**Description**: Use GitHub Actions workflow to call Paid API on events

**Pros**:
- Real-time
- Runs in GitHub's infrastructure
- No public endpoint needed from Paid

**Cons**:
- Requires workflow in each repo
- User must set up Actions
- Adds complexity to repo
- Minutes cost money

**Reason for rejection**: Adds friction for users. Polling doesn't require any repo changes.

### Alternative 4: No GitHub Projects Integration

**Description**: Skip GitHub Projects, use issues only

**Pros**:
- Simpler implementation
- Works with all GitHub plans
- Fewer API calls

**Cons**:
- Less visual organization
- Harder to track multi-issue features
- Users may expect project boards

**Reason for rejection**: Projects V2 adds value when available. Implementing with graceful degradation gives best of both worlds.

## Trade-offs and Consequences

### Positive Consequences

- **Works anywhere**: Polling works in any self-hosted environment
- **Reliable**: No missed events from webhook failures
- **Simple auth**: PATs are easy for users to create
- **Graceful degradation**: Features work without Projects V2
- **Low friction**: No repo changes required

### Negative Consequences

- **Latency**: Polling interval delays event detection (1-5 minutes)
- **API usage**: Consumes rate limit quota
- **Sync complexity**: Must handle cache invalidation
- **PAT management**: Users must rotate tokens

### Risks and Mitigations

- **Risk**: Rate limiting blocks polling
  **Mitigation**: Conditional requests (ETags), exponential backoff, spread polling across time.

- **Risk**: PAT expires or is revoked
  **Mitigation**: Detect auth failures, notify user, rotation reminders.

- **Risk**: Large repos with many issues
  **Mitigation**: Only fetch issues with trigger labels, pagination, caching.

## Implementation Plan

### Prerequisites

- [ ] Octokit gem added
- [ ] GitHub token model with encryption
- [ ] Issue caching tables

### Step-by-Step Implementation

#### Step 1: Add Gems

```ruby
# Gemfile
gem "octokit"
```

#### Step 2: Token Setup UI

Create UI that guides users through:
1. Creating fine-grained PAT
2. Selecting required scopes
3. Validating token works
4. Encrypting and storing

#### Step 3: Implement GitHub Service

Create service classes as shown above.

#### Step 4: Create Polling Workflow

Implement GitHubPollWorkflow for Temporal.

#### Step 5: Handle Rate Limiting

Add rate limit tracking and backoff logic.

#### Step 6: Add Projects V2 Support

Implement GraphQL mutations with graceful fallback.

### Files to Create/Modify

- `Gemfile` - Add octokit
- `app/models/github_token.rb`
- `app/services/github_service.rb`
- `app/workflows/github_poll_workflow.rb`
- `app/activities/github_activities.rb`
- `app/views/github_tokens/` - Setup UI

### Dependencies

- `octokit` (~> 9.0) - GitHub API client
- Temporal for polling workflow

## Validation

### Testing Approach

1. Unit tests for service classes (mocked API)
2. Integration tests with GitHub API (sandbox repo)
3. Rate limit handling tests
4. Webhook tests (for future)

### Test Scenarios

1. **Scenario**: Issue labeled with trigger label
   **Expected Result**: Detected on next poll, workflow triggered

2. **Scenario**: Rate limit hit during poll
   **Expected Result**: Waits until reset, then resumes

3. **Scenario**: Projects V2 not available
   **Expected Result**: Gracefully degrades, issues still tracked

4. **Scenario**: PAT has insufficient scopes
   **Expected Result**: Clear error message, guided to fix

### Performance Validation

- Poll latency < 5 seconds
- Conditional requests reduce API usage by 80%+
- Cache queries < 10ms

### Security Validation

- Tokens encrypted at rest
- Token scopes validated on creation
- No tokens in logs

## References

### Requirements & Standards

- Paid ARCHITECTURE.md - GitHub integration design
- [GitHub API Documentation](https://docs.github.com/en/rest)
- [GitHub GraphQL API](https://docs.github.com/en/graphql)

### Dependencies

- [Octokit.rb](https://github.com/octokit/octokit.rb)
- [GitHub Rate Limits](https://docs.github.com/en/rest/rate-limit)

### Research Resources

- GitHub polling patterns
- Rate limit optimization strategies
- GitHub Projects V2 API examples

## Notes

- Consider webhooks for Phase 2 when SaaS deployment available
- GitHub App migration path should be planned for Phase 3
- Monitor rate limit usage to tune polling intervals
- Token rotation reminders at 90 days
