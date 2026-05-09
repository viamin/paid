# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationStrategySelector do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:global_bug_fix_strategy) do
      create_strategy_with_version(
        :global,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "bug_fix" }
      )
    end
    let(:account_bug_fix_strategy) do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "bug_fix" }
      )
    end
    let(:project_bug_fix_strategy) do
      create_strategy_with_version(
        :for_project,
        project: project,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "bug_fix" }
      )
    end
    let(:broad_account_strategy) do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "bug_fix" }
      )
    end
    let(:specific_account_strategy) do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: {
          "task_type" => "bug_fix",
          "metadata" => {
            "repository_size" => "large"
          }
        }
      )
    end
    let(:scope_key_strategy) do
      create_strategy_with_version(
        :for_project,
        project: project,
        account: account,
        decision_type: "issue_execution",
        selection_rules: {
          "decision_type" => "issue_execution",
          "project_id" => project.id.to_s,
          "account_id" => account.id.to_s
        }
      )
    end
    let(:broad_language_account_strategy) do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "language" => [ "ruby", "python" ] }
      )
    end
    let(:specific_language_account_strategy) do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "language" => "ruby" }
      )
    end

    def create_strategy_with_version(*traits, **attributes)
      strategy = create(:strategy, *traits, **attributes)
      version = create(:strategy_version, :active, strategy: strategy)
      strategy.update!(current_version: version)
      strategy
    end

    def selector_result(**args)
      described_class.call(decision_type: "issue_execution", **args)
    end

    it "returns the global active version when no scoped override matches" do
      strategy = create_strategy_with_version(
        :global,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "any" }
      )

      result = selector_result(context: { task_type: "bug_fix" })

      expect(result.strategy).to eq(strategy)
      expect(result.strategy_version).to eq(strategy.current_version)
      expect(result.scope).to eq(:global)
    end

    it "prefers a project-scoped strategy over account and global matches" do
      global_bug_fix_strategy
      account_bug_fix_strategy
      strategy = project_bug_fix_strategy

      result = selector_result(project: project, context: { task_type: "bug_fix" })

      expect(result.strategy).to eq(strategy)
      expect(result.scope).to eq(:project)
    end

    it "prefers the most specific rule set within the same scope" do
      broad_account_strategy
      strategy = specific_account_strategy

      result = selector_result(
        account: account,
        context: {
          task_type: "bug_fix",
          metadata: { repository_size: "large" }
        }
      )

      expect(result.strategy).to eq(strategy)
      expect(result.matched_rule_count).to eq(2)
    end

    it "treats array alternatives as broader than an exact match" do
      broad_language_account_strategy
      strategy = specific_language_account_strategy

      result = selector_result(account: account, context: { language: "ruby" })

      expect(result.strategy).to eq(strategy)
      expect(result.matched_rule_count).to eq(1)
    end

    it "ignores strategies whose current version is not active" do
      strategy = create(:strategy, :for_account, account: account, decision_type: "issue_execution")
      draft_version = create(:strategy_version, strategy: strategy, promotion_state: "draft")
      strategy.update_column(:current_version_id, draft_version.id)

      result = described_class.call(
        decision_type: "issue_execution",
        account: account,
        context: { task_type: "bug_fix" }
      )

      expect(result).to be_nil
    end

    it "returns nil when no strategy matches the provided context" do
      create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "feature" }
      )

      result = selector_result(account: account, context: { task_type: "bug_fix" })

      expect(result).to be_nil
    end

    it "uses the project account_id without loading project.account" do
      strategy = create_strategy_with_version(
        :for_account,
        account: account,
        decision_type: "issue_execution",
        selection_rules: { "task_type" => "bug_fix" }
      )
      lightweight_project = Struct.new(:id, :account_id).new(project.id, account.id)

      result = selector_result(project: lightweight_project, context: { task_type: "bug_fix" })

      expect(result.strategy).to eq(strategy)
      expect(result.scope).to eq(:account)
    end

    it "does not let caller context override derived scope keys" do
      strategy = scope_key_strategy

      result = selector_result(
        project: project,
        context: {
          decision_type: "wrong_decision",
          project_id: SecureRandom.uuid,
          account_id: SecureRandom.uuid
        }
      )

      expect(result.strategy).to eq(strategy)
      expect(result.scope).to eq(:project)
    end
  end
end
