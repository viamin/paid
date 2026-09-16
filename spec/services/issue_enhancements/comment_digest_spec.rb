# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-ANALYSIS-015
RSpec.describe IssueEnhancements::CommentDigest do
  def digest(bodies, total_budget:, section_budget: 4_000)
    described_class.call(bodies: bodies, total_budget: total_budget, section_budget: section_budget)
  end

  it "strips Paid markers and keeps the section content" do
    body = "<!-- paid:enhance-issue -->\n\n## Implementation context\n- `app/models/audit_log.rb`\n"

    expect(digest([ body ], total_budget: 4_000)).to eq([ "## Implementation context\n- `app/models/audit_log.rb`" ])
  end

  it "keeps a decision-relevant section that starts beyond a head-truncate window" do
    preamble = "Thanks for the detailed report. #{'x' * 2_500}"
    body = "#{preamble}\n\n## Implementation context\n### Suggested approach\n- add a model\n"

    result = digest([ body ], total_budget: 2_000).first

    expect(result).to include("## Implementation context")
    expect(result).to include("### Suggested approach")
    expect(result).to include("- add a model")
    expect(result.length).to be <= 2_000
  end

  it "drops CIR and stopped-round boilerplate before decision-relevant sections" do
    body = <<~BODY
      <!-- paid:enhance-issue-manual-review -->
      ## Auto-enhancement stopped

      Paid has reached the configured limit of 3 enhancement re-evaluation rounds for this issue.

      ## Latest context
      ## Clarifying questions
      1. Should the audit log be per-tenant?

      ## Proposed Change Intent Record

      This issue contains a non-obvious constraint worth preserving for future work.
    BODY

    result = digest([ body ], total_budget: 120).first

    expect(result).to include("Should the audit log be per-tenant?")
    expect(result).not_to include("Auto-enhancement stopped")
    expect(result).not_to include("Proposed Change Intent Record")
    expect(result).not_to include("## Latest context")
  end

  it "renders retained sections in their original order" do
    body = "## Clarifying questions\n1. Which tenant?\n\n## Current context\n- none\n\n## Implementation context\n- files\n"

    result = digest([ body ], total_budget: 4_000).first

    expect(result.index("## Clarifying questions")).to be < result.index("## Current context")
    expect(result.index("## Current context")).to be < result.index("## Implementation context")
  end

  it "prefers newer comments within a tier and returns bodies in the given order" do
    older = "## Implementation context\n#{'a' * 1_000}"
    newer = "## Clarifying questions\n#{'b' * 1_000}"

    result = digest([ older, newer ], total_budget: 1_200)

    expect(result.last).to include("b" * 1_000)
    expect(result.first).to start_with("## Implementation context")
    expect(result.first.length).to be < 300
  end

  it "caps each section so one long section cannot starve the others, then tops up" do
    long = "## Implementation context\n#{'a' * 5_000}"
    questions = "## Clarifying questions\n#{'b' * 500}"

    result = digest([ long, questions ], total_budget: 3_000, section_budget: 1_000)

    expect(result.last).to include("b" * 500)
    expect(result.first.length).to be_between(1_000, 3_000 - 500 - "## Clarifying questions\n".length)
    expect(result.sum(&:length)).to be <= 3_000
  end

  it "treats fenced code blocks as opaque when splitting sections" do
    body = "## Implementation context\n```md\n## not a heading\n```\n- real content\n"

    result = digest([ body ], total_budget: 4_000).first

    expect(result).to eq(body.strip)
  end

  it "returns an empty string for comments with no admissible content" do
    expect(digest([ "<!-- paid:enhance-issue -->", "  " ], total_budget: 4_000)).to eq([ "", "" ])
  end
end
