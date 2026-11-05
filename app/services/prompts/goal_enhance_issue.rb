# frozen_string_literal: true

module Prompts
  # Shared source for the `goal.enhance_issue` prompt.
  #
  # The seeded template, the code fallback in `RunAgentActivity`, and the
  # prompt-sync migration must carry the same instructions, or fallback runs
  # and seeded runs ask differently-shaped questions.
  #
  # The clarifying-question contract lives here: the numbered question stays
  # short and standalone, and the parts of the clarification that are not the
  # question itself — the offered choices, Paid's recommendation, the
  # rationale, the examples, and the evidence references — travel in the
  # `clarifying_questions` payload of the agent's structured output.
  # @spec ISSUE-ENHANCEMENT-014
  # @spec ISSUE-ENHANCEMENT-018
  # @spec ISSUE-ENHANCEMENT-020
  module GoalEnhanceIssue
    PROMPT_SLUG = "goal.enhance_issue"
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
        "name" => "issue_number",
        "required" => true,
        "description" => "GitHub issue number"
      }
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
        "comment_body": "Markdown comment with implementation context or clarifying questions",
        "clarifying_questions": [
          {
            "question": "Which storage backend should the export use?",
            "choices": [
              { "label": "SQLite", "text": "local file, zero setup" },
              { "label": "Postgres", "text": "already used for app data" }
            ],
            "multiple": false,
            "recommendation": { "label": "SQLite", "text": "matches the existing export path" },
            "rationale": "Both backends are vendored, but only SQLite needs no server.",
            "examples": [ "A nightly CSV dump written to a local path" ],
            "evidence": [ "app/models/export.rb", "#1234" ]
          }
        ]
      }
      paid-enhance-issue-output

      Include "clarifying_questions" only when sufficient_context is false. It carries one
      entry per clarifying question, in the same order as the numbered list.

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

      Write each clarifying question so it stands on its own: the reader cannot be
      assumed to know the project, the issue history, or the roadmap. Keep the
      numbered question short - one or two sentences that ask for one decision.
      Do NOT put background, alternatives, code references, or your reasoning
      inside the numbered question. The operator reads the question first and the
      supporting detail second, so put that detail in the payload:
      - Put the background - why you are asking and what you found in the repository - in "rationale".
      - Reference the relevant code, issue, or doc in "evidence" when one exists
        (file path and symbol, issue number such as #123, or design doc).
      - When the question could be read two ways, name the options in "choices"
        instead of naming them in prose.
      - When the answer depends on where the issue sits in the roadmap, say so in
        "evidence" or "rationale" - dependencies on other issues, or follow-up
        work this issue enables.
      Keep each question a single numbered item so the question list stays
      machine-parseable.

      Each clarifying_questions entry has one field per part of the clarification:
      - "question": the same question text as the numbered item.
      - "choices": the answers the operator can pick. Give each one a short
        "label" and a one-sentence "text". Add "multiple": true when several
        answers may apply. Leave "choices" out when the answer is open-ended.
      - "recommendation": the option you believe is best, with the reason in
        "text". Include it only when the repository, the issue, or a trusted
        comment gives evidence for one option. Never present a guess as a
        decision, and leave it out when the requirement is genuinely ambiguous.
      - "rationale": why you are asking and what you found. Explain, do not decide.
      - "examples": what an answer looks like.
      - "evidence": the code, issue, or doc references behind the question.
    TEMPLATE
  end
end
