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

    it "returns a workflow-safe snapshot of project-scoped flags" do
      FeatureFlags.enable!(:explicit_pr_automation_decisions, project:)

      expect(activity.execute(project_id: project.id)).to eq(
        flags: {
          explicit_pr_automation_decisions: true
        },
        project_missing: false
      )
    end
  end
end
