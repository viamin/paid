# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ResolvePrReviewPlanActivity do
  describe "#execute" do
    it "does not resolve or create a paid agent provider when paid_agent is not dispatchable" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "methods" => {
          "manual" => { "enabled" => true }
        }
      })
      allow(Project).to receive(:find).with(project.id).and_return(project)

      expect(project).not_to receive(:paid_agent_review_provider)

      result = described_class.new.execute(project_id: project.id)

      expect(result).to include(
        review_enabled: true,
        dispatchable_review_methods: [],
        paid_agent_review_provider_id: nil,
        paid_agent_review_agent_type: nil
      )
      expect(project.effective_owner.providers.where(provider_key: "codex", auth_type: "subscription")).to be_empty
    end

    it "includes the paid agent provider metadata when paid_agent is dispatchable" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => { "enabled" => true }
        }
      })
      allow(Project).to receive(:find).with(project.id).and_return(project)

      result = described_class.new.execute(project_id: project.id)
      provider = project.effective_owner.providers.find_by!(provider_key: "codex", auth_type: "subscription")

      expect(result).to include(
        dispatchable_review_methods: [ "paid_agent" ],
        paid_agent_review_provider_id: provider.id,
        paid_agent_review_agent_type: "codex"
      )
    end
  end
end
