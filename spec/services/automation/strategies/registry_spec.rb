# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::Registry do
  subject(:registry) { described_class.new }

  let(:account) { build_stubbed(:account) }
  let(:project) { build_stubbed(:project, account: account) }

  let(:global_strategy) { Automation::Strategies::AutoPick }
  let(:account_strategy) { Automation::Strategies::AutoContinue }
  let(:project_strategy) { Automation::Strategies::AutoReview }
  let(:task_strategy) { Automation::Strategies::AutoMerge }

  def build_ctx(strategy_type: "auto_pick", proj: nil, acct: nil, task_type: nil)
    Automation::Strategies::SelectionContext.build(
      strategy_type: strategy_type,
      project: proj,
      account: acct,
      task_type: task_type
    )
  end

  describe "#resolve" do
    it "returns nil when nothing is registered" do
      ctx = build_ctx

      expect(registry.resolve(ctx)).to be_nil
    end

    it "resolves a global registration" do
      registry.register_global("auto_pick", global_strategy)
      ctx = build_ctx

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(global_strategy)
    end

    it "resolves an account registration over global" do
      registry.register_global("auto_pick", global_strategy)
      registry.register_account("auto_pick", account.id, account_strategy)
      ctx = build_ctx(acct: account)

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(account_strategy)
    end

    it "resolves a project registration over account and global" do
      registry.register_global("auto_pick", global_strategy)
      registry.register_account("auto_pick", account.id, account_strategy)
      registry.register_project("auto_pick", project.id, project_strategy)
      ctx = build_ctx(proj: project, acct: account)

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(project_strategy)
    end

    it "resolves a task registration over all other scopes" do
      registry.register_global("auto_pick", global_strategy)
      registry.register_account("auto_pick", account.id, account_strategy)
      registry.register_project("auto_pick", project.id, project_strategy)
      registry.register_task("auto_pick", "bug_fix", task_strategy)
      ctx = build_ctx(proj: project, acct: account, task_type: "bug_fix")

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(task_strategy)
    end

    it "falls back to account when project has no registration" do
      registry.register_global("auto_pick", global_strategy)
      registry.register_account("auto_pick", account.id, account_strategy)
      ctx = build_ctx(proj: project, acct: account)

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(account_strategy)
    end

    it "falls back to global when no scoped registration matches" do
      registry.register_global("auto_pick", global_strategy)
      ctx = build_ctx(proj: project, acct: account, task_type: "feature")

      reg = registry.resolve(ctx)

      expect(reg.strategy_class).to eq(global_strategy)
    end

    it "preserves constructor args in the registration" do
      registry.register_global("auto_pick", global_strategy, candidate_source: :custom)
      ctx = build_ctx

      reg = registry.resolve(ctx)

      expect(reg.constructor_args).to eq({ candidate_source: :custom })
    end

    it "does not match a different strategy type" do
      registry.register_global("auto_merge", task_strategy)
      ctx = build_ctx(strategy_type: "auto_pick")

      expect(registry.resolve(ctx)).to be_nil
    end
  end

  describe "#clear!" do
    it "removes all registrations" do
      registry.register_global("auto_pick", global_strategy)
      registry.register_account("auto_pick", account.id, account_strategy)
      registry.register_project("auto_pick", project.id, project_strategy)
      registry.register_task("auto_pick", "bug_fix", task_strategy)

      registry.clear!

      ctx = build_ctx(proj: project, acct: account, task_type: "bug_fix")
      expect(registry.resolve(ctx)).to be_nil
    end
  end
end
