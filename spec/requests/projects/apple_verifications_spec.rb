# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::AppleVerifications" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, apple_verification_mode: "off") }
  let(:project_administrator) do
    create(:user, :viewer, account:).tap { |administrator| administrator.add_role(:project_admin, project) }
  end

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
    sign_in user
  end

  describe "GET /projects/:project_id/apple_verification" do
    it "presents workflows, attempt results, audit evidence, and protected artifacts" do # @spec APPLE-VERIFY-001 # @spec APPLE-VERIFY-003 # @spec APPLE-VERIFY-004
      attempt = create(:apple_verification_attempt, project:)
      artifact = create_artifact(attempt)
      create_result_artifact(attempt)
      create_audit_event(attempt)

      get project_apple_verification_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(*presented_attempt_evidence(attempt, artifact))
    end

    it "presents the mode without an update control to account viewers" do # @spec APPLE-VERIFY-001
      sign_out user
      sign_in create(:user, :viewer, account:)

      get project_apple_verification_path(project)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Mode: Off")
      expect(response.body).not_to include("Save mode", "project[mode]")
    end
  end

  describe "GET /projects/:project_id/apple_verification/compare" do
    it "presents every workflow field that differs" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:, content_digest: digest("b"), required_checks: [ "build" ])
      comparison = create(
        :apple_verification_workflow_revision,
        project:,
        apple_worker_profile: create(:apple_worker_profile, account:),
        content_digest: digest("c"),
        required_checks: [ "test" ]
      )

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: comparison.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Content digest", digest("b"), digest("c"), "Required checks", "Worker profile")
    end

    it "does not compare a revision from another project" do # @spec APPLE-VERIFY-005
      revision = create(:apple_verification_workflow_revision, project:)
      other_revision = create(:apple_verification_workflow_revision)

      get compare_project_apple_verification_path(project), params: { revision_id: revision.id, compare_to_id: other_revision.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /projects/:project_id/apple_verification/artifact" do
    it "issues a storage URL only after project authorization" do # @spec APPLE-VERIFY-004
      artifact = create_artifact(create(:apple_verification_attempt, project:))
      storage = instance_double(ArtifactStorage, signed_url: "https://artifacts.example.test/capture")
      allow(ArtifactStorage).to receive(:new).and_return(storage)

      get artifact_project_apple_verification_path(project), params: { artifact_id: artifact.id }

      expect(response).to redirect_to("https://artifacts.example.test/capture")
      expect(storage).to have_received(:signed_url).with(artifact.storage_key)
    end

    it "does not issue a storage URL outside the project account" do # @spec APPLE-VERIFY-004 # @spec TENANT-ACCESS-001
      artifact = create_artifact(create(:apple_verification_attempt, project:))
      storage = instance_double(ArtifactStorage)
      allow(ArtifactStorage).to receive(:new).and_return(storage)
      allow(storage).to receive(:signed_url)
      sign_out user
      sign_in create(:user, :owner)

      get artifact_project_apple_verification_path(project), params: { artifact_id: artifact.id }

      expect(response).to have_http_status(:not_found)
      expect(storage).not_to have_received(:signed_url)
    end
  end

  describe "PATCH /projects/:project_id/apple_verification" do
    it "updates the project verification mode" do # @spec APPLE-VERIFY-001
      patch project_apple_verification_path(project), params: { project: { mode: "on_demand" } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.reload.apple_verification_mode).to eq("on_demand")
    end
  end

  describe "POST /projects/:project_id/apple_verification/approve" do
    it "approves a draft revision for a project administrator" do # @spec APPLE-VERIFY-002
      revision = create(:apple_verification_workflow_revision, project:)
      sign_in_project_administrator

      post approve_project_apple_verification_path(project), params: { revision_id: revision.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(revision.reload).to be_approved
    end

    it "does not approve a draft revision for an account owner without a project role" do # @spec APPLE-VERIFY-002
      revision = create(:apple_verification_workflow_revision, project:)

      post approve_project_apple_verification_path(project), params: { revision_id: revision.id }

      expect(response).to redirect_to(root_path)
      expect(revision.reload).to be_draft
    end
  end

  describe "POST /projects/:project_id/apple_verification/rerun" do
    it "queues one retry when an authorized user submits the rerun twice" do # @spec APPLE-VERIFY-006
      attempt = create(:apple_verification_attempt, project:, status: "failed", retry_number: 2)
      sign_in_project_administrator

      post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }
      post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.apple_verification_attempts.count).to eq(2)
      expect(project.apple_verification_attempts.order(:created_at).last).to have_attributes(
        status: "queued", retry_number: 3, source_digest: attempt.source_digest, retry_of_attempt: attempt
      )
    end
  end

  describe "POST /projects/:project_id/apple_verification/cancel" do
    it "cancels an active attempt for an authorized user" do # @spec APPLE-VERIFY-006
      attempt = create(:apple_verification_attempt, project:, status: "running")
      sign_in_project_administrator

      post cancel_project_apple_verification_path(project), params: { attempt_id: attempt.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(attempt.reload.status).to eq("cancelled")
    end
  end

  describe "POST /projects/:project_id/apple_verification/waive" do
    it "waives the selected required check with a reason" do # @spec APPLE-VERIFY-006
      attempt = create(:apple_verification_attempt, project:, status: "failed")
      sign_in_project_administrator

      post waive_project_apple_verification_path(project), params: {
        attempt_id: attempt.id,
        waiver: { check_ids: [ "test" ], reason: "Known simulator outage", expires_at: 1.hour.from_now.iso8601 }
      }

      waiver = AppleVerificationWaiver.last
      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(waiver).to have_attributes(apple_verification_attempt: attempt, created_by: project_administrator, reason: "Known simulator outage")
    end
  end

  describe "POST /projects/:project_id/apple_verification/destroy_retained_vm" do
    it "requests cleanup of a retained failed verification VM" do # @spec APPLE-VERIFY-006
      attempt = create(:apple_verification_attempt, project:, status: "failed")
      resource = ExecutionResourceLedgerEntry.create!(
        apple_verification_attempt: attempt,
        runner_type: "apple_worker",
        resource_kind: "verification_vm",
        status: "active",
        tags: {},
        runner_handle: {}
      )
      sign_in_project_administrator

      post destroy_retained_vm_project_apple_verification_path(project), params: { attempt_id: attempt.id }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(resource.reload).to be_cleanup_pending
    end
  end

  def create_artifact(attempt)
    AppleVerificationArtifact.create!(
      apple_verification_attempt: attempt,
      kind: "screenshot",
      storage_key: "apple-verification/#{attempt.id}/screenshot.png"
    )
  end

  def create_result_artifact(attempt)
    AppleVerificationArtifact.create!(
      apple_verification_attempt: attempt,
      kind: "result",
      storage_key: "apple-verification/#{attempt.id}/result.json",
      metadata: {
        "results" => {
          "build" => { "outcome" => "succeeded", "source" => "xcodebuild build" },
          "test" => { "outcome" => "succeeded", "source" => "xcodebuild test" },
          "coverage" => { "outcome" => "92.4%", "source" => "xccov view" },
          "policy" => { "outcome" => "allowed", "source" => "required checks" }
        }
      }
    )
  end

  def create_audit_event(attempt)
    ExecutionAuditEvent.create!(
      apple_verification_attempt: attempt,
      event_name: "verification.completed",
      actor_type: "guest_executor",
      actor_id: "apple-worker-1",
      backend: "Guest executor",
      metadata: { "result_source" => "guest executor response" }
    )
  end

  def presented_attempt_evidence(attempt, artifact)
    [
      attempt.apple_verification_workflow_revision.content_digest,
      "Worker constraints", "platforms", "Build result", "succeeded", "xcodebuild build",
      "Test result", "xcodebuild test", "Coverage", "92.4%", "xccov view",
      "Policy decision", "allowed", "required checks", "verification.completed", "Guest executor",
      artifact_project_apple_verification_path(project, artifact_id: artifact.id), "Protected artifact"
    ]
  end

  def sign_in_project_administrator
    sign_out user
    sign_in project_administrator
  end

  def digest(character)
    "sha256:#{character * 64}"
  end
end
