# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::AuditEvidence do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:, body: "## Acceptance\n- Merged evidence") }
  let(:source_pr) do
    create(:issue, :pull_request, project:, github_number: 42, parent_issue: issue,
      pr_review_phase: "merged", merged_commit_sha: "a" * 40)
  end
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:agent_run) { create(:agent_run, :completed, project:, issue:) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
  end

  def persist_assessment!(criterion_keys: [ "Merged evidence" ])
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => criterion_keys.map { |key| { "criterion" => key, "state" => "unmet" } }, "gaps" => []
    } })
  end

  def approve_mapping(criterion_key: "Merged evidence")
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key:, stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
  end

  def create_verification_run(mapping:, outcome: "passed")
    status = outcome == "passed" ? "completed" : "failed"
    create(:agent_run, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, status:, completed_at: Time.current,
      source_pull_request_number: source_pr.github_number, base_commit_sha: source_pr.merged_commit_sha,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest,
      verification_result: { "closeout_verification" => {
        "source_issue_id" => issue.id, "criterion" => mapping.criterion_key,
        "source_pr_number" => source_pr.github_number, "merged_commit_sha" => source_pr.merged_commit_sha,
        "recipe_version" => mapping.target_version, "recipe_digest" => mapping.target_digest,
        "mapping_id" => mapping.id, "outcome" => outcome, "recorded_at" => Time.current.iso8601
      } })
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "includes matching terminal closeout_verification evidence in the bounded audit packet" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")

    packet = JSON.parse(described_class.call(issue:, agent_run:))

    expect(packet.fetch("closeout_verifications")).to contain_exactly(
      hash_including("criterion_key" => "Merged evidence", "pr_number" => 42, "outcome" => "passed", "current" => true)
    )
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "keeps a failed closeout_verification result visible without representing it as satisfied" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "failed")

    packet = JSON.parse(described_class.call(issue:, agent_run:))
    record = packet.fetch("closeout_verifications").first

    expect(record).to include("outcome" => "failed")
    expect(record.keys).not_to include("satisfied")
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "changes the audit's source revision when new closeout_verification evidence appears" do
    persist_assessment!
    revision_before = described_class.new(issue:, agent_run:).tap(&:call).source_revision

    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")

    revision_after = described_class.new(issue:, agent_run:).tap(&:call).source_revision

    expect(revision_after).not_to eq(revision_before)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "does not include a closeout_verification record scoped to a different issue" do
    persist_assessment!
    create_other_issue_verification!

    packet = JSON.parse(described_class.call(issue:, agent_run:))

    expect(packet.fetch("closeout_verifications")).to be_empty
  end

  def create_other_issue_verification!
    other_issue = create(:issue, project:, body: "## Acceptance\n- Merged evidence")
    other_pr = create(:issue, :pull_request, project:, github_number: 43, parent_issue: other_issue,
      pr_review_phase: "merged", merged_commit_sha: "b" * 40)
    create(:agent_run, :completed, project:, issue: other_issue, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(other_issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(other_issue),
      "criteria" => [ { "criterion" => "Merged evidence", "state" => "unmet" } ], "gaps" => []
    } })
    other_mapping = StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue: other_issue, attributes: {
      criterion_key: "Merged evidence", stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
    create(:agent_run, project:, issue: other_issue, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, status: "completed", completed_at: Time.current,
      source_pull_request_number: other_pr.github_number, base_commit_sha: other_pr.merged_commit_sha,
      closeout_mapping_id: other_mapping.id, closeout_criterion_key: other_mapping.criterion_key,
      closeout_recipe_version: other_mapping.target_version, closeout_recipe_digest: other_mapping.target_digest,
      verification_result: { "closeout_verification" => { "outcome" => "passed" } })
  end
  # @spec PARTIAL-CLOSEOUT-057
  it "marks the audit input incomplete when verification records are omitted" do
    stub_const("CloseoutVerifications::Evidence::MAX_RECORDS", 1)
    persist_assessment!(criterion_keys: [ "Merged evidence", "Second check" ])
    mappings = [ "Merged evidence", "Second check" ].map { |key| approve_mapping(criterion_key: key) }
    mappings.each { |mapping| create_verification_run(mapping:) }
    builder = described_class.new(issue:, agent_run:)
    packet = JSON.parse(builder.call)

    expect(packet.fetch("closeout_verifications").size).to be <= 1
    expect(builder.coverage).to include("complete" => false)
    expect(builder.coverage.fetch("reasons")).to include("closeout_verification_records_omitted")
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "marks the audit input incomplete when primary verification output is truncated" do
    persist_assessment!
    mapping = approve_mapping
    run = create_verification_run(mapping:)
    receipt = run.verification_result.fetch("closeout_verification").merge("technical_evidence" => {
      "native" => { "stdout" => "x" * 30_000, "exit_code" => 0 }
    })
    run.update!(verification_result: { "closeout_verification" => receipt })
    builder = described_class.new(issue:, agent_run:)
    packet = JSON.parse(builder.call)

    expect(packet.fetch("closeout_verifications").first.dig("native", "stdout").bytesize).to be <= 2_000
    expect(builder.coverage).to include("complete" => false)
  end
end
