# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::LoadFeatureFlagsActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  before do
    FeatureFlags.flipper.features.each(&:remove)
  end

  describe "#execute" do
    it "returns project_missing when the project cannot be found" do
      expect(activity.execute(project_id: -1)).to eq(
        flags: {},
        project_missing: true
      )
    end

    it "returns the registered flags with disabled defaults when none are enabled" do
      expect(activity.execute(project_id: project.id)).to eq(
        flags: {
          context_intake_agent_questions: false,
          execution_runner_enabled: false,
          managed_subscription_runner_auth: false
        },
        project_missing: false
      )
    end
  end
end
