# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-007
RSpec.describe AppleVerification::Setup::SmokeAttemptFactory do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:image_digest) { "sha256:#{'a' * 64}" }
  let(:factory) { described_class.new(project:, image_digest:, profile_id: "ios-standard") }
  let(:attempt_lambda) { factory.call }
  let(:agent_run) do
    TenantContext.with_system_access do
      project.agent_runs.create!(
        agent_type: "claude_code", status: "running", goal: "create_pr", focus: "general",
        trigger_type: "manual", started_at: Time.current, custom_prompt: "Apple worker setup smoke",
        external_metadata: { "purpose" => "apple_setup_smoke", "smoke" => true, "project_id" => project.id }
      )
    end
  end

  before do
    project
    TenantContext.with_system_access do
      Project.where(id: project.id).update_all(account_id: account.id)
    end
  end

  describe "#call" do
    it "returns a Result whose attempt is bound to a smoke-only AppleWorkerProfile" do
      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.profile.name).to start_with(described_class::PROFILE_NAME_PREFIX)
      expect(result.profile.name).to include(image_digest.delete_prefix("sha256:")[0, described_class::PROFILE_NAME_DIGEST_FRAGMENT])
      expect(result.profile.image_digest).to eq(image_digest)
      expect(result.profile.account_id).to eq(account.id)
    end

    it "leaves the workflow revision in draft state without invoking the approval gate" do
      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.revision.status).to eq("draft")
      expect(result.revision.approved_at).to be_nil
      expect(result.revision.approved_by_id).to be_nil
      expect(result.revision.lifecycle_gate).to eq("agent_iteration")
    end

    it "creates a fresh attempt bound to the supplied agent_run" do
      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.attempt).to be_a(AppleVerificationAttempt)
      expect(result.attempt.agent_run_id).to eq(agent_run.id)
      expect(result.attempt.project_id).to eq(project.id)
      expect(result.attempt.apple_verification_workflow_revision_id).to eq(result.revision.id)
      expect(result.attempt.apple_worker_profile_id).to eq(result.profile.id)
      expect(result.attempt.lifecycle_gate).to eq("agent_iteration")
      expect(result.attempt.retry_number).to eq(0)
    end

    it "creates one revision per profile and reuses it on subsequent calls" do
      first = attempt_lambda.call(agent_run: agent_run)
      second_agent_run = create_third_agent_run
      second = attempt_lambda.call(agent_run: second_agent_run)

      expect(second.revision.id).to eq(first.revision.id)
      expect(second.profile.id).to eq(first.profile.id)
      expect(second.attempt.id).not_to eq(first.attempt.id)
      expect(second.attempt.agent_run_id).to eq(second_agent_run.id)
    end

    it "does not collide with a production profile that shares the operator's --profile value" do
      production_profile = TenantContext.with_system_access do
        create(:apple_worker_profile, account: account, name: "ios-standard")
      end

      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.profile.id).not_to eq(production_profile.id)
      expect(result.profile.name).not_to eq(production_profile.name)
    end

    it "does not find or mutate a production draft revision bound to a production profile" do
      production_profile = TenantContext.with_system_access do
        create(:apple_worker_profile, account: account, name: "ios-standard")
      end
      production_revision = TenantContext.with_system_access do
        create(:apple_verification_workflow_revision,
          project: project, account: account, apple_worker_profile: production_profile,
          content_digest: "sha256:#{'b' * 64}")
      end

      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.revision.id).not_to eq(production_revision.id)
      expect(production_revision.reload.status).to eq("draft")
      expect(production_revision.approved_at).to be_nil
    end

    it "never invokes the production approval gate even when a project administrator exists" do
      administrator = create(:user, account: account)
      administrator.add_role(:project_admin, project)

      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.revision.status).to eq("draft")
      expect(result.revision.approved_by_id).to be_nil
    end
  end

  describe "smoke profile name derivation" do
    it "uses a deterministic profile name keyed by image digest so re-runs share the smoke profile" do
      first_factory = described_class.new(project:, image_digest:, profile_id: "ios-standard").call
      second_factory = described_class.new(project:, image_digest:, profile_id: "ios-standard").call

      first_result = first_factory.call(agent_run: agent_run)
      second_result = second_factory.call(agent_run: agent_run)

      expect(second_result.profile.id).to eq(first_result.profile.id)
    end

    it "scopes the smoke profile name with a fixed prefix that production profiles do not use" do
      result = attempt_lambda.call(agent_run: agent_run)

      expect(result.profile.name).to start_with(described_class::PROFILE_NAME_PREFIX)
      expect(result.profile.name).not_to eq("ios-standard")
    end

    it "uses different smoke profile names for different image digests" do
      other_digest = "sha256:#{'f' * 64}"
      first_factory = described_class.new(project:, image_digest:, profile_id: "ios-standard").call
      second_factory = described_class.new(project:, image_digest: other_digest, profile_id: "ios-standard").call

      first_result = first_factory.call(agent_run: agent_run)
      second_result = second_factory.call(agent_run: create_third_agent_run)

      expect(second_result.profile.id).not_to eq(first_result.profile.id)
    end
  end

  describe "active attempts" do
    it "reuses the active smoke attempt when setup runs again for the same agent run" do
      first_result = attempt_lambda.call(agent_run: agent_run)
      second_result = attempt_lambda.call(agent_run: agent_run)

      expect(second_result.attempt.id).to eq(first_result.attempt.id)
    end
  end

  def create_third_agent_run
    TenantContext.with_system_access do
      project.agent_runs.create!(
        agent_type: "claude_code", status: "running", goal: "create_pr", focus: "general",
        trigger_type: "manual", started_at: Time.current, custom_prompt: "Apple worker setup smoke",
        external_metadata: { "purpose" => "apple_setup_smoke", "smoke" => true, "project_id" => project.id }
      )
    end
  end
end
