# frozen_string_literal: true

require "rails_helper"

# @spec MANUAL-RUN-RETRY-001 MANUAL-RUN-RETRY-005
RSpec.describe RetryFailedManualRunJob do
  let(:project) { create(:project) }

  describe ".retry_delay" do
    it "doubles the base delay per attempt, bounded by the max delay" do
      expect(described_class.retry_delay(1)).to eq(30.seconds)
      expect(described_class.retry_delay(2)).to eq(1.minute)
      expect(described_class.retry_delay(3)).to eq(2.minutes)
      expect(described_class.retry_delay(10)).to eq(5.minutes)
    end
  end

  describe "#perform" do
    it "mints a new queued run, marks the original retried, and re-queues processing" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, project: project, goal: "create_pr")

      expect {
        described_class.new.perform(original.id, 1)
      }.to change(AgentRun, :count).by(1)
        .and have_enqueued_job(ProcessRunQueueJob)

      expect(original.reload.status).to eq("retried")

      new_run = AgentRun.order(:id).last
      expect(new_run.project).to eq(project)
      expect(new_run.goal).to eq("create_pr")
      expect(new_run.custom_prompt).to eq(original.custom_prompt)
      expect(new_run.trigger_type).to eq("manual")
      expect(new_run.status).to eq("queued")
      expect(new_run.external_metadata[AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY]).to eq(1)
      expect(new_run.external_metadata[AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY]).to eq(original.id)
    end

    it "carries forward external_metadata needed by the goal (e.g. create_feature's feature_brief)" do
      original = create(:agent_run, :failed, :manual, :create_feature_goal, project: project, issue: nil,
        external_metadata: { "feature_brief" => { "summary" => "Add dark mode" } })

      described_class.new.perform(original.id, 1)

      new_run = AgentRun.order(:id).last
      expect(new_run.external_metadata["feature_brief"]).to eq({ "summary" => "Add dark mode" })
    end

    it "preserves plan_doc_source when a lid_planning run failed before its prompt was persisted" do
      # Pre-prompt failure shape: ProjectsController#start_lid queues a
      # lid_planning run with plan_doc_source and a blank custom_prompt; the
      # prompt is only persisted later by CreateAgentRunActivity's
      # ensure_lid_planning_prompt!. If the workflow fails before that point
      # (e.g. runner validation), the retry must still carry the
      # operator-selected design document so it plans the same work.
      original = create(:agent_run, :failed, :manual, :lid_planning_goal, project: project, issue: nil,
        plan_doc_source: "docs/rdrs/RDR-051-lid-aware-agent-runs.md", custom_prompt: nil)

      described_class.new.perform(original.id, 1)

      new_run = AgentRun.order(:id).last
      expect(new_run.plan_doc_source).to eq("docs/rdrs/RDR-051-lid-aware-agent-runs.md")
      expect(new_run.custom_prompt).to be_nil
    end

    it "does nothing when the run no longer exists" do
      expect {
        described_class.new.perform(-1, 1)
      }.not_to change(AgentRun, :count)
    end

    it "does nothing when the run is no longer eligible (e.g. already retried)" do
      original = create(:agent_run, :retried, :manual, :with_custom_prompt, project: project, goal: "create_pr")

      expect {
        described_class.new.perform(original.id, 1)
      }.not_to change(AgentRun, :count)
    end

    it "does nothing when the project toggle has since been disabled" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, project: project, goal: "create_pr")
      project.update!(retry_failed_manual_runs: false)

      expect {
        described_class.new.perform(original.id, 1)
      }.not_to change(AgentRun, :count)

      expect(original.reload.status).to eq("failed")
    end

    it "does nothing when the attempt exceeds the retry cap" do
      original = create(:agent_run, :failed, :manual, :with_custom_prompt, project: project, goal: "create_pr")

      expect {
        described_class.new.perform(original.id, AgentRun::MAX_MANUAL_RETRY_ATTEMPTS + 1)
      }.not_to change(AgentRun, :count)

      expect(original.reload.status).to eq("failed")
    end
  end
end
