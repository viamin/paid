# frozen_string_literal: true

require "rails_helper"

RSpec.describe LiveTargetCloseoutVerificationSweepJob do
  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    ENV["PAID_DEPLOYED_REVISION"] = "fixture-current-live-target"
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  def reviewed_project(criteria: [ "Live evidence" ])
    project = create(:project)
    actor = create(:user, :owner, account: project.account)
    project.update!(created_by: actor)
    FeatureFlags.enable!(:automation_phases, project:)
    project.update!(automation_phase_settings: { "phases" => { "operations" => true } })
    StagedCloseoutAdoption::Enroll.call(project:, actor:, enabled: true)
    issue = create(:issue, project:)
    create(:agent_run, :completed, project:, issue:, goal: "analyze_issue",
      pull_request_number: nil, pull_request_url: nil, reconciliation: { "assessment" => {
        "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
        "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
        "criteria" => criteria.map { |criterion| { "criterion" => criterion, "state" => "unmet" } }, "gaps" => []
      } })
    mappings = criteria.map do |criterion|
      StagedCloseoutAdoption::Mappings.approve(project:, actor:, issue:, attributes: {
        criterion_key: criterion, stage: "live_environment", phase: "operations", target_shape: "live_signal",
        execution_path: "trusted_measurement", target_key: "agent_planning_hold_reconciliation_closed_count",
        environment_class: Rails.env.to_s, freshness_seconds: 60
      })
    end
    [ project, mappings ]
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "automatically admits reviewed mappings across active projects and deduplicates replay" do
    first, = reviewed_project
    second, = reviewed_project

    described_class.perform_now
    described_class.perform_now

    runs = AgentRun.where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL)
    expect(runs.pluck(:project_id)).to contain_exactly(first.id, second.id)
    expect(runs.pluck(:closeout_target_revision).uniq).to eq([ "fixture-current-live-target" ])
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "does not fabricate admission without an environment signal" do
    reviewed_project
    ENV.delete("PAID_DEPLOYED_REVISION")

    described_class.perform_now

    expect(AgentRun.where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL)).to be_empty
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  it "bounds mapping work within a project and resumes at the mapping cursor" do
    stub_const("LiveTargetCloseoutVerificationSweepJob::MAPPING_BATCH_SIZE", 1)
    project, mappings = reviewed_project(criteria: [ "First live check", "Second live check" ])

    expect { described_class.perform_now(project_id: project.id) }
      .to have_enqueued_job(described_class).with(project_id: project.id, after_mapping_id: mappings.first.id)
    expect(AgentRun.where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL).count).to eq(1)

    described_class.perform_now(project_id: project.id, after_mapping_id: mappings.first.id)

    expect(AgentRun.where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL).pluck(:closeout_mapping_id))
      .to match_array(mappings.map(&:id))
  end
end
