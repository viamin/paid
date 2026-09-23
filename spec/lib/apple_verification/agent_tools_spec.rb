# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::AgentTools do
  # @spec APPLE-RESULT-006
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, apple_verification_mode: "on_demand") }
  let(:agent_run) { create(:agent_run, :running, project:) }
  let(:bundle_digest) { "sha256:#{'e' * 64}" }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
  end

  def draft_revision
    create(
      :apple_verification_workflow_revision,
      project:,
      lifecycle_gate: "agent_iteration",
      required_checks: %w[ios-app.tests],
      advisory_checks: %w[ios-app.initial-screen]
    )
  end

  def approved_revision(gate: "completion_verification")
    create(
      :apple_verification_workflow_revision,
      :approved,
      project:,
      lifecycle_gate: gate,
      required_checks: %w[ios-app.tests ios-app.initial-screen],
      advisory_checks: []
    )
  end

  it "exposes only the four semantic operations" do
    expect(described_class.singleton_methods.sort).to eq(
      %i[capture_apple_screenshot get_apple_verification stop_apple_verification verify_apple_project].sort
    )
  end

  def attempt_for(revision, agent_run:, status: "queued", failure_classification: nil)
    create(
      :apple_verification_attempt,
      project:,
      agent_run:,
      apple_verification_workflow_revision: revision,
      apple_worker_profile: revision.apple_worker_profile,
      lifecycle_gate: revision.lifecycle_gate,
      status:,
      failure_classification:
    )
  end

  describe ".verify_apple_project" do
    it "queues an advisory draft attempt at the agent_iteration gate from a workspace bundle digest" do
      revision = draft_revision

      result = described_class.verify_apple_project(project:, agent_run:, bundle_digest:)

      expect(result).to include(
        "status" => "queued",
        "lifecycle_gate" => "agent_iteration",
        "workflow_revision_status" => "draft",
        "source_digest" => bundle_digest,
        "agent_run_id" => agent_run.id
      )
      attempt = revision.apple_verification_attempts.last
      expect(attempt).to be_present
      expect(attempt.agent_run).to eq(agent_run)
      expect(attempt.commit_sha).to be_nil
    end

    it "queues an attempt for the approved revision from committed source" do
      revision = approved_revision
      commit_sha = "0123456789abcdef0123456789abcdef01234567"

      result = described_class.verify_apple_project(project:, agent_run:, commit_sha:)

      expect(result).to include(
        "status" => "queued",
        "lifecycle_gate" => "completion_verification",
        "workflow_revision_status" => "approved",
        "commit_sha" => commit_sha
      )
      expect(revision.apple_verification_attempts.last.agent_run).to eq(agent_run)
    end

    it "raises when the rollout flag is disabled" do
      FeatureFlags.disable!(:apple_verification_workers, project:)
      draft_revision

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::CapabilityDisabledError)
    end

    it "raises when the project mode is off" do
      project.update!(apple_verification_mode: "off")
      draft_revision

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::ModeUnavailableError)
    end

    it "raises when the project mode is automatic because agents cannot trigger scheduler-owned verification" do
      project.update!(apple_verification_mode: "automatic")
      draft_revision

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::ModeUnavailableError, /automatic/)
    end

    it "raises when the agent run belongs to a different project" do
      draft_revision
      other_project = create(:project, account:)
      other_run = create(:agent_run, :running, project: other_project)

      expect { described_class.verify_apple_project(project:, agent_run: other_run, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::AuthorityError)
    end

    it "raises when the agent run is not active" do
      draft_revision
      finished_run = create(:agent_run, :completed, project:)

      expect { described_class.verify_apple_project(project:, agent_run: finished_run, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::AuthorityError)
    end

    it "raises when no draft revision exists for an uncommitted request" do
      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::WorkflowUnavailableError, /draft/)
    end

    it "raises when no approved revision exists for a committed request" do
      draft_revision

      expect { described_class.verify_apple_project(project:, agent_run:, commit_sha: "0123456789abcdef0123456789abcdef01234567") }
        .to raise_error(AppleVerification::AgentTools::WorkflowUnavailableError, /approved/)
    end

    it "raises when the bundle digest is not a sha256 digest" do
      draft_revision

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest: "md5:abc") }
        .to raise_error(AppleVerification::AgentTools::InvalidSourceError)
    end

    it "requires a source reference" do
      expect { described_class.verify_apple_project(project:, agent_run:) }
        .to raise_error(AppleVerification::AgentTools::InvalidSourceError)
    end

    it "raises when an active attempt already exists for the run" do
      revision = draft_revision
      create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "queued"
      )

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::QuotaExceededError, /active/)
    end

    it "rejects a second active attempt for the run at the database level" do
      revision = draft_revision
      attrs = {
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate
      }
      create(:apple_verification_attempt, attrs.merge(status: "queued"))

      expect { create(:apple_verification_attempt, attrs.merge(status: "running")) }
        .to raise_error(ActiveRecord::RecordNotUnique, /idx_apple_attempts_one_active_per_run/)

      # Terminal attempts never conflict: a retry may queue after them.
      create(:apple_verification_attempt, attrs.merge(status: "succeeded"))
      create(:apple_verification_attempt, attrs.merge(status: "failed", failure_classification: "test_assertion"))
      # Scheduler-owned attempts without an agent run are outside the quota.
      create(:apple_verification_attempt, attrs.merge(status: "queued", agent_run: nil))
      create(:apple_verification_attempt, attrs.merge(status: "running", agent_run: nil))
    end

    it "maps a concurrent duplicate insert to the quota error" do
      revision = draft_revision
      create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "queued"
      )
      # Simulate the check-then-create race: ensure_quota passes because the
      # concurrent attempt is not visible to it, but the partial unique index
      # on active attempts per agent run still rejects the duplicate insert.
      allow(described_class).to receive(:ensure_quota).and_return(nil)

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::QuotaExceededError, /active/)
    end

    it "raises when the run exceeds the per-run attempt quota" do
      revision = draft_revision
      AppleVerification::AgentTools::MAX_ATTEMPTS_PER_RUN.times do
        create(
          :apple_verification_attempt,
          project:,
          agent_run:,
          apple_verification_workflow_revision: revision,
          apple_worker_profile: revision.apple_worker_profile,
          lifecycle_gate: revision.lifecycle_gate,
          status: "cancelled"
        )
      end

      expect { described_class.verify_apple_project(project:, agent_run:, bundle_digest:) }
        .to raise_error(AppleVerification::AgentTools::QuotaExceededError, /quota/)
    end
  end

  describe ".capture_apple_screenshot" do
    it "requests an attempt for a capture declared by the revision" do
      revision = draft_revision

      result = described_class.capture_apple_screenshot(project:, agent_run:, bundle_digest:, capture_id: "ios-app.initial-screen")

      expect(result).to include(
        "status" => "queued",
        "requested_capture" => "ios-app.initial-screen",
        "lifecycle_gate" => "agent_iteration"
      )
      expect(revision.apple_verification_attempts.count).to eq(1)
    end

    it "rejects a capture the revision does not declare" do
      draft_revision

      expect { described_class.capture_apple_screenshot(project:, agent_run:, bundle_digest:, capture_id: "ios-app.secret-screen") }
        .to raise_error(AppleVerification::AgentTools::CaptureNotDeclaredError)
    end

    it "requires a capture id" do
      draft_revision

      expect { described_class.capture_apple_screenshot(project:, agent_run:, bundle_digest:, capture_id: "") }
        .to raise_error(ArgumentError)
    end

    it "rejects an undeclared capture even on an approved revision" do
      approved_revision

      expect {
        described_class.capture_apple_screenshot(
          project:, agent_run:,
          commit_sha: "0123456789abcdef0123456789abcdef01234567",
          capture_id: "not-declared"
        )
      }.to raise_error(AppleVerification::AgentTools::CaptureNotDeclaredError)
    end
  end

  describe ".get_apple_verification" do
    it "returns structured state matching the project UI presentation" do
      revision = approved_revision(gate: "agent_iteration")
      attempt = attempt_for(revision, agent_run:, status: "failed", failure_classification: "test_assertion")

      state = described_class.get_apple_verification(project:, agent_run:)

      expect(state).to include(
        "mode" => "on_demand",
        "flag_enabled" => true
      )
      expect(state["attempts"]).to be_present
      expect(state["attempts"].first).to include(
        "attempt_id" => attempt.id,
        "status" => "failed",
        "failure_classification" => "test_assertion",
        "workflow_revision_status" => "approved",
        "retry_number" => 0,
        "required_checks" => %w[ios-app.tests ios-app.initial-screen]
      )
    end

    it "includes workflow revision summaries and protected artifact metadata" do
      revision = draft_revision
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate
      )
      attempt.apple_verification_artifacts.create!(
        kind: "screenshot", storage_key: "apple/attempt/#{attempt.id}/initial-screen.png",
        content_type: "image/png"
      )

      state = described_class.get_apple_verification(project:, agent_run:)

      expect(state["workflow"]).to include(
        "draft" => hash_including("revision" => revision.revision, "content_digest" => revision.content_digest)
      )
      artifact = state["attempts"].first["artifacts"].first
      expect(artifact).to include("kind" => "screenshot", "storage_key" => "apple/attempt/#{attempt.id}/initial-screen.png")
      expect(artifact).not_to include("url")
    end

    it "scopes a specific attempt lookup to the project and run" do
      revision = draft_revision
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate
      )

      state = described_class.get_apple_verification(project:, agent_run:, attempt_id: attempt.id)

      expect(state["attempts"].first["attempt_id"]).to eq(attempt.id)
    end

    it "raises when the rollout flag is disabled" do
      FeatureFlags.disable!(:apple_verification_workers, project:)

      expect { described_class.get_apple_verification(project:, agent_run:) }
        .to raise_error(AppleVerification::AgentTools::CapabilityDisabledError)
    end

    it "raises when the project mode is off" do
      project.update!(apple_verification_mode: "off")

      expect { described_class.get_apple_verification(project:, agent_run:) }
        .to raise_error(AppleVerification::AgentTools::ModeUnavailableError)
    end

    it "does not return attempts belonging to other agent runs" do
      revision = draft_revision
      other_run = create(:agent_run, :running, project:)
      create(
        :apple_verification_attempt,
        project:,
        agent_run: other_run,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate
      )

      state = described_class.get_apple_verification(project:, agent_run:)

      expect(state["attempts"]).to be_empty
    end
  end

  describe ".stop_apple_verification" do
    it "cancels the run's own active attempt" do
      revision = draft_revision
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "running"
      )

      result = described_class.stop_apple_verification(project:, agent_run:, attempt_id: attempt.id)

      expect(result["status"]).to eq("cancelled")
      expect(attempt.reload.status).to eq("cancelled")
    end

    it "refuses to cancel another run's attempt" do
      revision = draft_revision
      other_run = create(:agent_run, :running, project:)
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run: other_run,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "running"
      )

      expect { described_class.stop_apple_verification(project:, agent_run:, attempt_id: attempt.id) }
        .to raise_error(AppleVerification::AgentTools::AuthorityError)
    end

    it "refuses to cancel an attempt from another project" do
      other_project = create(:project, account:)
      other_revision = create(
        :apple_verification_workflow_revision,
        :approved,
        project: other_project,
        lifecycle_gate: "completion_verification"
      )
      attempt = create(
        :apple_verification_attempt,
        project: other_project,
        agent_run: create(:agent_run, :running, project: other_project),
        apple_verification_workflow_revision: other_revision,
        apple_worker_profile: other_revision.apple_worker_profile,
        lifecycle_gate: other_revision.lifecycle_gate,
        status: "running"
      )

      expect { described_class.stop_apple_verification(project:, agent_run:, attempt_id: attempt.id) }
        .to raise_error(AppleVerification::AgentTools::AuthorityError, /not found for this project/)
    end

    it "refuses to cancel an unknown attempt id" do
      expect { described_class.stop_apple_verification(project:, agent_run:, attempt_id: 0) }
        .to raise_error(AppleVerification::AgentTools::AuthorityError, /not found for this project/)
    end

    it "raises for an already terminal attempt" do
      revision = draft_revision
      attempt = create(
        :apple_verification_attempt,
        project:,
        agent_run:,
        apple_verification_workflow_revision: revision,
        apple_worker_profile: revision.apple_worker_profile,
        lifecycle_gate: revision.lifecycle_gate,
        status: "succeeded"
      )

      expect { described_class.stop_apple_verification(project:, agent_run:, attempt_id: attempt.id) }
        .to raise_error(ArgumentError, /no longer active/)
    end
  end
end
