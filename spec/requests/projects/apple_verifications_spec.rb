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
end
