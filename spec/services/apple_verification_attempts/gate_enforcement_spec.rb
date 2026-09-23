# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::GateEnforcement do
  # @spec APPLE-ATTEMPT-011
  # @spec APPLE-ATTEMPT-012
  # @spec APPLE-ATTEMPT-013
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def approved_required_revision(gate: "completion_verification")
    create(
      :apple_verification_workflow_revision,
      :approved,
      project:,
      lifecycle_gate: gate,
      required_checks: %w[ios-app.tests ios-app.initial-screen],
      advisory_checks: []
    )
  end

  def attempt_for(revision, agent_run:, status: "queued", failure_classification: nil, **extra)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status:,
      failure_classification:,
      **extra
    )
  end

  describe ".evaluate at the completion gate" do
    it "is not required without an approved workflow" do
      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
    end

    it "is not required when the approved revision carries no required checks" do
      revision = create(
        :apple_verification_workflow_revision,
        :approved,
        project:,
        lifecycle_gate: "completion_verification",
        required_checks: [],
        advisory_checks: %w[ios-app.tests]
      )

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
      expect(revision.required_checks).to be_empty
    end

    it "is pending when required verification has not run for the agent run" do
      approved_required_revision

      decision = described_class.evaluate(agent_run:, gate: "completion_verification")

      expect(decision.status).to eq(:pending)
      expect(decision.reason).to include("has not run")
    end

    it "is pending while the run's attempt is in flight" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "provisioning")

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:pending)
    end

    it "is satisfied when the run's attempt succeeded" do
      revision = approved_required_revision
      attempt = attempt_for(revision, agent_run:, status: "succeeded")

      decision = described_class.evaluate(agent_run:, gate: "completion_verification")

      expect(decision.status).to eq(:satisfied)
      expect(decision.attempt.id).to eq(attempt.id)
    end

    it "is satisfied when an unexpired waiver covers the run's failed attempt" do
      revision = approved_required_revision
      attempt = attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion")
      create(:apple_verification_waiver, apple_verification_attempt: attempt, expires_at: 1.hour.from_now)

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:satisfied)
    end

    it "does not satisfy from an expired waiver" do
      revision = approved_required_revision
      attempt = attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion")
      create(:apple_verification_waiver, apple_verification_attempt: attempt, expires_at: 1.hour.ago)

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:blocked)
    end

    it "is satisfied by a retry that succeeds after an earlier failure" do
      revision = approved_required_revision
      failed = attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion")
      attempt_for(revision, agent_run:, status: "succeeded", retry_of_attempt: failed, retry_number: 1)

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:satisfied)
    end

    it "ignores attempts bound to other agent runs" do
      revision = approved_required_revision
      other_run = create(:agent_run, :running, project:)
      attempt_for(revision, agent_run: other_run, status: "succeeded")

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:pending)
    end

    %w[capacity_or_quota worker_infrastructure cancellation_or_timeout].each do |classification|
      it "stays pending when the failure is infrastructure (#{classification})" do
        revision = approved_required_revision
        attempt_for(revision, agent_run:, status: "failed", failure_classification: classification)

        decision = described_class.evaluate(agent_run:, gate: "completion_verification")

        expect(decision.status).to eq(:pending)
      end
    end

    %w[cancelled timed_out unavailable].each do |terminal_status|
      it "stays pending when the attempt ended in #{terminal_status}" do
        revision = approved_required_revision
        attempt_for(revision, agent_run:, status: terminal_status)

        expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:pending)
      end
    end

    %w[project_configuration compile_or_link test_assertion launch_or_ui_flow required_capture network_policy unsupported_capability].each do |classification|
      it "blocks when a required check failed with #{classification}" do
        revision = approved_required_revision
        attempt_for(revision, agent_run:, status: "failed", failure_classification: classification)

        decision = described_class.evaluate(agent_run:, gate: "completion_verification")

        expect(decision.status).to eq(:blocked)
        expect(decision.attempt.failure_classification).to eq(classification)
      end
    end

    it "is not required when the rollout flag is disabled for the project" do
      approved_required_revision
      FeatureFlags.disable!(:apple_verification_workers, project:)

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
    end

    it "is not required when the project mode is off" do
      approved_required_revision
      project.update!(apple_verification_mode: "off")

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
    end

    it "enforces in automatic mode" do
      approved_required_revision
      project.update!(apple_verification_mode: "automatic")

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:pending)
    end
  end

  describe ".evaluate with result_commit binding" do
    let(:committed_sha) { "0123456789abcdef0123456789abcdef01234567" }
    let(:other_sha) { "abcdef0123456789abcdef0123456789abcdef01" }

    it "is satisfied only when an attempt's commit_sha matches result_commit" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: committed_sha)

      matching = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: committed_sha)
      mismatching = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: other_sha)

      expect(matching.status).to eq(:satisfied)
      expect(mismatching.status).to eq(:pending)
      expect(mismatching.reason).to include(committed_sha).and include(other_sha)
    end

    it "stays pending when a stale succeeded attempt cannot satisfy a different commit" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: committed_sha)

      decision = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: other_sha)

      expect(decision.status).to eq(:pending)
      expect(decision.attempt).to be_nil
    end

    it "stays pending when a committed attempt exists but the completion has no commit" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: committed_sha)

      decision = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: nil)

      expect(decision.status).to eq(:pending)
      expect(decision.reason).to include(committed_sha)
    end

    it "blocks when the matching commit's attempt is a non-waived code failure" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion", commit_sha: committed_sha)

      decision = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: committed_sha)

      expect(decision.status).to eq(:blocked)
      expect(decision.attempt.failure_classification).to eq("test_assertion")
    end

    it "ignores the latest committed attempt when it does not match result_commit" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion", commit_sha: committed_sha)
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: other_sha, retry_number: 1)

      decision = described_class.evaluate(agent_run:, gate: "completion_verification", result_commit: other_sha)

      expect(decision.status).to eq(:satisfied)
      expect(decision.attempt.commit_sha).to eq(other_sha)
    end
  end

  describe ".evaluate binding to approved committed revisions" do
    it "never enforces a draft revision even at an enforcement gate" do
      create(
        :apple_verification_workflow_revision,
        project:,
        lifecycle_gate: "completion_verification",
        required_checks: %w[ios-app.tests]
      )

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
    end

    it "never enforces an approved revision assigned to another gate" do
      approved_required_revision(gate: "agent_iteration")

      expect(described_class.evaluate(agent_run:, gate: "completion_verification").status).to eq(:not_required)
    end

    it "carries the approved revision binding on the decision" do
      revision = approved_required_revision

      decision = described_class.evaluate(agent_run:, gate: "completion_verification")

      expect(decision.revision.id).to eq(revision.id)
      expect(decision.revision.content_digest).to eq(revision.content_digest)
      expect(decision.gate).to eq("completion_verification")
    end
  end

  describe "completion enforcement on AgentRun#complete!" do
    it "blocks an agent run from reporting success while required verification is pending" do
      approved_required_revision

      expect(agent_run.complete!).to be_falsey
      expect(agent_run.reload.status).to eq("running")
    end

    it "records the withheld completion instead of failing the run while verification is pending" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "worker_infrastructure")

      expect(agent_run.complete!(pr_url: "https://github.com/example/pull/1")).to be_falsey

      expect(agent_run.reload.status).to eq("running")
      expect(agent_run.pull_request_url).to be_blank
      log = agent_run.agent_run_logs.system.last
      expect(log.content).to include("Completion withheld").and include("worker_infrastructure")
      expect(agent_run.external_metadata).to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
      expect(agent_run.external_metadata.fetch(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY))
        .to include("withheld_at", "pr_url" => "https://github.com/example/pull/1")
    end

    it "exempts the withheld run from stale-running recovery" do
      approved_required_revision
      agent_run.update_column(:started_at, AgentRun.stale_running_cutoff - 1.minute)

      expect(agent_run.complete!(pr_url: "https://github.com/example/pull/1")).to be_falsey

      expect(AgentRun.awaiting_completion_verification).to contain_exactly(agent_run)
      expect(AgentRun.stale_running).to be_empty
      expect(AgentRun.stale_running?(agent_run.reload)).to be(false)
    end

    it "clears the withheld marker when completion later succeeds" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "worker_infrastructure")
      expect(agent_run.complete!(pr_url: "https://github.com/example/pull/1")).to be_falsey
      expect(agent_run.reload.external_metadata).to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)

      attempt_for(revision, agent_run:, status: "succeeded", retry_number: 1)
      expect(agent_run.complete!(pr_url: "https://github.com/example/pull/1")).to be_truthy

      expect(agent_run.reload.status).to eq("completed")
      expect(agent_run.external_metadata).not_to have_key(AgentRun::COMPLETION_VERIFICATION_WITHHELD_METADATA_KEY)
    end

    it "blocks an agent run from reporting success when required checks failed" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion")

      expect { agent_run.complete! }.to raise_error(
        AppleVerificationAttempts::GateEnforcement::RequiredVerificationFailed,
        /test_assertion/
      )
      expect(agent_run.reload.status).to eq("running")
    end

    it "completes the run once required verification succeeds" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "succeeded")

      expect(agent_run.complete!(pr_url: "https://github.com/example/pull/1")).to be_truthy
      expect(agent_run.reload.status).to eq("completed")
    end

    it "completes the run when no required verification applies" do
      expect(agent_run.complete!).to be_truthy
      expect(agent_run.reload.status).to eq("completed")
    end

    it "withholds completion when a stale succeeded attempt does not cover the commit being completed" do
      revision = approved_required_revision
      attempt_for(revision, agent_run:, status: "succeeded",
        commit_sha: "0123456789abcdef0123456789abcdef01234567")
      shipped_sha = "abcdef0123456789abcdef0123456789abcdef01"

      expect(
        agent_run.complete!(result_commit: shipped_sha, pr_url: "https://github.com/example/pull/9", pr_number: 9)
      ).to be_falsey

      agent_run.reload
      expect(agent_run.status).to eq("running")
      expect(agent_run.pull_request_url).to be_blank
      log = agent_run.agent_run_logs.system.last
      expect(log.content).to include("Completion withheld", "0123456789abcdef0123456789abcdef01234567")
    end

    it "completes once verification succeeds on the commit being shipped" do
      revision = approved_required_revision
      shipped_sha = "0123456789abcdef0123456789abcdef01234567"
      attempt_for(revision, agent_run:, status: "succeeded", commit_sha: shipped_sha)

      expect(
        agent_run.complete!(result_commit: shipped_sha, pr_url: "https://github.com/example/pull/9", pr_number: 9)
      ).to be_truthy

      expect(agent_run.reload.status).to eq("completed")
      expect(agent_run.result_commit_sha).to eq(shipped_sha)
    end
  end

  describe "pull_request_verification gate on the recorded PR verification result" do
    let(:project) do
      create(:project, account:, apple_verification_mode: "on_demand", screenshot_settings: { "verification_enabled" => true })
    end
    let(:repo_path) { Dir.mktmpdir("apple-pr-gate-spec") }
    let(:result_path) { File.join(repo_path, AgentRuns::VerificationPrompt::RESULT_PATH) }

    before { FileUtils.mkdir_p(File.dirname(result_path)) }

    after { FileUtils.rm_rf(repo_path) }

    def write_interactive_result(status:)
      File.write(result_path, JSON.generate(status: status, summary: "Interactive verification #{status}."))
    end

    it "downgrades a passed interactive result while required verification is pending" do
      approved_required_revision(gate: "pull_request_verification")
      write_interactive_result(status: "passed")

      AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)

      result = agent_run.reload.verification_result
      expect(result["status"]).to eq("not_run")
      expect(result["reason"]).to eq("apple_verification_pending")
      expect(result.fetch("apple_verification")).to include(
        "state" => "pending",
        "gate" => "pull_request_verification"
      )
      expect(result["apple_verification"]["interactive_status"]).to eq("passed")
    end

    it "marks the recorded result failed when required checks failed" do
      revision = approved_required_revision(gate: "pull_request_verification")
      attempt_for(revision, agent_run:, status: "failed", failure_classification: "required_capture")
      write_interactive_result(status: "passed")

      AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)

      result = agent_run.reload.verification_result
      expect(result["status"]).to eq("failed")
      expect(result["reason"]).to eq("apple_verification_failed")
      expect(result.fetch("apple_verification")).to include(
        "state" => "blocked",
        "failure_classification" => "required_capture"
      )
    end

    it "leaves the interactive result unchanged when the gate is satisfied" do
      revision = approved_required_revision(gate: "pull_request_verification")
      attempt_for(revision, agent_run:, status: "succeeded")
      write_interactive_result(status: "passed")

      AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)

      expect(agent_run.reload.verification_result["status"]).to eq("passed")
      expect(agent_run.reload.verification_result).not_to have_key("apple_verification")
    end

    it "records an apple-only result when interactive verification is disabled" do
      project.update!(screenshot_settings: { "verification_enabled" => false })
      approved_required_revision(gate: "pull_request_verification")

      AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)

      result = agent_run.reload.verification_result
      expect(result["status"]).to eq("not_run")
      expect(result["reason"]).to eq("apple_verification_pending")
    end

    it "records nothing when the gate is satisfied and interactive verification is disabled" do
      project.update!(screenshot_settings: { "verification_enabled" => false })
      revision = approved_required_revision(gate: "pull_request_verification")
      attempt_for(revision, agent_run:, status: "succeeded")

      expect(AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)).to be_nil
      expect(agent_run.reload.verification_result).to eq({})
    end

    it "records nothing when no required verification applies and interactive verification is disabled" do
      project.update!(screenshot_settings: { "verification_enabled" => false })

      expect(AgentRuns::VerificationResultRecorder.call(agent_run:, repo_path:)).to be_nil
      expect(agent_run.reload.verification_result).to eq({})
    end
  end
end
