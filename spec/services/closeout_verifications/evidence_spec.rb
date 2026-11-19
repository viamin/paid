# frozen_string_literal: true

require "rails_helper"

RSpec.describe CloseoutVerifications::Evidence do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:source_issue) { create(:issue, project:, body: "## Acceptance\n- Merged evidence") }
  let(:source_pr) { create(:issue, :pull_request, project:, github_number: 42, pr_review_phase: "merged", merged_commit_sha: "a" * 40) }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:criteria) { [ "Merged evidence" ] }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "release_deployment" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
  end

  def persist_assessment!(issue: source_issue, criterion_keys: criteria)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => criterion_keys.map { |key| { "criterion" => key, "state" => "unmet" } }, "gaps" => []
    } })
  end

  def approve_mapping(issue: source_issue, criterion_key: "Merged evidence")
    StagedCloseoutAdoption::Mappings.approve(project:, actor: maintainer, issue:, attributes: {
      criterion_key:, stage: "merged_revision", phase: "release_deployment",
      target_shape: "source_pr_merged_revision", execution_path: "technical_prerequisite",
      target_key: recipe.id, freshness_seconds: 60
    })
  end

  def create_verification_run(mapping:, pr: source_pr, merged_sha: pr.merged_commit_sha, outcome: "passed",
    status: nil, error: nil, issue: source_issue)
    status ||= outcome == "cancelled" ? "cancelled" : (outcome == "passed" ? "completed" : "failed")
    create(:agent_run, project:, issue:, agent_type: "internal_agent", goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL,
      synthetic: true, status:, completed_at: Time.current,
      source_pull_request_number: pr.github_number, base_commit_sha: merged_sha,
      closeout_mapping_id: mapping.id, closeout_criterion_key: mapping.criterion_key,
      closeout_recipe_version: mapping.target_version, closeout_recipe_digest: mapping.target_digest,
      verification_result: { "closeout_verification" => {
        "source_issue_id" => issue.id, "criterion" => mapping.criterion_key,
        "source_pr_number" => pr.github_number, "merged_commit_sha" => merged_sha,
        "recipe_version" => mapping.target_version, "recipe_digest" => mapping.target_digest,
        "mapping_id" => mapping.id, "outcome" => outcome, "recorded_at" => Time.current.iso8601,
        "error" => error
      }.compact })
  end

  it "includes a passing terminal record keyed by criterion, PR, target SHA, and recipe version" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")

    record = described_class.records_for(source_issue).first

    expect(record).to include("criterion_key" => "Merged evidence", "pr_number" => 42,
      "target_sha" => "a" * 40, "recipe_version" => mapping.target_version,
      "outcome" => "passed", "current" => true, "stale_reasons" => [])
  end

  it "includes a failed record visibly without ever marking it satisfied" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "failed", error: "command exited 1")

    record = described_class.records_for(source_issue).first

    expect(record).to include("outcome" => "failed", "error" => "command exited 1", "current" => true)
    expect(record.keys).not_to include("satisfied")
  end

  it "includes an unavailable record visibly without treating it as satisfied" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "unavailable")

    record = described_class.records_for(source_issue).first

    expect(record).to include("outcome" => "unavailable", "current" => true)
  end

  it "excludes a non-terminal (running) record" do
    persist_assessment!
    mapping = approve_mapping
    run = create_verification_run(mapping:, outcome: "passed")
    run.update_columns(status: "running", completed_at: nil)

    expect(described_class.records_for(source_issue)).to be_empty
  end

  it "does not leak a record scoped to a different issue" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")
    other_issue = create(:issue, project:)

    expect(described_class.records_for(other_issue)).to be_empty
  end

  it "keys distinct records by criterion when multiple mappings cover the same issue" do
    persist_assessment!(criterion_keys: %w[Merged\ evidence Second\ check])
    first_mapping = approve_mapping(criterion_key: "Merged evidence")
    second_mapping = approve_mapping(criterion_key: "Second check")
    create_verification_run(mapping: first_mapping, outcome: "passed")
    create_verification_run(mapping: second_mapping, outcome: "failed")

    records = described_class.records_for(source_issue)

    expect(records.map { |record| record["criterion_key"] }).to contain_exactly("Merged evidence", "Second check")
  end

  it "marks a record stale when the pinned mapping has since been revoked" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")
    StagedCloseoutAdoption::Mappings.revoke(mapping:, project:, actor: maintainer, issue: source_issue, attributes: {})

    record = described_class.records_for(source_issue).first

    expect(record).to include("current" => false, "stale_reasons" => [ "mapping_revoked" ])
  end

  it "marks a record stale when the source PR's authoritative merge target has since changed" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed", merged_sha: "a" * 40)
    source_pr.update!(merged_commit_sha: "b" * 40)

    record = described_class.records_for(source_issue).first

    expect(record).to include("current" => false, "stale_reasons" => [ "target_changed" ])
  end

  it "marks a record stale when the issue's approved intent has since changed" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")
    source_issue.update!(body: "## Acceptance\n- Merged evidence\n- A new criterion")

    record = described_class.records_for(source_issue).first

    expect(record).to include("current" => false, "stale_reasons" => [ "intent_changed" ])
  end

  it "bounds the number of records returned per issue" do
    criterion_keys = (1..9).map { |n| "Criterion #{n}" }
    persist_assessment!(criterion_keys:)
    # Every mapping is reviewed against the still-fresh assessment before any
    # verification evidence exists; once the first terminal result is
    # recorded it joins the source revision and would otherwise stale out a
    # not-yet-approved later mapping (the same guard #approve always enforced).
    mappings = criterion_keys.map { |key| approve_mapping(criterion_key: key) }
    mappings.each { |mapping| create_verification_run(mapping:, outcome: "passed") }

    expect(described_class.records_for(source_issue).size).to eq(described_class::MAX_RECORDS)
  end

  it "produces a stable revision across replayed reads regardless of the recorded timestamp" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:, outcome: "passed")

    first = described_class.revision_for(source_issue)
    travel 5.minutes do
      second = described_class.revision_for(source_issue, records: described_class.records_for(source_issue))
      expect(second).to eq(first)
    end
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "keeps failed terminal retries visible after a later retry passes" do
    persist_assessment!
    mapping = approve_mapping
    failed_run = create_verification_run(mapping:, outcome: "failed", merged_sha: "a" * 40)
    before_revision = described_class.revision_for(source_issue)

    passed_run = create_verification_run(mapping:, outcome: "passed", merged_sha: "b" * 40)

    expect(described_class.revision_for(source_issue)).not_to eq(before_revision)
    expect(described_class.records_for(source_issue)).to contain_exactly(
      include("verification_run_id" => failed_run.id, "outcome" => "failed", "target_sha" => "a" * 40),
      include("verification_run_id" => passed_run.id, "outcome" => "passed", "target_sha" => "b" * 40)
    )
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "marks an unavailable authoritative merge target stale" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:)
    source_pr.update!(merged_commit_sha: nil)

    expect(described_class.records_for(source_issue).first).to include("current" => false)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "revalidates the actual recipe instead of comparing two old snapshots" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:)
    recipe.update!(command: "bin/replaced-check")

    expect(described_class.records_for(source_issue).first).to include("current" => false)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "rejects a criterion that does not match the reviewed mapping" do
    persist_assessment!
    mapping = approve_mapping
    create_verification_run(mapping:).update_column(:closeout_criterion_key, "Other criterion")

    expect(described_class.records_for(source_issue).first).to include("current" => false)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "includes primary run provenance and bounded command results" do
    persist_assessment!
    mapping = approve_mapping
    run = create_verification_run(mapping:)
    receipt = run.verification_result.fetch("closeout_verification").merge(
      "command" => "bin/reviewed-check", "technical_evidence" => {
        "native" => { "stdout" => "Verified fixture", "stderr" => "", "exit_code" => 0 },
        "cleanup" => { "completed" => true }
      })
    run.update!(verification_result: { "closeout_verification" => receipt })

    record = described_class.records_for(source_issue).first

    expect(record).to include("verification_run_id" => run.id, "command" => "bin/reviewed-check")
    expect(record.fetch("native")).to include("exit_code" => 0, "stdout" => "Verified fixture")
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "changes the revision when an omitted criterion loses its reviewed mapping" do
    stub_const("#{described_class}::MAX_RECORDS", 1)
    persist_assessment!(criterion_keys: [ "Merged evidence", "Second check" ])
    mappings = [ "Merged evidence", "Second check" ].map { |key| approve_mapping(criterion_key: key) }
    mappings.each { |mapping| create_verification_run(mapping:) }
    before_revision = described_class.revision_for(source_issue)
    StagedCloseoutAdoption::Mappings.revoke(mapping: mappings.first, project:, actor: maintainer,
      issue: source_issue, attributes: {})

    expect(described_class.revision_for(source_issue)).not_to eq(before_revision)
  end

  # @spec PARTIAL-CLOSEOUT-057
  it "retains a newly superseding result when its criterion was previously capped" do
    criterion_keys = (1..9).map { |n| "Criterion #{n}" }
    persist_assessment!(criterion_keys:)
    mappings = criterion_keys.map { |key| approve_mapping(criterion_key: key) }
    mappings.each { |mapping| create_verification_run(mapping:, outcome: "passed") }
    before_revision = described_class.revision_for(source_issue)

    source_pr.update!(merged_commit_sha: "b" * 40)
    replay = create_verification_run(mapping: mappings.first, merged_sha: source_pr.merged_commit_sha,
      outcome: "failed", error: "new terminal result")

    records = described_class.records_for(source_issue)
    expect(records.map { |record| record["criterion_key"] }).to eq(criterion_keys.drop(2) + [ criterion_keys.first ])
    expect(described_class.current_for_run?(replay)).to be(true)
    expect(records.last).to include("verification_run_id" => replay.id, "outcome" => "failed", "error" => "new terminal result", "current" => true)
    expect(described_class.revision_for(source_issue, records:)).not_to eq(before_revision)
  end

  %w[failed unavailable cancelled passed].each do |prior_outcome|
    # @spec PARTIAL-CLOSEOUT-057
    it "retains a superseded #{prior_outcome} terminal record as stale history" do
      persist_assessment!
      mapping = approve_mapping
      prior = create_verification_run(mapping:, outcome: prior_outcome)
      source_pr.update!(merged_commit_sha: "b" * 40)
      latest = create_verification_run(mapping:, outcome: prior_outcome == "passed" ? "failed" : "passed")

      records = described_class.records_for(source_issue)

      expect(records.size).to eq(2)
      expect(records.first).to include("verification_run_id" => prior.id, "outcome" => prior_outcome, "current" => false)
      expect(records.first.fetch("stale_reasons")).to include("superseded_result")
      expect(records.last).to include("verification_run_id" => latest.id, "current" => true)
      expect(described_class.current_for_run?(prior)).to be(false)
    end
  end
end
