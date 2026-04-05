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

    it "returns nil paid agent metadata when no configured codex provider is available" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => { "enabled" => true }
        }
      })
      allow(Project).to receive(:find).with(project.id).and_return(project)

      result = described_class.new.execute(project_id: project.id)

      expect(result).to include(
        dispatchable_review_methods: [ "paid_agent" ],
        paid_agent_review_provider_id: nil,
        paid_agent_review_agent_type: nil
      )
    end

    it "includes the configured paid agent provider metadata when paid_agent is dispatchable" do
      project = create(:project, review_settings: {
        "enabled" => true,
        "methods" => {
          "paid_agent" => { "enabled" => true }
        }
      })
      codex_api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "openai")
      codex = create(:provider, user: project.effective_owner, provider_key: "codex",
        auth_type: "api_key", provider_api_key: codex_api_key)
      project.effective_owner.settings.update!(
        default_agent_provider: codex.routing_key,
        fallback_providers: []
      )
      allow(Project).to receive(:find).with(project.id).and_return(project)

      result = described_class.new.execute(project_id: project.id)

      expect(result).to include(
        dispatchable_review_methods: [ "paid_agent" ],
        paid_agent_review_provider_id: codex.id,
        paid_agent_review_agent_type: "codex"
      )
    end
  end
end
