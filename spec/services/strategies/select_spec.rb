# frozen_string_literal: true

require "rails_helper"

# @spec LEARNED-ORCH-001
RSpec.describe Strategies::Select do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    def create_strategy_with_version(*traits, **attributes)
      strategy = create(:strategy, *traits, **attributes)
      version = create(:strategy_version, :active, strategy: strategy)
      strategy.update!(current_version: version)
      strategy
    end

    def select_result(**args)
      described_class.call(decision_type: "issue_execution", **args)
    end

    describe "global strategy selection" do
      it "returns a global strategy when no scoped override matches" do
        strategy = create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "any" }
        )

        result = select_result(context: { task_type: "bug_fix" })

        expect(result).to be_found
        expect(result.strategy).to eq(strategy)
        expect(result.strategy_version).to eq(strategy.current_version)
        expect(result.scope).to eq(:global)
      end

      it "returns a global strategy with empty selection rules as catch-all" do
        strategy = create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: {}
        )

        result = select_result

        expect(result).to be_found
        expect(result.strategy).to eq(strategy)
        expect(result.scope).to eq(:global)
      end

      it "does not return a global strategy that does not match context" do
        create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: { "language" => "python" }
        )

        result = select_result(context: { language: "ruby" })

        expect(result).not_to be_found
      end
    end

    describe "account-scoped selection" do
      it "prefers an account strategy over a global match" do
        create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "any" }
        )
        strategy = create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "any" }
        )

        result = select_result(account: account, context: { task_type: "any" })

        expect(result.strategy).to eq(strategy)
        expect(result.scope).to eq(:account)
      end

      it "does not match an account strategy for a different account" do
        other_account = create(:account)
        create_strategy_with_version(
          :for_account,
          account: other_account,
          decision_type: "issue_execution",
          selection_rules: {}
        )

        result = select_result(account: account)

        expect(result).not_to be_found
      end

      it "resolves account from project when account is not given" do
        strategy = create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "any" }
        )

        result = select_result(project: project, context: { task_type: "any" })

        expect(result.strategy).to eq(strategy)
        expect(result.scope).to eq(:account)
      end
    end

    describe "project-scoped selection" do
      it "prefers a project strategy over account and global matches" do
        create_strategy_with_version(:global, decision_type: "issue_execution", selection_rules: { "task_type" => "any" })
        create_strategy_with_version(:for_account, account: account, decision_type: "issue_execution", selection_rules: { "task_type" => "any" })
        strategy = create_strategy_with_version(:for_project, project: project, account: account, decision_type: "issue_execution", selection_rules: { "task_type" => "any" })

        result = select_result(project: project, account: account, context: { task_type: "any" })

        expect(result.strategy).to eq(strategy)
        expect(result.scope).to eq(:project)
      end

      it "does not match a project strategy for a different project" do
        other_project = create(:project, account: account)
        create_strategy_with_version(
          :for_project,
          project: other_project,
          account: account,
          decision_type: "issue_execution",
          selection_rules: {}
        )

        result = select_result(project: project)

        expect(result).not_to be_found
      end
    end

    describe "task-specific selection" do
      it "enriches context with task_type for rule matching" do
        strategy = create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "bug_fix" }
        )

        result = select_result(account: account, task_type: "bug_fix")

        expect(result).to be_found
        expect(result.strategy).to eq(strategy)
      end

      it "prefers a task-specific strategy over a broader strategy at the same scope" do
        create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "any" }
        )
        strategy = create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "bug_fix" }
        )

        result = select_result(account: account, task_type: "bug_fix")

        expect(result.strategy).to eq(strategy)
        expect(result.matched_rule_count).to eq(1)
      end

      it "does not match when task_type differs from selection rules" do
        create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "feature" }
        )

        result = select_result(account: account, task_type: "bug_fix")

        expect(result).not_to be_found
      end

      it "allows context to override task_type when explicitly provided" do
        create_strategy_with_version(
          :for_account,
          account: account,
          decision_type: "issue_execution",
          selection_rules: { "task_type" => "refactor" }
        )

        result = select_result(account: account, task_type: "bug_fix", context: { "task_type" => "refactor" })

        expect(result).to be_found
      end
    end

    describe "rule specificity" do
      it "prefers the strategy with more matched rules at the same scope" do
        create_strategy_with_version(:for_account, account: account, decision_type: "issue_execution", selection_rules: { "task_type" => "bug_fix" })
        strategy = create_strategy_with_version(:for_account, account: account, decision_type: "issue_execution", selection_rules: { "task_type" => "bug_fix", "language" => "ruby" })

        result = select_result(account: account, task_type: "bug_fix", context: { language: "ruby" })

        expect(result.strategy).to eq(strategy)
        expect(result.matched_rule_count).to eq(2)
      end
    end

    describe "fallback behavior" do
      it "returns a fallback result when no strategy matches" do
        result = select_result

        expect(result).not_to be_found
        expect(result.strategy).to be_nil
        expect(result.strategy_version).to be_nil
        expect(result.scope).to eq(:fallback)
        expect(result.matched_rule_count).to eq(0)
      end

      it "provides empty content for fallback results" do
        result = select_result

        expect(result.content).to eq({})
      end

      it "does not return a draft strategy as fallback" do
        strategy = create(:strategy, :global, :draft, decision_type: "issue_execution")
        create(:strategy_version, strategy: strategy, promotion_state: "draft")
        strategy.update_column(:current_version_id, strategy.strategy_versions.first.id)

        result = select_result

        expect(result).not_to be_found
      end

      it "does not return an archived strategy as fallback" do
        create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: {}
        ).tap { |s| s.update!(status: "archived") }

        result = select_result

        expect(result).not_to be_found
      end
    end

    describe "Result" do
      it "delegates content from the strategy version" do
        strategy = create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: {}
        )

        result = select_result

        expect(result.content).to eq(strategy.current_version.content)
      end

      it "has a human-readable to_s for matched results" do
        strategy = create_strategy_with_version(
          :global,
          decision_type: "issue_execution",
          selection_rules: {}
        )

        result = select_result

        expect(result.to_s).to eq("#{strategy.name} (global, v#{strategy.current_version.version})")
      end

      it "has a human-readable to_s for fallback results" do
        result = select_result

        expect(result.to_s).to eq("fallback")
      end
    end

    describe "decision type isolation" do
      it "does not match strategies from a different decision type" do
        create_strategy_with_version(
          :global,
          decision_type: "retry",
          selection_rules: {}
        )

        result = select_result

        expect(result).not_to be_found
      end
    end
  end
end
