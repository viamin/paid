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
