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

  context "when a criterion also requires human authorization" do
    let(:native_requirement) do
      create(:pre_commit_requirement, project:, account: project.account, check_type: "shell_command", command: "bin/check")
    end
    let(:mixed_criterion) do
      {
        "criterion" => "Representative staging environment is approved", "state" => "unmet",
        "prerequisite_kind" => "human", "validation_kind" => "native", "validation_requirement_id" => native_requirement.id
      }
    end
    let(:assessment) { instance_double(PartialCloseouts::Assessment::Result, stale?: false, criteria: [ mixed_criterion ]) }

    def publish_authorization_notification!(sufficient:)
      revision = PartialCloseouts::Assessment.source_revision_for(source_run.issue)
      occurrence = { "identity" => "auth-1", "criterion" => mixed_criterion.fetch("criterion"), "kind" => "human",
        "workflow" => TechnicalPrerequisites::AUTHORIZATION_WORKFLOW, "source_revision" => revision }
      submissions = sufficient ? [ { "prerequisite_identity" => "auth-1", "source_revision" => revision, "outcome" => "sufficient" } ] : []
      create(:notification, :error, account: project.account, subject: source_run.issue,
        source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE, blocking: true,
        title: "Approve the representative environment", description: "Approve it before Paid measures it.",
        metadata: { "prerequisites" => [ occurrence ], "evidence_submissions" => submissions })
    end

    # @spec PARTIAL-CLOSEOUT-048
    it "offers the run action when no authorization is required" do
      action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

      expect(action).to be_ready
    end

    # @spec PARTIAL-CLOSEOUT-048
    it "withholds the run action while operator authorization is pending" do
      publish_authorization_notification!(sufficient: false)

      action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

      expect(action).not_to be_ready
      expect(action.setup_action).to eq(
        "Awaiting operator authorization of this prerequisite; the validation run becomes available once it is approved."
      )
    end

    # @spec PARTIAL-CLOSEOUT-048
    it "offers the run action once operator authorization is sufficient" do
      publish_authorization_notification!(sufficient: true)

      action = described_class.call(project:, actor: project.created_by, assessment:, source_run:).sole

      expect(action).to be_ready
    end
  end
end
