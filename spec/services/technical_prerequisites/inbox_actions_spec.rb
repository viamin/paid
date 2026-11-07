# frozen_string_literal: true

require "rails_helper"

RSpec.describe TechnicalPrerequisites::InboxActions do
  let(:project) { create(:project) }
  let(:source_run) { create(:agent_run, :completed, project:, base_commit_sha: "a" * 40, result_commit_sha: "c" * 40) }
  let(:criterion) do
    {
      "criterion" => "Inbox response time", "state" => "unmet", "validation_kind" => "performance_measurement",
      "validation_requirement_id" => requirement.id
    }
  end
  let(:assessment) { instance_double(PartialCloseouts::Assessment::Result, stale?: false, criteria: [ criterion ]) }
  let(:requirement) do
    create(:pre_commit_requirement, project:, account: project.account, check_type: "performance_measurement",
      measurement_recipe: { "samples" => 3 })
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "holds an incomplete performance recipe instead of offering a run" do
    action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

    expect(action).not_to be_ready
    expect(action.setup_action).to eq("Configure a complete representative performance recipe for this criterion.")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "explains when a performance measurement source run has no produced revision" do
    source_run.update!(result_commit_sha: nil)

    action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

    expect(action).not_to be_ready
    expect(action.setup_action).to eq("Select an implementation run with a produced revision before validating this criterion.")
  end

  # @spec PARTIAL-CLOSEOUT-042
  it "offers a reviewed browser-visible performance recipe" do
    requirement.update!(measurement_recipe: {
      "baseline_commit_sha" => "b" * 40,
      "workload" => { "identity" => "browser-chat", "provenance" => "reviewed fixture v1", "representative" => true },
      "metrics" => [ "wall_ms" ], "samples" => 3, "environment" => "browser-visible",
      "budget_seconds" => 60, "artifact_contract" => [ "raw_samples", "comparison" ],
      "requires_browser" => true
    })

    action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

    expect(action).to be_ready
    expect(action.setup_action).to be_nil
  end
end
