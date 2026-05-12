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

  describe "goal.review_pull_request clean-PR phrase coupling" do
    # If ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN ever changes, the
    # seeded review template AND the FALLBACK_REVIEW_GOAL_PROMPT in
    # RunAgentActivity must be updated together or clean reviews will
    # silently fail to terminate the review loop.
    let(:pattern) { Activities::ScanPaidPrsActivity::REVIEW_BOT_CLEAN_PATTERN }

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

    it "seeded template tells reviewers to install bundled gems before Ruby validation" do
      template = described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      expect(template).to include(
        "BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle check || " \
          "BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3"
      )
      expect(template).to include("Before running Ruby/Rails commands")
      expect(template).to match(/writable\s+path outside the repository without changing the lockfile/)
      expect(template).to include("missing network access")
    end

    it "FALLBACK_REVIEW_GOAL_PROMPT tells reviewers to install bundled gems before Ruby validation" do
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include(
          "BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle check || " \
            "BUNDLE_PATH=/tmp/bundle BUNDLE_APP_CONFIG=/tmp/bundle-config BUNDLE_FROZEN=true bundle install --jobs 4 --retry 3"
        )
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include("Before running Ruby/Rails commands")
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to match(/writable\s+path outside the repository without changing the lockfile/)
      expect(Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT)
        .to include("missing network access")
    end

    # Regression for #839: review JSON posted with inline `-d '...'` breaks
    # when the body contains multiline markdown or apostrophes, producing an
    # invalid JSON payload that Rails rejects before the request reaches
    # GitHub. Reviews must be submitted via a temp file + `--data-binary @file`.
    describe "review payload submission pattern (issue #839)" do
      let(:seed_template) do
        described_class.global.find_by(slug: "goal.review_pull_request").current_version.template
      end
      let(:fallback_template) { Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT }

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
  end

  describe "goal.create_github_issue drafting guidance" do
    let(:seed_template) do
      described_class.global.find_by(slug: "goal.create_github_issue").current_version.template
    end

    it "seeded template tells the agent to synthesize the issue from existing context" do
      expect(seed_template).to include(
        "Treat the request and repository context already provided above as the full source"
      )
      expect(seed_template).to include(
        "Do NOT reply by asking the user to provide the issue type, title, description,"
      )
      expect(seed_template).to include("When no labels are clearly requested, omit them.")
    end

    it "FALLBACK_ISSUE_GOAL_PROMPT matches the seeded drafting guidance" do
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT).to include(
        "Treat the request and repository context already provided above as the full source"
      )
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT).to include(
        "Do NOT reply by asking the user to provide the issue type, title, description,"
      )
      expect(Activities::RunAgentActivity::FALLBACK_ISSUE_GOAL_PROMPT)
        .to include("When no labels are clearly requested, omit them.")
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
