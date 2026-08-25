# frozen_string_literal: true

class SyncEnhanceIssueStructuredOutputPrompt < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Require structured output and platform-owned comment posting for enhance_issue"
  PROMPT_SLUG = "goal.enhance_issue"
  VARIABLES = [
    { "name" => "base_prompt", "required" => true, "description" => "The base prompt this augmentation extends" },
    { "name" => "repo", "required" => true, "description" => "Repository full_name (owner/repo)" },
    { "name" => "issue_number", "required" => true, "description" => "GitHub issue number" }
  ].freeze
  TEMPLATE = <<~'TEMPLATE'
    {{base_prompt}}

    ---
    IMPORTANT: Your goal is to ENHANCE AN EXISTING ISSUE by adding context or asking clarifying questions.
    Do NOT write code, create PRs, create new issues, push commits, or post GitHub comments.

    This run is read-only: do NOT modify files in /workspace, commit, push, create a PR,
    or mutate GitHub. The workflow discards workspace modifications and posts the validated
    enhancement comment itself. You can explore and read the repo freely.
    State directories (under /home/agent/) are writable for scratch/tooling needs.

    Read issue #{{issue_number}} in {{repo}}. Trusted collaborator comments are already included in
    the base prompt; do not fetch raw issue comments. Explore the repository
    to self-answer codebase-determinable questions (existing models, platform targets, patterns, etc.)
    before asking the human. Only ask about genuine product, scope, or intent ambiguities.

    You can search the project's knowledge base to look up existing code,
    symbols, routes, and patterns before asking questions:

    ```bash
    curl -s --connect-timeout 10 --max-time 30 "$KNOWLEDGE_SEARCH_URL?q=sortable+column+dashboard" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"
    ```

    Use the GitHub API proxy only to read issue details:

    ```bash
    curl -s --connect-timeout 10 --max-time 30 "$GITHUB_API_URL/repos/{{repo}}/issues/{{issue_number}}" \
      -H "X-Agent-Run-Id: $AGENT_RUN_ID" \
      -H "X-Proxy-Token: $PROXY_TOKEN"
    ```

    When you are finished, print your result on stdout wrapped between
    delimiter lines (exactly `paid-enhance-issue-output` on its own line,
    before and after the JSON). Print nothing else between the markers:

    paid-enhance-issue-output
    {
      "sufficient_context": true or false,
      "comment_body": "Markdown comment with implementation context or clarifying questions"
    }
    paid-enhance-issue-output

    If sufficient_context is true, the comment_body should include:
    ## Implementation context
    ### Relevant files and symbols
    - ...
    ### Architecture notes
    - ...
    ### Suggested approach
    - ...

    If sufficient_context is false, the comment_body should include:
    ## Clarifying questions
    1. ...
    ## Current context
    - ...
  TEMPLATE

  # @spec ISSUE-ENHANCEMENT-010, POSTGRESQL-PERSISTENCE-008
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

  def down; end

  private

  def synced?(version)
    version && version.template.to_s.strip == TEMPLATE.strip && version.variables == VARIABLES
  end
end
