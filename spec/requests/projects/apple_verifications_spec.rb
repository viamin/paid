# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Projects::AppleVerifications" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, apple_verification_settings: { "mode" => "off", "profiles" => [ "ios" ] }) }

  before do
    FeatureFlags.enable!(:apple_verification_workers, project:)
    sign_in user
  end

  describe "PATCH /projects/:project_id/apple_verification" do
    # @spec APPLE-VERIFY-001
    it "preserves inferred profiles when updating the verification mode" do
      patch project_apple_verification_path(project), params: { project: { mode: "on_demand" } }

      expect(response).to redirect_to(project_apple_verification_path(project))
      expect(project.reload.apple_verification_settings).to eq({ "mode" => "on_demand", "profiles" => [ "ios" ] })
    end
  end

  describe "POST /projects/:project_id/apple_verification/rerun" do
    # @spec APPLE-VERIFY-003
    it "does not queue a rerun while the project mode is off" do
      attempt = create(:apple_verification_attempt, project:)

      expect {
        post rerun_project_apple_verification_path(project), params: { attempt_id: attempt.id }
      }.not_to change(AppleVerificationAttempt, :count)

      expect(response).to redirect_to(root_path)
    end
  end
end
