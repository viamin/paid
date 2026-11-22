# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-010
RSpec.describe PullRequests::ConflictRepairScopeGate do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 42) }
  let(:head_sha) { "abc123" }

  def record_repair(status:, head: head_sha, assessment: nil)
    create(:agent_run, :automatic, :failed,
      project:, issue:, goal: "create_pr", focus: "merge_conflict",
      source_pull_request_number: issue.github_number, result_commit_sha: head,
      external_metadata: assessment || {
        "conflict_repair_scope_assessment" => {
          "status" => status,
          "explanation" => "Scope #{status}",
          "base_sha" => "pre-repair",
          "head_sha" => head,
          "base_imported_paths" => [ "app/base.rb" ],
          "repair_authored_paths" => [ "app/repair.rb" ]
        }
      })
  end

  it "allows an ordinary PR with no automatic conflict repair" do
    expect(described_class.call(project:, issue:, head_sha:)).to be_allowed
  end

  it "blocks unavailable, rejected, and incomplete current-head assessments" do
    %w[unavailable rejected].each do |status|
      record_repair(status:)
      expect(described_class.call(project:, issue:, head_sha:)).not_to be_allowed
      AgentRun.delete_all
    end

    record_repair(status: "approved", assessment: { "conflict_repair_scope_assessment" => { "status" => "approved" } })
    expect(described_class.call(project:, issue:, head_sha:)).not_to be_allowed
  end

  it "allows complete approved evidence and ignores a superseded head" do
    record_repair(status: "approved")
    expect(described_class.call(project:, issue:, head_sha:)).to be_allowed

    expect(described_class.call(project:, issue:, head_sha: "new-head")).to be_allowed
  end
end
