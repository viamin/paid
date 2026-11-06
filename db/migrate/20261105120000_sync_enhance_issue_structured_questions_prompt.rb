# frozen_string_literal: true

class SyncEnhanceIssueStructuredQuestionsPrompt < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Ask for structured clarifying questions with separate supporting context"
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
    the base prompt. Do not fetch raw issue comments. Explore the repository
    to self-answer codebase-determinable questions (existing models, platform targets, patterns, etc.)
    before asking the human. Only ask about genuine product, scope, or intent ambiguities.

    Write the comment in simplified technical English. Use short sentences. One idea per sentence.
    Use plain technical words. Do not stack jargon. Avoid nested clauses and long noun chains.
    Keep technical precision. Simplify the wording, not the meaning.

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
      "comment_body": "Markdown comment with implementation context or concise numbered questions",
      "questions": [
        {
          "question": "One short standalone question?",
          "choices": [
            { "label": "Option A", "detail": "Short consequence" },
            { "label": "Option B", "detail": "Alternative consequence" }
          ],
          "choice_type": "single",
          "recommendation": "Option A",
          "rationale": "Why this is a recommendation",
          "examples": ["Concrete example"],
          "evidence_references": ["app/path.rb:12"]
        }
      ]
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

    If sufficient_context is false, include a non-empty `questions` array and
    make comment_body include the same concise numbered question labels:
    ## Clarifying questions
    1. ...
    ## Current context
    - ...

    Each `question` must be concise and standalone. Keep background, reasons,
    examples, references, and roadmap context out of its label. Put those facts
    in `rationale`, `examples`, and `evidence_references` instead. Supply
    `choices` only for an enumerable set of at least two options; with fewer
    options the question is not a choice question. Supply `recommendation`
    only when `evidence_references` directly support it; otherwise omit it.
    A recommendation is an aid, never a confirmed product decision.
    For each choice question, set `choice_type` to `single` when exactly one
    answer applies or `multi` when several answers may apply. It MUST match
    the marker family used in the comment body. Each structured `choices`
    entry MUST repeat its comment marker's Label and description byte-for-byte.
    A structured choice label must not contain the `)` character. Keep the
    complete comment_body to no more than 50,000 characters so publication
    does not truncate any numbered question or choice marker.

    Choice questions. When — and only when — a question has a short, enumerable
    set of answers, put the answers in a sub-list under the numbered question
    using these exact marker lines:

    1. Which storage backend should the export use?
       - ( ) SQLite) local file, zero setup
       - ( ) Postgres) already used for app data
       - ( ) Flat JSON) easiest to diff

    Use `- ( ) Label) description` lines when exactly one answer applies. Use
    `- [ ] Label) description` lines when several answers may apply. The Label
    is a short answer name of up to a few words and must not contain the `)`
    character. The description is one short sentence. Provide at least two
    option lines; with fewer options the question is not a choice question —
    write it as prose. Never use these markers for context bullets or for
    examples anywhere else in the comment.
  TEMPLATE

  # @spec ISSUE-ENHANCEMENT-020
  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt

      next if synced?(prompt.current_version)

      prompt.create_version!(template: TEMPLATE, variables: VARIABLES, created_by: "migration", change_notes: CHANGE_NOTES)
    end
  end

  def down; end

  private

  def synced?(version)
    version && version.template.to_s.strip == TEMPLATE.strip && version.variables == VARIABLES
  end
end
