# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatInvestigations::RunJob do
  include_context "without qdrant vector search"

  # @spec QUESTION-EXPLORATION-010
  it "uses the low-priority queue with a bounded execution time" do
    expect(described_class.queue_name).to eq("low_priority")
    expect(described_class.perform_timeout).to eq(15.minutes)
  end

  # @spec QUESTION-EXPLORATION-010
  it "resolves the investigation account for tenant isolation" do
    investigation = create(:chat_investigation)

    expect(described_class.new(investigation.id).send(:tenant_account)).to eq(investigation.account)
  end

  # @spec QUESTION-EXPLORATION-010 QUESTION-EXPLORATION-013
  it "publishes a reconnectable result and settles its reservation" do
    investigation = create(:chat_investigation, reserved_cost_cents: 10)
    # The default factory creates the author as a second account user who never
    # receives the auto-assigned owner role, so grant an explicit project role
    # to satisfy the queued-side-effect recheck.
    investigation.created_by.add_role(:project_member, investigation.project)
    project_version = create(:project_version, project: investigation.project)
    collector_run = create(:collector_run, project_version:, collector_type: "routes")
    artifact = create(:knowledge_artifact, project: investigation.project, collector_run:,
      identifier: investigation.prompt, content: "Repository evidence")
    create(:knowledge_chunk, project: investigation.project, knowledge_artifact: artifact,
      content: "Repository evidence")

    described_class.perform_now(investigation.id)

    expect(investigation.reload).to have_attributes(status: "completed", reserved_cost_cents: 0)
    expect(investigation.result).to start_with("Knowledge-base search results for this question:")
    expect(investigation.result).to include("Repository evidence")
  end

  it "does not execute queued work after execution is disabled" do
    investigation = create(:chat_investigation, reserved_cost_cents: 10)
    investigation.created_by.add_role(:project_member, investigation.project)
    create(:execution_control, :enabled, scope: "project", project: investigation.project)

    described_class.perform_now(investigation.id)

    expect(investigation.reload).to have_attributes(status: "awaiting_authorization", reserved_cost_cents: 0)
  end

  # @spec QUESTION-EXPLORATION-007
  it "does not execute queued work after the originating collaborator loses project access" do
    investigation = create(:chat_investigation, reserved_cost_cents: 10)
    investigation.created_by.add_role(:project_member, investigation.project)

    # Drop the original author's project membership after they queued the work
    # so the run job recheck sees them as unauthorized.
    investigation.created_by.remove_role(:project_member, investigation.project)

    described_class.perform_now(investigation.id)

    expect(investigation.reload).to have_attributes(
      status: "awaiting_authorization",
      reserved_cost_cents: 0
    )
    expect(investigation.metadata["authorization_required"]).to match(/no longer has access/i)
  end
end
