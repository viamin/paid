# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategies::ResolveVersion do
  describe ".call" do
    let(:slug) { Strategies::BaselineOrchestration::PLANNING_OUTCOME_SLUG }

    it "returns the project-scoped current version first" do
      project = create(:project)
      global = create(:strategy, :global, slug: slug, decision_type: "planning_outcome")
      global_version = create(:strategy_version, :active, strategy: global, content: { "scope" => "global" })
      global.update!(current_version: global_version)

      account_strategy = create(:strategy, account: project.account, project: nil, slug: slug, decision_type: "planning_outcome")
      account_version = create(:strategy_version, :active, strategy: account_strategy, content: { "scope" => "account" })
      account_strategy.update!(current_version: account_version)

      project_strategy = create(:strategy, project: project, account: project.account, slug: slug, decision_type: "planning_outcome")
      project_version = create(:strategy_version, :active, strategy: project_strategy, content: { "scope" => "project" })
      project_strategy.update!(current_version: project_version)

      expect(described_class.call(slug: slug, project: project)).to eq(project_version)
    end

    it "falls back to account then global scope" do
      project = create(:project)
      global = create(:strategy, :global, slug: slug, decision_type: "planning_outcome")
      global_version = create(:strategy_version, :active, strategy: global)
      global.update!(current_version: global_version)

      account_strategy = create(:strategy, account: project.account, project: nil, slug: slug, decision_type: "planning_outcome")
      account_version = create(:strategy_version, :active, strategy: account_strategy)
      account_strategy.update!(current_version: account_version)

      expect(described_class.call(slug: slug, project: project)).to eq(account_version)

      account_strategy.update!(status: "archived")

      expect(described_class.call(slug: slug, project: project)).to eq(global_version)
    end

    it "skips scoped strategies whose current version is missing or inactive" do
      project = create(:project)
      global = create(:strategy, :global, slug: slug, decision_type: "planning_outcome")
      global_version = create(:strategy_version, :active, strategy: global, content: { "scope" => "global" })
      global.update!(current_version: global_version)

      account_strategy = create(:strategy, account: project.account, project: nil, slug: slug, decision_type: "planning_outcome")
      inactive_account_version = create(
        :strategy_version,
        strategy: account_strategy,
        promotion_state: "draft",
        content: { "scope" => "account" }
      )
      account_strategy.update_column(:current_version_id, inactive_account_version.id)

      project_strategy = create(:strategy, project: project, account: project.account, slug: slug, decision_type: "planning_outcome")
      project_strategy.update_column(:current_version_id, nil)

      expect(described_class.call(slug: slug, project: project)).to eq(global_version)
    end

    it "returns nil when the current version is not active" do
      strategy = create(:strategy, :global, slug: slug, decision_type: "planning_outcome")
      draft_version = create(:strategy_version, strategy: strategy, promotion_state: "draft")
      strategy.update_column(:current_version_id, draft_version.id)

      expect(described_class.call(slug: slug)).to be_nil
    end
  end
end
