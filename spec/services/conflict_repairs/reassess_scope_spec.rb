# frozen_string_literal: true

require "ostruct"
require "rails_helper"

# @spec AUTO-MERGE-011
RSpec.describe ConflictRepairs::ReassessScope do
  let(:project) { create(:project) }
  let(:requester) { create(:user, :member, account: project.account) }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 42) }
  let(:run) do
    create(:agent_run, :automatic, :failed, project:, issue:, goal: "create_pr", focus: "merge_conflict",
      source_pull_request_number: 42, result_commit_sha: "result-sha",
      external_metadata: { "pre_run_head_sha" => "pre-sha", "conflict_repair_scope_assessment" => { "status" => "unavailable" } })
  end
  let(:client) { instance_double(GithubClient) }
  let(:head) { OpenStruct.new(sha: "result-sha") }
  let(:base) { OpenStruct.new(sha: "base-sha") }
  let(:pr) { OpenStruct.new(head:, base:) }

  before do
    allow(project).to receive(:client).and_return(client)
    allow(CostBudgets::Check).to receive(:call).and_return({ allowed: true })
    allow(client).to receive(:pull_request).with(project.full_name, 42).and_return(pr)
    allow(client).to receive(:compare_summary).and_return({ files: [] })
  end

  it "records fresh approved evidence without changing the failed producer" do
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "bounded repair", base_imported_paths: [], repair_authored_paths: []))

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result).to be_accepted
    expect(result.evidence).to have_attributes(pre_run_sha: "pre-sha", integration_base_sha: "base-sha", result_sha: "result-sha", provider_head_sha: "result-sha", status: "approved")
    expect(run.reload).to have_attributes(status: "failed", result_commit_sha: "result-sha")
  end

  it "records unavailable evidence and does not call the harness when the provider head is stale" do
    allow(client).to receive(:pull_request).and_return(OpenStruct.new(head: OpenStruct.new(sha: "new-head"), base:))
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result.evidence).to have_attributes(status: "unavailable", provider_head_sha: "new-head")
  end

  it "returns the same unavailable evidence for repeated stale-head requests" do
    stale_pr = OpenStruct.new(head: OpenStruct.new(sha: "new-head"), base:)
    allow(client).to receive(:pull_request).and_return(stale_pr)

    first = described_class.call(agent_run: run, requested_by: requester)
    second = described_class.call(agent_run: run, requested_by: requester)

    expect(second.evidence).to eq(first.evidence)
    expect(ConflictRepairScopeEvidence.where(agent_run: run, status: "unavailable").count).to eq(1)
  end

  it "returns the same unavailable evidence across repeated provider failures" do
    allow(client).to receive(:pull_request).and_raise(GithubClient::Error, "provider unavailable")

    first = described_class.call(agent_run: run, requested_by: requester)
    second = described_class.call(agent_run: run, requested_by: requester)

    expect(second.evidence).to eq(first.evidence)
    expect(ConflictRepairScopeEvidence.where(agent_run: run, status: "unavailable").count).to eq(1)
  end

  it "reassesses current-head unavailable evidence after the provider recovers" do
    unavailable = ConflictRepairScopeEvidence.create!(agent_run: run, account: project.account, project:, issue:, requested_by: requester,
      pre_run_sha: "pre-sha", integration_base_sha: "base-sha", result_sha: "result-sha", provider_head_sha: "result-sha",
      status: "unavailable", explanation: "provider unavailable", base_imported_paths: [], repair_authored_paths: [])
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "bounded repair", base_imported_paths: [], repair_authored_paths: []))

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result.evidence).to have_attributes(status: "approved", integration_base_sha: "base-sha")
    expect(result.evidence).not_to eq(unavailable)
  end

  it "publishes unavailable evidence when the provider base changes during assessment" do
    changed = OpenStruct.new(head:, base: OpenStruct.new(sha: "new-base"))
    allow(client).to receive(:pull_request).and_return(pr, changed)
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "bounded repair", base_imported_paths: [], repair_authored_paths: []))

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result.evidence).to have_attributes(status: "unavailable", integration_base_sha: "new-base")
  end

  it "preserves a rejected semantic decision" do
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "rejected", explanation: "Gemfile is unrelated", base_imported_paths: [], repair_authored_paths: [ "Gemfile" ]))

    expect(described_class.call(agent_run: run, requested_by: requester).evidence).to have_attributes(status: "rejected", repair_authored_paths: [ "Gemfile" ])
  end

  it "refuses a non-failed producer without provider or harness I/O" do
    run.update!(status: "completed")
    expect(client).not_to receive(:pull_request)
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run, requested_by: requester)).to have_attributes(status: :refused, reason: "producer_is_not_an_immutable_failed_repair")
  end

  it "refuses a manual producer without provider or harness I/O" do
    run.update!(trigger_type: "manual")
    expect(client).not_to receive(:pull_request)
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run, requested_by: requester)).to have_attributes(status: :refused, reason: "producer_is_not_an_immutable_failed_repair")
  end

  it "refuses a missing or removed requester before provider or semantic I/O" do
    expect(client).not_to receive(:pull_request)
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run)).to have_attributes(status: :refused, reason: "requesting_actor_not_authorized")
  end

  it "does not reuse evidence when the integration base changes" do
    ConflictRepairScopeEvidence.create!(agent_run: run, account: project.account, project:, issue:, requested_by: requester,
      pre_run_sha: "pre-sha", integration_base_sha: "old-base", result_sha: "result-sha", provider_head_sha: "result-sha",
      status: "approved", explanation: "old base", base_imported_paths: [], repair_authored_paths: [])
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "new base", base_imported_paths: [], repair_authored_paths: []))

    result = described_class.call(agent_run: run, requested_by: requester)

    expect(result.evidence.integration_base_sha).to eq("base-sha")
  end

  it "refuses comparison work when the requester loses authorization during the head read" do
    allow(client).to receive(:pull_request) do
      requester.add_role(:viewer, project.account)
      expect(AgentRunPolicy.new(requester.reload, run).retry?).to be(false)
      pr
    end
    expect(client).not_to receive(:compare_summary)
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run, requested_by: requester))
      .to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to be_empty
  end

  it "refuses further provider and semantic work after revocation during comparison" do
    expect(client).to receive(:compare_summary).once do
      requester.add_role(:viewer, project.account)
      expect(AgentRunPolicy.new(requester.reload, run).retry?).to be(false)
      { files: [] }
    end
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run, requested_by: requester))
      .to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to be_empty
  end

  it "refuses publication when the requester loses authorization during semantic assessment" do
    allow(ConflictRepairs::AssessScope).to receive(:call) do
      requester.add_role(:viewer, project.account)
      expect(AgentRunPolicy.new(requester.reload, run).retry?).to be(false)
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "bounded repair", base_imported_paths: [], repair_authored_paths: [])
    end

    expect(described_class.call(agent_run: run, requested_by: requester))
      .to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to be_empty
    expect(run.reload).to have_attributes(status: "failed", result_commit_sha: "result-sha")
  end

  it "refuses publication when the requester loses authorization during the final provider read" do
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "approved", explanation: "bounded repair", base_imported_paths: [], repair_authored_paths: []))
    reads = 0
    allow(client).to receive(:pull_request) do
      reads += 1
      requester.add_role(:viewer, project.account) if reads == 2
      pr
    end

    expect(described_class.call(agent_run: run, requested_by: requester))
      .to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to be_empty
  end

  it "does not record an unavailable outcome for a requester revoked during failed provider work" do
    allow(client).to receive(:pull_request) do
      requester.add_role(:viewer, project.account)
      raise GithubClient::Error, "provider unavailable"
    end

    expect(described_class.call(agent_run: run, requested_by: requester))
      .to have_attributes(status: :refused, reason: "requesting_actor_not_authorized", evidence: nil)
    expect(ConflictRepairScopeEvidence.where(agent_run: run)).to be_empty
  end
end
