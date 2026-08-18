# frozen_string_literal: true

class SyncCreateGithubIssuePromptClarificationFix < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Sync create-issue prompt clarification fix"
  PROMPT_SLUG = "goal.create_github_issue"
  VARIABLES = [
    {
      "name" => "base_prompt",
      "required" => true,
      "description" => "The base prompt this augmentation extends"
    },
    {
      "name" => "repo",
      "required" => true,
      "description" => "Repository full_name (owner/repo)"
    },
    {
      "name" => "decomposition_instructions",
      "required" => true,
      "description" => "Feature decomposition instructions (injected when scope analysis triggers decomposition)"
    }
  ].freeze
  TEMPLATE = <<~TEMPLATE
    {{base_prompt}}

    ---
    IMPORTANT: Your goal is to CREATE A GITHUB ISSUE, not to write code or create a PR.

    Treat the request and repository context already provided above as the full source
    material for the GitHub issue you need to file. Synthesize the issue title, body,
    and any appropriate labels from that context yourself.

    Do NOT reply by asking the user to provide the issue type, title, description,
    labels, or other issue-drafting fields. If a field is not explicitly specified in
    the provided context, make a reasonable choice and continue. When no labels are
    clearly requested, omit them.

    You have access to the GitHub API via a proxy. Use curl to create the issue.

    IMPORTANT: Do NOT pass JSON inline with a single-quoted -d '...'. The body will contain
    markdown with apostrophes (single quotes) and possibly newlines that break shell quoting.
    Instead, write the JSON payload to a temporary file and use --data-binary @file:

    ```bash
    tmpfile=$(mktemp)
    cat > "$tmpfile" <<'ISSUE_JSON'
    {
      "title": "Issue title",
      "body": "Issue description with `code` and apostrophes",
      "labels": []
    }
    ISSUE_JSON
    curl -X POST --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/issues" \
      -H "Content-Type: application/json" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN" \
      --data-binary @"$tmpfile"
    rm -f "$tmpfile"
    ```

    Available endpoints:
    - GET  $GITHUB_API_URL/repos/{{repo}}/issues — list issues
    - GET  $GITHUB_API_URL/repos/{{repo}}/issues/{number} — get issue
    - POST $GITHUB_API_URL/repos/{{repo}}/issues — create issue
    - PATCH $GITHUB_API_URL/repos/{{repo}}/issues/{number} — update issue
    - POST $GITHUB_API_URL/repos/{{repo}}/issues/{number}/comments — add comment
    - POST $GITHUB_API_URL/repos/{{repo}}/issues/{number}/labels — add labels

    Do NOT push code or create a pull request. Only create the GitHub issue.

    {{decomposition_instructions}}
  TEMPLATE

  # Global prompts carry no account_id, so the tenant_isolation_update policy on
  # `prompts` never admits them. Prompt#create_version! locks the row before
  # promoting the new version, and PostgreSQL evaluates SELECT ... FOR UPDATE
  # against that write policy — without system access the lock finds no row.
  #
  # @spec POSTGRESQL-PERSISTENCE-008
  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: TEMPLATE,
        variables: VARIABLES,
        created_by: "migration",
        change_notes: CHANGE_NOTES
      )
    end
  end

  def down
  end

  private

  def normalize(template)
    template.to_s.strip
  end

  def synced?(version)
    return false unless version

    normalize(version.template) == normalize(TEMPLATE) &&
      version.variables == VARIABLES
  end
end
