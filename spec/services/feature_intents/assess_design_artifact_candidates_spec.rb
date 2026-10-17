# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe FeatureIntents::AssessDesignArtifactCandidates do
  let(:project) { create(:project, owner: "acme", repo: "widget") }
  let(:artifact) { { path: "docs/rdrs/RDR-100.md", revision: "a" * 40, body: "Implement repository traceability." } }
  let(:issues) do
    [ { repository: "acme/widget", number: 10, state: "open", revision: "2026-10-16T00:00:00Z", title: "Traceability", body: "Implement traceability." } ]
  end

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache)
  end

  it "retains a semantic match and reuses it for unchanged revisions" do
    response = instance_double(AgentHarness::Response, success?: true, output: '{"issue_identity":"acme/widget#10","explanation":"It implements the RDR scope."}')
    allow(AgentHarness).to receive(:send_message).and_return(response)

    first = described_class.call(project:, artifact:, issues:)
    second = described_class.call(project:, artifact:, issues:)

    expect(first).to have_attributes(identity: "acme/widget#10", evidence: "It implements the RDR scope.")
    expect(second).to eq(first)
    expect(AgentHarness).to have_received(:send_message).once
  end

  it "retains a completed assessment after the former cache expiry" do
    response = instance_double(AgentHarness::Response, success?: true, output: '{"issue_identity":"acme/widget#10","explanation":"It implements the RDR scope."}')
    allow(AgentHarness).to receive(:send_message).and_return(response)

    described_class.call(project:, artifact:, issues:)
    travel 8.days do
      described_class.call(project:, artifact:, issues:)
    end

    expect(AgentHarness).to have_received(:send_message).once
  end

  it "reassesses when the artifact revision changes" do
    first_response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":null,"explanation":"The first revision has no match."}')
    second_response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#10","explanation":"The revised artifact is covered."}')
    allow(AgentHarness).to receive(:send_message).and_return(first_response, second_response)

    first = described_class.call(project:, artifact:, issues:)
    second = described_class.call(project:, artifact: artifact.merge(revision: "b" * 40), issues:)

    expect(first).not_to be_covered
    expect(second).to have_attributes(identity: "acme/widget#10", evidence: "The revised artifact is covered.")
    expect(AgentHarness).to have_received(:send_message).twice
  end

  it "does not use closed work as semantic implementation coverage" do
    closed_issues = issues.map { |issue| issue.merge(state: "closed") }

    result = described_class.call(project:, artifact:, issues: closed_issues)

    expect(result).not_to be_covered
  end

  it "retries a malformed semantic response instead of caching it" do
    malformed_response = instance_double(AgentHarness::Response, success?: true, output: "[]")
    completed_response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#10","explanation":"It implements the RDR scope."}')
    allow(AgentHarness).to receive(:send_message).and_return(malformed_response, completed_response)

    invalid = described_class.call(project:, artifact:, issues:)
    retry_result = described_class.call(project:, artifact:, issues:)

    expect(invalid).to have_attributes(identity: nil, evidence: "Semantic assessment returned an invalid response")
    expect(retry_result).to have_attributes(identity: "acme/widget#10", evidence: "It implements the RDR scope.")
    expect(AgentHarness).to have_received(:send_message).twice
  end

  it "retries an unavailable semantic assessment instead of caching it" do
    response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#10","explanation":"It implements the RDR scope."}')
    attempts = 0
    allow(AgentHarness).to receive(:send_message) do
      attempts += 1
      raise AgentHarness::Error, "provider timeout" if attempts == 1

      response
    end

    unavailable = described_class.call(project:, artifact:, issues:)
    retry_result = described_class.call(project:, artifact:, issues:)

    expect(unavailable).to have_attributes(identity: nil, evidence: "Semantic assessment was unavailable")
    expect(retry_result).to have_attributes(identity: "acme/widget#10", evidence: "It implements the RDR scope.")
    expect(AgentHarness).to have_received(:send_message).twice
  end

  it "retries an incomplete semantic assessment instead of caching it" do
    incomplete_response = instance_double(AgentHarness::Response, success?: false)
    completed_response = instance_double(AgentHarness::Response, success?: true,
      output: '{"issue_identity":"acme/widget#10","explanation":"It implements the RDR scope."}')
    allow(AgentHarness).to receive(:send_message).and_return(incomplete_response, completed_response)

    incomplete = described_class.call(project:, artifact:, issues:)
    retry_result = described_class.call(project:, artifact:, issues:)

    expect(incomplete).to have_attributes(identity: nil, evidence: "Semantic assessment did not complete")
    expect(retry_result).to have_attributes(identity: "acme/widget#10", evidence: "It implements the RDR scope.")
    expect(AgentHarness).to have_received(:send_message).twice
  end
end
