# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::Select do
  let(:registry) { Automation::Strategies::Registry.new }
  let(:account) { build_stubbed(:account) }
  let(:project) { build_stubbed(:project, account: account) }

  def select(**args)
    described_class.call(registry: registry, **args)
  end

  describe ".call" do
    context "with global defaults" do
      before do
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_global("auto_continue", Automation::Strategies::AutoContinue)
        registry.register_global("auto_review", Automation::Strategies::AutoReview)
        registry.register_global("auto_merge", Automation::Strategies::AutoMerge)
      end

      it "returns the global default for auto_pick" do
        strategy = select(strategy_type: :auto_pick)

        expect(strategy).to be_a(Automation::Strategies::AutoPick)
      end

      it "returns the global default for auto_continue" do
        strategy = select(strategy_type: :auto_continue)

        expect(strategy).to be_a(Automation::Strategies::AutoContinue)
      end

      it "returns the global default for auto_review" do
        strategy = select(strategy_type: :auto_review)

        expect(strategy).to be_a(Automation::Strategies::AutoReview)
      end

      it "returns the global default for auto_merge" do
        strategy = select(strategy_type: :auto_merge)

        expect(strategy).to be_a(Automation::Strategies::AutoMerge)
      end
    end

    context "with account-scoped registration" do
      it "returns the account-scoped strategy when project belongs to the account" do
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_account("auto_pick", account.id, Automation::Strategies::AutoContinue)

        strategy = select(strategy_type: :auto_pick, project: project)

        expect(strategy).to be_a(Automation::Strategies::AutoContinue)
      end

      it "falls back to global when the account has no registration" do
        other_account = build_stubbed(:account)
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_account("auto_pick", other_account.id, Automation::Strategies::AutoContinue)

        strategy = select(strategy_type: :auto_pick, project: project)

        expect(strategy).to be_a(Automation::Strategies::AutoPick)
      end

      it "uses project.account_id without touching project.account" do
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_account("auto_pick", account.id, Automation::Strategies::AutoContinue)
        project_without_account = Struct.new(:id, :account_id).new(project.id, account.id)

        strategy = select(strategy_type: :auto_pick, project: project_without_account)

        expect(strategy).to be_a(Automation::Strategies::AutoContinue)
      end
    end

    context "with project-scoped registration" do
      it "returns the project-scoped strategy" do
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_project("auto_pick", project.id, Automation::Strategies::AutoReview)

        strategy = select(strategy_type: :auto_pick, project: project)

        expect(strategy).to be_a(Automation::Strategies::AutoReview)
      end

      it "takes precedence over account-scoped registration" do
        registry.register_account("auto_pick", account.id, Automation::Strategies::AutoContinue)
        registry.register_project("auto_pick", project.id, Automation::Strategies::AutoReview)

        strategy = select(strategy_type: :auto_pick, project: project)

        expect(strategy).to be_a(Automation::Strategies::AutoReview)
      end
    end

    context "with task-scoped registration" do
      it "returns the task-scoped strategy" do
        registry.register_global("auto_pick", Automation::Strategies::AutoPick)
        registry.register_task("auto_pick", "bug_fix", Automation::Strategies::AutoMerge)

        strategy = select(strategy_type: :auto_pick, task_type: :bug_fix)

        expect(strategy).to be_a(Automation::Strategies::AutoMerge)
      end

      it "takes precedence over project-scoped registration" do
        registry.register_project("auto_pick", project.id, Automation::Strategies::AutoReview)
        registry.register_task("auto_pick", "bug_fix", Automation::Strategies::AutoMerge)

        strategy = select(strategy_type: :auto_pick, project: project, task_type: :bug_fix)

        expect(strategy).to be_a(Automation::Strategies::AutoMerge)
      end
    end

    context "with constructor args" do
      it "passes constructor args to the strategy" do
        source = instance_double(Automation::Strategies::AutoPick::DefaultCandidateSource)
        registry.register_global("auto_pick", Automation::Strategies::AutoPick, candidate_source: source)

        strategy = select(strategy_type: :auto_pick)

        expect(strategy).to be_a(Automation::Strategies::AutoPick)
      end
    end

    context "with no matching registration" do
      it "falls back to the built-in default when the registry has no match" do
        strategy = select(strategy_type: :auto_pick)

        expect(strategy).to be_a(Automation::Strategies::AutoPick)
      end

      it "returns a NullStrategy for an unknown strategy type" do
        strategy = select(strategy_type: :unknown_strategy)

        expect(strategy).to be_a(Automation::Strategies::NullStrategy)
      end

      it "NullStrategy returns a noop result" do
        strategy = select(strategy_type: :unknown_strategy)
        context = Automation::Context.build(
          record: nil,
          project: project,
          metadata: {}
        )

        result = strategy.evaluate(context)

        expect(result.decisions.size).to eq(1)
        expect(result.decisions.first.type).to eq("noop")
      end
    end
  end

  describe ".swap_default_registry" do
    after do
      described_class.reset_default_registry!
    end

    it "returns the previous registry and installs the new one" do
      previous_registry = described_class.default_registry
      replacement_registry = Automation::Strategies::Registry.new

      returned_registry = described_class.swap_default_registry(replacement_registry)

      expect(returned_registry).to be(previous_registry)
      expect(described_class.default_registry).to be(replacement_registry)
    end
  end
end
