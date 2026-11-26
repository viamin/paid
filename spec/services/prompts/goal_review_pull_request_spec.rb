# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/services/prompts/goal_review_pull_request"
require_relative "../../../app/services/prompts/render"

# Behavior-focused tests for the review-goal prompt augmentation source.
# The seed (db/seeds/prompts.rb) and the code fallback
# (Activities::RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT) both bind to
# this shared source, so an assertion on Prompts::GoalReviewPullRequest is an
# assertion on the union of the two bindings.
RSpec.describe Prompts::GoalReviewPullRequest, :no_db do
  it "declares the expected prompt slug and variables" do
    expect(described_class::PROMPT_SLUG).to eq("goal.review_pull_request")
    expect(described_class::VARIABLES).to eq(
      [
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
          "name" => "pr_number",
          "required" => true,
          "description" => "Pull request number"
        }
      ]
    )
  end

  describe "review scope (#3897)" do # @spec REVIEW-PR-002
    # Acceptance criterion: review scope must explicitly cover PR base/head
    # diff, changed behavior, removed safeguards, caller/callee compatibility,
    # and project instructions, alongside the existing security/performance/
    # style/scope/linkage categories.
    it "enumerates the five review-scope axes in order" do
      scope_match = described_class::TEMPLATE.match(
        /Scope of review.*?Review categories/m
      )
      expect(scope_match).not_to be_nil
      scope_block = scope_match[0]

      expect(scope_block).to include("PR base/head diff")
      expect(scope_block).to include("Changed behavior")
      expect(scope_block).to include("Removed safeguards")
      expect(scope_block).to include("Caller / callee compatibility")
      expect(scope_block).to include("Project instructions")
    end

    it "treats removed safeguards as an explicit, separate axis from changed behavior" do
      expect(described_class::TEMPLATE).to include('3. **Removed safeguards.** ')
      expect(described_class::TEMPLATE).to include('2. **Changed behavior.** ')
    end

    it "preserves the legacy performance/security/style/scope/linkage categories" do
      expect(described_class::TEMPLATE).to include("**Performance**")
      expect(described_class::TEMPLATE).to include("**Security**")
      expect(described_class::TEMPLATE).to include("**Best practices**")
      expect(described_class::TEMPLATE).to include("**Project code style**")
      expect(described_class::TEMPLATE).to include("**Scope violations**")
      expect(described_class::TEMPLATE).to include("**Issue linkage**")
    end
  end

  describe "finding evidence bar (#3897)" do # @spec REVIEW-PR-003
    # Acceptance criterion: each proposed finding must name a triggering
    # state, resulting incorrect behavior or concrete cost, and supporting
    # code location, and the reviewer must recheck against surrounding code
    # before posting.
    it "requires a triggering state for each finding" do
      expect(described_class::TEMPLATE).to include("Triggering state.")
      expect(described_class::TEMPLATE).to include("Name the input, configuration, branch, or")
      expect(described_class::TEMPLATE).to include("condition that triggers the problem")
    end

    it "requires the resulting incorrect behavior or concrete cost for each finding" do
      expect(described_class::TEMPLATE).to include("Resulting incorrect behavior or concrete cost.")
      expect(described_class::TEMPLATE).to match(/Vague "this might be wrong"\s+framings are not findings/)
    end

    it "requires a supporting code location for each finding" do
      expect(described_class::TEMPLATE).to include("Supporting code location.")
      expect(described_class::TEMPLATE).to include("Cite the file path and line number")
      expect(described_class::TEMPLATE).to match(/The inline comment's .path. \/ .line. MUST point at the\s+triggering code/)
    end

    it "requires the reviewer to recheck each finding against surrounding code before posting" do
      expect(described_class::TEMPLATE).to include("Recheck against surrounding code before posting")
      expect(described_class::TEMPLATE).to match(/Walk one or\ntwo levels above and below the cited line/)
      expect(described_class::TEMPLATE).to match(/Review depth is not permission\s+to invent nitpicks/)
    end
  end

  describe "review contract preservation" do # @spec REVIEW-PR-004, REVIEW-PR-005, REVIEW-PR-006
    # Acceptance criterion: the clean-review signal and one-review contract
    # must survive the scope/evidence expansion. These markers are matched
    # by ScanPaidPrsActivity to stop the review loop and must remain
    # byte-identical.
    it "keeps the Case B clean-review signal phrase and HTML marker" do
      expect(described_class::TEMPLATE).to include('body starts with EXACTLY "Generated no new comments."')
      expect(described_class::TEMPLATE).to include("<!-- paid-review-clean -->")
    end

    it "forbids REQUEST_CHANGES and APPROVE review events" do
      expect(described_class::TEMPLATE).to include('Always use `"event": "COMMENT"`')
      expect(described_class::TEMPLATE).to include('"REQUEST_CHANGES"')
      expect(described_class::TEMPLATE).to include('"APPROVE"')
    end

    it "forbids praise-only inline comments and nitpicks" do
      expect(described_class::TEMPLATE)
        .to include("Inline comments are reserved **exclusively for actionable changes**")
      expect(described_class::TEMPLATE).to match(/Do not\ninvent nitpicks/)
    end

    it "posts the review via a temp file and --data-binary" do
      expect(described_class::TEMPLATE).to include("tmpfile=$(mktemp)")
      expect(described_class::TEMPLATE).to include('--data-binary @"$tmpfile"')
    end
  end

  describe "dependency preparation and limited review (#5398)" do # @spec REVIEW-PR-008, REVIEW-PR-009
    it "checks the locked bundle before one visible, bounded preparation attempt" do
      expect(described_class::TEMPLATE).to include("bundle check")
      expect(described_class::TEMPLATE).to include("timeout 120s")
      expect(described_class::TEMPLATE).to include("BUNDLE_FROZEN=true")
      expect(described_class::TEMPLATE).to include("--retry 0")
      expect(described_class::TEMPLATE).to include("Do not pipe this command")
      expect(described_class::TEMPLATE).to include("Do not make a second dependency-preparation attempt")
      expect(described_class::TEMPLATE).to include("remaining review time cannot accommodate the attempt")
    end

    it "keeps unavailable git dependencies, stalled setup, and terminal setup failures truthful" do
      expect(described_class::TEMPLATE).to include("unavailable git dependency")
      expect(described_class::TEMPLATE).to match(/times out or\s+produces no meaningful progress/)
      expect(described_class::TEMPLATE).to match(/another terminal\s+setup failure/)
      expect(described_class::TEMPLATE).to include("No local tests were run")
    end

    it "publishes a limited review without the clean marker and stops when the diff is unavailable" do
      limited_review = described_class::TEMPLATE.match(/Case C.*?If the base\/head diff/m)[0]

      expect(limited_review).to include('"event": "COMMENT"')
      expect(limited_review).to include('"comments": []')
      expect(limited_review).not_to include("<!-- paid-review-clean -->")
      expect(limited_review).to include("not a clean review or merge authorization")
      expect(limited_review).to include("matching the observed terminal outcome")
      expect(limited_review).to match(/Never post the sample's\s+#\s+unavailable-git-dependency reason when it is not true/)
      expect(described_class::TEMPLATE).to include("actionable unavailable stop")
    end

    it "discloses unavailable dependencies when a limited review finds actionable issues" do
      actionable_review = described_class::TEMPLATE.match(/Case A.*?Case B/m)[0]

      expect(actionable_review).to include("No local tests were run")
      expect(actionable_review).to include("not a clean review or merge authorization")
      expect(actionable_review).to include("inline comments")
    end
  end

  describe "renders all declared placeholders" do # @spec REVIEW-PR-007
    let(:variables) { described_class::VARIABLES.map { |v| v["name"].to_sym } }

    it "does not leave unresolved {{variables}} when supplied every declared variable" do
      rendered = Prompts::Render.interpolate(
        described_class::TEMPLATE,
        variables.to_h { |v| [ v, "X" ] }
      )
      expect(rendered).not_to match(/\{\{\w+\}\}/)
    end
  end
end
