# frozen_string_literal: true

require "rails_helper"

RSpec.describe IntentConformance::ShadowEvaluation::ReviewContext do
  let(:client) { instance_double(GithubClient) }
  let(:item) do
    { "repository" => "acme/widgets", "base_sha" => "a" * 40, "head_sha" => "b" * 40,
      "approved_design_revision" => "c" * 40 }
  end
  let(:comparison) do
    { commits: [ { sha: "b" * 40, commit: { message: "Use explicit queue labels (#42)" } } ],
      files: [ { filename: "docs/intent/queue/queue-design.md", additions: 2, deletions: 3 } ] }
  end

  def context
    described_class.call(corpus_case: item, comparison:, client:)
  end

  before do
    allow(client).to receive(:pull_request).with("acme/widgets", 42).and_return(
      merge_commit_sha: "b" * 40, title: "Use explicit queue labels", body: "## Summary\nOnly configured labels block work.")
    allow(client).to receive(:file_content).and_return(nil)
    allow(client).to receive(:file_content).with("acme/widgets", path: "docs/intent/queue/queue-design.md", ref: "c" * 40)
      .and_return("# Queue\n\nExplicit dependencies block work.")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "reuses a matching PR summary and recovers requirements only at the approved revision" do
    result = context

    expect(result[:summary]).to include(source: "Pull request #42", title: "Use explicit queue labels")
    expect(result[:documents].sole).to include(path: "docs/intent/queue/queue-design.md", content: include("Explicit dependencies"), source: "recovered")
    expect(client).not_to have_received(:file_content).with(anything, path: anything, ref: "b" * 40)
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "does not show an unrelated or outdated PR description" do
    allow(client).to receive(:pull_request).and_return(merge_commit_sha: "d" * 40, body: "Wrong change")

    expect(context[:summary]).to include(source: "Git commit", title: "Use explicit queue labels (#42)")
    expect(context.to_s).not_to include("Wrong change")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "never substitutes selection notes for missing baseline evidence" do
    item.merge!("notes" => "within scope", "selection_rationale" => "accept this case")
    allow(client).to receive(:file_content).and_return(nil)

    expect(context[:documents]).to be_empty
    expect(context.to_s).not_to include("within scope", "accept this case")
  end

  # @spec INTENT-CONFORMANCE-ROLLOUT-013
  it "retains declared requirements rather than guessing alternatives" do
    item["design_document_paths"] = [ "docs/requirements.md" ]
    allow(client).to receive(:file_content).with("acme/widgets", path: "docs/requirements.md", ref: "c" * 40).and_return("The approved requirement.")

    expect(context[:documents].sole).to include(path: "docs/requirements.md", source: "declared")
  end
end
