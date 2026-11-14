# frozen_string_literal: true

require "rails_helper"

RSpec.describe PullRequests::SourceClosureBody do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, github_number: 42) }

  it "rewrites an explicit closing reference when assessment does not authorize closure" do # @spec PARTIAL-CLOSEOUT-029
    body = described_class.call(body: "## Report\n\nFixes #42", issue: issue, project: project, disposition: "track")

    expect(body).to include("Tracks #42")
    expect(body).not_to match(/(?:Closes|Fixes|Resolves)\s+#42/i)
  end

  it "rewrites every closing-keyword form and a source-repository-qualified reference" do # @spec PARTIAL-CLOSEOUT-029
    closing_keywords = %w[Close Closes Closed Fix Fixes Fixed Resolve Resolves Resolved]
    body = described_class.call(
      body: closing_keywords.map.with_index do |keyword, index|
        reference = index.zero? ? "#{project.issue_target_repository}#42" : "#42"
        "#{keyword} #{reference}"
      end.join("\n"),
      issue: issue,
      project: project,
      disposition: "track"
    )

    expect(body).to eq(Array.new(closing_keywords.length, "Tracks #42").join("\n"))
  end

  it "appends one canonical closing reference for supported completion" do # @spec PARTIAL-CLOSEOUT-029
    body = described_class.call(body: "## Report\n\nTracks #42", issue: issue, project: project, disposition: "close")

    expect(body.scan("Closes #42")).to eq([ "Closes #42" ])
  end

  it "promotes only the source reference without duplicating it on replay" do # @spec PARTIAL-CLOSEOUT-050
    body = "## Report\n\nTracks #42\n\nRelates to #99"

    promoted = described_class.call(body:, issue:, project:, disposition: "close")

    expect(promoted).to eq("## Report\n\nCloses #42\n\nRelates to #99")
    expect(described_class.call(body: promoted, issue:, project:, disposition: "close")).to eq(promoted)
  end
end
