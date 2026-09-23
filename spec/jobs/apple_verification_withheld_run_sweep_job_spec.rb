# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationWithheldRunSweepJob do
  # @spec APPLE-ATTEMPT-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def approved_required_revision
    create(
      :apple_verification_workflow_revision,
      :approved,
      project:,
      lifecycle_gate: "completion_verification",
      required_checks: %w[ios-app.tests],
      advisory_checks: []
    )
  end

  # The approved revision must exist before `complete!` runs, or the gate
  # evaluates `not_required` and the run completes without being withheld.
  def withheld_agent_run(revision, shipped_commit: "a" * 40)
    agent_run = create(:agent_run, :running, project:)
    result = agent_run.complete!(
      result_commit: shipped_commit,
      pr_url: "https://github.com/example/pull/7",
      pr_number: 7
    )
    expect(result).to be_falsey
    agent_run.reload
    expect(agent_run.status).to eq("running")
    expect(agent_run.external_metadata).to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
    agent_run
  end

  def attempt_for(revision, agent_run:, status:, commit_sha:, failure_classification: nil, retry_number: 0)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status:,
      failure_classification:,
      commit_sha:,
      retry_number:
    )
  end

  describe "#perform" do
    it "invokes CompleteWithheldRun under system access for every withheld run" do
      shipped = "a" * 40
      revision = approved_required_revision
      withheld_runs = Array.new(2) { withheld_agent_run(revision, shipped_commit: shipped) }
      withheld_runs.each do |run|
        attempt_for(revision, agent_run: run, status: "succeeded", commit_sha: shipped)
      end

      in_system_access = false
      allow(TenantContext).to receive(:with_system_access) do |&block|
        in_system_access = true
        block.call
      end

      described_class.new.perform

      expect(in_system_access).to be(true)
      withheld_runs.each do |run|
        run.reload
        expect(run.status).to eq("completed")
        expect(run.external_metadata).not_to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
      end
    end

    it "completes a withheld run once a matching succeeded attempt is recorded" do
      shipped = "a" * 40
      revision = approved_required_revision
      agent_run = withheld_agent_run(revision, shipped_commit: shipped)
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: shipped)

      described_class.new.perform

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.result_commit_sha).to eq(shipped)
    end

    it "does not complete a withheld run whose latest succeeded attempt does not match the shipped commit" do
      shipped = "a" * 40
      revision = approved_required_revision
      agent_run = withheld_agent_run(revision, shipped_commit: shipped)
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: "b" * 40)

      described_class.new.perform

      agent_run.reload
      expect(agent_run.status).to eq("running")
      expect(AgentRun.awaiting_completion_verification).to contain_exactly(agent_run)
    end

    it "completes a withheld run once the gate relaxes via the project mode being set to off" do
      shipped = "a" * 40
      revision = approved_required_revision
      agent_run = withheld_agent_run(revision, shipped_commit: shipped)
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion", commit_sha: shipped)

      # Waive would block on a failed attempt without an active waiver, but
      # moving the project to `off` makes the gate `not_required`, so the
      # withheld completion must be re-driven by the sweep.
      project.update!(apple_verification_mode: "off")

      described_class.new.perform

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.external_metadata).not_to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
    end

    it "does not emit the summary log when nothing was withheld" do
      create(:agent_run, :running, project:)

      logger = instance_double(ActiveSupport::Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      expect(logger).not_to receive(:info)

      described_class.new.perform
    end

    it "logs and continues when an individual run fails" do
      revision = approved_required_revision
      agent_run = withheld_agent_run(revision)
      allow(AppleVerificationAttempts::CompleteWithheldRun)
        .to receive(:call).with(agent_run: agent_run).and_raise(StandardError, "boom")

      logger = instance_double(ActiveSupport::Logger)
      allow(Rails).to receive(:logger).and_return(logger)
      expect(logger).to receive(:error).with(
        hash_including(
          message: "apple_verification_withheld_run_sweep.run_failed",
          agent_run_id: agent_run.id,
          project_id: project.id
        )
      )
      expect(logger).to receive(:info).with(
        hash_including(
          message: "apple_verification_withheld_run_sweep.completed",
          skipped: 1
        )
      )

      expect { described_class.new.perform }.not_to raise_error
    end
  end
end
