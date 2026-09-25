# frozen_string_literal: true

require "rails_helper"

# Loads db/seeds/prompts.rb and verifies that every seeded prompt:
#   1. Creates a Prompt + current PromptVersion row
#   2. Renders without leaving any unresolved {{variable}} placeholders
#      when given the variables declared in its `variables` metadata
#
# This is the regression net for the "all prompts in the table" migration —
# if a caller adds a new {{var}} to its template without declaring it in the
# seed metadata, this spec will fail.
module SeedsPromptsSpec
  EXPECTED_SLUGS = %w[
    ci.failure_guidance
    coding.issue_implementation
    coding.pr_review_rebase
    diagnostics.agent_run_failure
    planning.decompose_feature
    planning.model_selection
    evolution.mutate_prompt
    style.extract_guide
    style.compress_guide
    generation.issue_title
    generation.pr_description
    knowledge.draft_decision
    goal.create_github_issue
    goal.review_pull_request
    goal.enhance_issue
    lid.planning
    service_environment.available_services_intro
    service_environment.environment_constraints_no_db
    service_environment.schema_workflow_ruby
    service_environment.setup.framework_db
    service_environment.setup.no_db
    service_environment.setup.ruby_db
  ].freeze
end

RSpec.describe Prompt, type: :model do
  before do
    load Rails.root.join("db/seeds/prompts.rb").to_s
  end

  SeedsPromptsSpec::EXPECTED_SLUGS.each do |slug|
    describe "prompt #{slug}" do
      let(:prompt) { described_class.global.find_by(slug: slug) }
      let(:version) { prompt&.current_version }

      it "exists with an active current version" do
        expect(prompt).to be_present
        expect(prompt.active).to be true
        expect(version).to be_present
      end

      it "renders without leaving unresolved {{variables}}" do
        vars = Array(version.variables).each_with_object({}) do |v, h|
          name = v.is_a?(Hash) ? (v["name"] || v[:name]) : v.to_s
          h[name.to_sym] = "X"
        end

        rendered = version.render(vars)
        unresolved = rendered.scan(/\{\{\w+\}\}/)
        expect(unresolved).to be_empty,
          "expected no unresolved placeholders in #{slug}, got: #{unresolved.inspect}"
      end

      it "declares every {{placeholder}} that appears in its template" do
        declared = Array(version.variables).map { |v| v.is_a?(Hash) ? (v["name"] || v[:name]) : v.to_s }
        used = version.template.scan(/\{\{(\w+)\}\}/).flatten.uniq
        missing = used - declared
        expect(missing).to be_empty,
          "template references undeclared variables: #{missing.inspect}"
      end
    end
  end

  it "covers every expected slug exactly" do
    actual = described_class.global.where(slug: SeedsPromptsSpec::EXPECTED_SLUGS).pluck(:slug).sort
    expect(actual).to eq(SeedsPromptsSpec::EXPECTED_SLUGS.sort)
  end

  describe "chat.system_prompt feature-design exploration coupling" do
    # The seeded chat template and the in-code base_identity fallback are the
    # two prompt sources for feature-design chat. They must carry the same
    # guidance — including the optional problem-exploration step — so seeded
    # and fallback deployments behave alike (RDR-053 § 2026-09-25 Extension).
    # @spec FEATURE-CREATION-003
    let(:seed_template) do
      described_class.global.find_by(slug: "chat.system_prompt").current_version.template
    end

    it "seeds the feature-design clarification guidance", :aggregate_failures do
      expect(seed_template).to include("gather intent through adaptive questions")
      expect(seed_template).to include("trigger a `create_feature` agent run")
      expect(seed_template).to include("custom_prompt")
    end

    it "seeds the problem-exploration guidance", :aggregate_failures do
      expect(seed_template).to match(/explicitly asks to explore the problem/i)
      expect(seed_template).to include('never run a fixed questionnaire')
      expect(seed_template).to include("tentative hypotheses")
      expect(seed_template).to include('must not itself trigger a `create_feature` agent run or file implementation issues')
      expect(seed_template).to include('justify reconsidering')
    end

    it "seeded template matches the base_identity fallback exactly" do
      expect(seed_template.strip).to eq(ChatSessions::BuildSystemPrompt::DEFAULT_BASE_IDENTITY)
    end
  end

  describe "goal.review_pull_request clean-PR phrase coupling" do
    # If ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN ever changes, the
    # seeded review template AND the FALLBACK_REVIEW_GOAL_PROMPT in
    # RunAgentActivity must be updated together or clean reviews will
    # silently fail to terminate the review loop.
    let(:pattern) { Activities::ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN }
    let(:seed_template) do
      described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
    end
    let(:fallback_template) { Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT }

    it "seeded template body matches the clean-review pattern" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to match(pattern)
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT matches the clean-review pattern" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT).to match(pattern)
    end

    it "seeded template includes the paid_agent clean marker" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to include(Activities::ScanPaidPrsActivity::PAID_REVIEW_CLEAN_MARKER)
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT includes the paid_agent clean marker" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include(Activities::ScanPaidPrsActivity::PAID_REVIEW_CLEAN_MARKER)
    end

    it "seeded template includes the inline comment verification checklist" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to include('Case A: "comments" array is NON-EMPTY, each entry has "path", "line", and "body"')
      expect(template).to include('Case B: body starts with EXACTLY "Generated no new comments." and "comments" is []')
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT includes the inline comment verification checklist" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include('Case A: "comments" array is NON-EMPTY, each entry has "path", "line", and "body"')
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include('Case B: body starts with EXACTLY "Generated no new comments." and "comments" is []')
    end

    it "seeded template forbids REQUEST_CHANGES and APPROVE review events" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to include('Always use `"event": "COMMENT"`')
      expect(template).to include('"REQUEST_CHANGES"')
      expect(template).to include('"APPROVE"')
      expect(template).to include("will be automatically dismissed")
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT forbids REQUEST_CHANGES and APPROVE review events" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include('Always use `"event": "COMMENT"`')
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include('"REQUEST_CHANGES"')
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include('"APPROVE"')
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include("will be automatically dismissed")
    end

    it "seeded template tells reviewers to install bundled gems before Ruby validation" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to include(
        "bundle check || BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3"
      )
      expect(template).to include("Before running Ruby/Rails commands")
      expect(template).to match(/bundled gems it needs without\s+changing the lockfile/)
      expect(template).to include("missing network access")
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT tells reviewers to install bundled gems before Ruby validation" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include(
          "bundle check || BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3"
        )
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include("Before running Ruby/Rails commands")
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to match(/bundled gems it needs without\s+changing the lockfile/)
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include("missing network access")
    end

    # Regression for #839: review JSON posted with inline `-d '...'` breaks
    # when the body contains multiline markdown or apostrophes, producing an
    # invalid JSON payload that Rails rejects before the request reaches
    # GitHub. Reviews must be submitted via a temp file + `--data-binary @file`.
    describe "review payload submission pattern (issue #839)" do
      # Match any curl invocation whose target URL is the /pulls/<n>/reviews
      # endpoint, regardless of what flags come between `curl` and the URL.
      # This catches new shapes (e.g. `curl -sS -X POST`) that a future edit
      # might introduce.
      let(:inline_review_curl_pattern) do
        /curl[^\n]*\/pulls\/[^\n]*\/reviews[^\n]*(?:\\\n[^\n]*)*-d\s+'/m
      end

      it "seeded template posts the review via a temp file and --data-binary" do
        expect(seed_template).to include('--data-binary @"$tmpfile"')
        expect(seed_template).to include("tmpfile=$(mktemp)")
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT posts the review via a temp file and --data-binary" do
        expect(fallback_template).to include('--data-binary @"$tmpfile"')
        expect(fallback_template).to include("tmpfile=$(mktemp)")
      end

      it "seeded template does not model inline `-d '{...}'` for the reviews endpoint" do
        expect(seed_template).not_to match(inline_review_curl_pattern)
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT does not model inline `-d '{...}'` for the reviews endpoint" do
        expect(fallback_template).not_to match(inline_review_curl_pattern)
      end

      it "seeded template warns against inline JSON payloads" do
        expect(seed_template).to match(/Do NOT pass .*inline/i)
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT warns against inline JSON payloads" do
        expect(fallback_template).to match(/Do NOT pass .*inline/i)
      end
    end

    # Acceptance criterion: review scope explicitly covers correctness and
    # removed safeguards alongside the existing performance/security/style/
    # scope/linkage categories, in both the seeded template and the code
    # fallback. Keeps the two bindings in lockstep so a future edit can't
    # add the new scope to only one of them.
    describe "review scope and finding evidence (#3897)" do # @spec REVIEW-PR-002, REVIEW-PR-003
      it "seeded template enumerates the five review-scope axes" do
        expect(seed_template).to include("Scope of review")
        expect(seed_template).to include("PR base/head diff")
        expect(seed_template).to include("Changed behavior")
        expect(seed_template).to include("Removed safeguards")
        expect(seed_template).to include("Caller / callee compatibility")
        expect(seed_template).to include("Project instructions")
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT enumerates the five review-scope axes" do
        expect(fallback_template).to include("Scope of review")
        expect(fallback_template).to include("PR base/head diff")
        expect(fallback_template).to include("Changed behavior")
        expect(fallback_template).to include("Removed safeguards")
        expect(fallback_template).to include("Caller / callee compatibility")
        expect(fallback_template).to include("Project instructions")
      end

      it "seeded template still lists the legacy review categories" do
        expect(seed_template).to include("**Performance**")
        expect(seed_template).to include("**Security**")
        expect(seed_template).to include("**Project code style**")
        expect(seed_template).to include("**Scope violations**")
        expect(seed_template).to include("**Issue linkage**")
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT still lists the legacy review categories" do
        expect(fallback_template).to include("**Performance**")
        expect(fallback_template).to include("**Security**")
        expect(fallback_template).to include("**Project code style**")
        expect(fallback_template).to include("**Scope violations**")
        expect(fallback_template).to include("**Issue linkage**")
      end

      it "seeded template requires triggering state, concrete cost, and supporting code location for each finding" do
        expect(seed_template).to include("Finding quality bar")
        expect(seed_template).to include("Triggering state.")
        expect(seed_template).to include("Resulting incorrect behavior or concrete cost.")
        expect(seed_template).to include("Supporting code location.")
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT requires triggering state, concrete cost, and supporting code location for each finding" do
        expect(fallback_template).to include("Finding quality bar")
        expect(fallback_template).to include("Triggering state.")
        expect(fallback_template).to include("Resulting incorrect behavior or concrete cost.")
        expect(fallback_template).to include("Supporting code location.")
      end

      it "seeded template requires the reviewer to recheck each finding against surrounding code before posting" do
        expect(seed_template).to include("Recheck against surrounding code before posting")
        expect(seed_template).to match(/Walk one or\ntwo levels above and below the cited line/)
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT requires the reviewer to recheck each finding against surrounding code before posting" do
        expect(fallback_template).to include("Recheck against surrounding code before posting")
        expect(fallback_template).to match(/Walk one or\ntwo levels above and below the cited line/)
      end

      it "seeded template keeps the actionable-only inline comment rule and forbids nitpicks" do
        expect(seed_template).to include("Inline comments are reserved **exclusively for actionable changes**")
        expect(seed_template).to match(/Do not\ninvent nitpicks/)
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT keeps the actionable-only inline comment rule and forbids nitpicks" do
        expect(fallback_template).to include("Inline comments are reserved **exclusively for actionable changes**")
        expect(fallback_template).to match(/Do not\ninvent nitpicks/)
      end
    end

    # The seed and the code fallback MUST stay in lockstep byte-for-byte.
    # spec/services/prompts/goal_create_github_issue_spec.rb holds the
    # analogous invariant for the create_github_issue goal via
    # Prompts::GoalCreateGithubIssue::TEMPLATE. The seed records the same
    # shared source so the two cannot drift apart.
    describe "seeded template matches the shared source exactly" do # @spec REVIEW-PR-001
      it "seed template equals Prompts::GoalReviewPullRequest::TEMPLATE" do
        expect(seed_template.strip).to eq(Prompts::GoalReviewPullRequest::TEMPLATE.strip)
      end

      it "FALLBACK_REVIEW_GOAL_PROMPT equals Prompts::GoalReviewPullRequest::TEMPLATE" do
        expect(fallback_template.strip).to eq(Prompts::GoalReviewPullRequest::TEMPLATE.strip)
      end
    end
  end

  describe "goal.create_github_issue drafting guidance" do
    let(:seed_template) do
      described_class.global.find_by(slug: Prompts::GoalCreateGithubIssue::PROMPT_SLUG).current_version.template
    end

    it "seeded template tells the agent to synthesize the issue from existing context" do
      expect(seed_template).to include(
        "Treat the request and repository context already provided above as the full source"
      )
      expect(seed_template).to include(
        "Do NOT reply by asking the user to provide the issue type, title, description,"
      )
      expect(seed_template).to match(/When no labels are\s+clearly requested, omit them\./)
    end

    it "FALLBACK_ISSUE_GOAL_PROMPT matches the seeded drafting guidance" do
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT).to include(
        "Treat the request and repository context already provided above as the full source"
      )
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT).to include(
        "Do NOT reply by asking the user to provide the issue type, title, description,"
      )
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT)
        .to match(/When no labels are\s+clearly requested, omit them\./)
    end

    it "seeded template matches the shared template source exactly" do
      expect(seed_template).to eq(Prompts::GoalCreateGithubIssue::TEMPLATE)
    end

    it "FALLBACK_ISSUE_GOAL_PROMPT matches the shared template source exactly" do
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT)
        .to eq(Prompts::GoalCreateGithubIssue::TEMPLATE)
    end
  end

  describe "goal.enhance_issue self-contained questions coupling" do
    # If the question-context guidance ever changes, the seeded template AND
    # the FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT in RunAgentActivity must be
    # updated together (plus the prompt-sync migration), or fallback runs and
    # seeded runs will ask differently-shaped questions.
    let(:seed_template) do
      described_class.global.find_by(slug: "goal.enhance_issue").current_version.template
    end
    let(:fallback_template) { Activities::RunAgentActivity::FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT }

    it "seeded template requires each clarifying question to stand on its own", :aggregate_failures do # @spec ISSUE-ENHANCEMENT-014
      expect(seed_template).to include("stands on its own")
      expect(seed_template).to match(/why you are asking and what\s+you found in the repository/)
      expect(seed_template).to include("Reference the relevant code, issue, or doc")
      expect(seed_template).to include("name the options")
      expect(seed_template).to include("where the issue sits in the roadmap")
    end

    it "FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT requires self-contained questions", :aggregate_failures do # @spec ISSUE-ENHANCEMENT-014
      expect(fallback_template).to include("stands on its own")
      expect(fallback_template).to match(/why you are asking and what\s+you found in the repository/)
      expect(fallback_template).to include("Reference the relevant code, issue, or doc")
      expect(fallback_template).to include("name the options")
      expect(fallback_template).to include("where the issue sits in the roadmap")
    end

    it "seeded template matches the code fallback template exactly" do
      expect(seed_template.strip).to eq(fallback_template.strip)
    end

    it "seeded template requires strict choice-option markers for enumerable questions", :aggregate_failures do # @spec ISSUE-ENHANCEMENT-018
      expect(seed_template).to include("Choice questions")
      expect(seed_template).to include("- ( ) SQLite) local file, zero setup")
      expect(seed_template).to include("`- ( ) Label) description` lines when exactly one answer applies")
      expect(seed_template).to include("`- [ ] Label) description` lines when several answers may apply")
      expect(seed_template).to match(/Provide at least two\s+option lines/)
    end

    it "FALLBACK_ENHANCE_ISSUE_GOAL_PROMPT requires strict choice-option markers", :aggregate_failures do # @spec ISSUE-ENHANCEMENT-018
      expect(fallback_template).to include("Choice questions")
      expect(fallback_template).to include("- ( ) SQLite) local file, zero setup")
      expect(fallback_template).to include("`- ( ) Label) description` lines when exactly one answer applies")
      expect(fallback_template).to include("`- [ ] Label) description` lines when several answers may apply")
      expect(fallback_template).to match(/Provide at least two\s+option lines/)
    end
  end

  describe "coding.pr_review_rebase already-addressed marker" do
    it "seeded template includes the no-change review resolution variable slot" do
      template = described_class.global.find_by(slug: "coding.pr_review_rebase").current_version.template
      expect(template).to include("{{already_addressed_instruction}}")
    end

    it "fallback prompt includes the no-change review resolution variable slot" do
      expect(Prompts::BuildForPr::FALLBACK_PROMPT).to include("{{already_addressed_instruction}}")
    end

    it "seeded template declares the no-change review resolution variable" do
      variables = described_class.global.find_by(slug: "coding.pr_review_rebase").current_version.variables
      names = variables.map { |variable| variable["name"] || variable[:name] }
      expect(names).to include("already_addressed_instruction")
    end
  end
end
