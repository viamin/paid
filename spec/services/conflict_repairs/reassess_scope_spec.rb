# frozen_string_literal: true

require "ostruct"
require "rails_helper"

# @spec AUTO-MERGE-011
RSpec.describe ConflictRepairs::ReassessScope do
  let(:project) { create(:project) }
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

    result = described_class.call(agent_run: run)

    expect(result).to be_accepted
    expect(result.evidence).to have_attributes(pre_run_sha: "pre-sha", integration_base_sha: "base-sha", result_sha: "result-sha", provider_head_sha: "result-sha", status: "approved")
    expect(run.reload).to have_attributes(status: "failed", result_commit_sha: "result-sha")
  end

  it "records unavailable evidence and does not call the harness when the provider head is stale" do
    allow(client).to receive(:pull_request).and_return(OpenStruct.new(head: OpenStruct.new(sha: "new-head"), base:))
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    result = described_class.call(agent_run: run)

    expect(result.evidence).to have_attributes(status: "unavailable", provider_head_sha: "new-head")
  end

  it "preserves a rejected semantic decision" do
    allow(ConflictRepairs::AssessScope).to receive(:call).and_return(
      ConflictRepairs::AssessScope::Result.new(status: "rejected", explanation: "Gemfile is unrelated", base_imported_paths: [], repair_authored_paths: [ "Gemfile" ]))

    expect(described_class.call(agent_run: run).evidence).to have_attributes(status: "rejected", repair_authored_paths: [ "Gemfile" ])
  end

  it "refuses a non-failed producer without provider or harness I/O" do
    run.update!(status: "completed")
    expect(client).not_to receive(:pull_request)
    expect(ConflictRepairs::AssessScope).not_to receive(:call)

    expect(described_class.call(agent_run: run)).to have_attributes(status: :refused, reason: "producer_is_not_an_immutable_failed_repair")
  end
end
