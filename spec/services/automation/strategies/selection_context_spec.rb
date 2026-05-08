# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::SelectionContext do
  describe ".build" do
    it "normalizes strategy_type to a string" do
      ctx = described_class.build(strategy_type: :auto_pick)

      expect(ctx.strategy_type).to eq("auto_pick")
    end

    it "normalizes task_type to a string" do
      ctx = described_class.build(strategy_type: "auto_pick", task_type: :bug_fix)

      expect(ctx.task_type).to eq("bug_fix")
    end

    it "freezes metadata" do
      ctx = described_class.build(strategy_type: "auto_pick", metadata: { lang: "ruby" })

      expect(ctx.metadata).to be_frozen
    end

    it "defaults metadata to an empty frozen hash" do
      ctx = described_class.build(strategy_type: "auto_pick")

      expect(ctx.metadata).to eq({})
      expect(ctx.metadata).to be_frozen
    end

    it "infers account from project when not explicitly given" do
      account = build_stubbed(:account)
      project = build_stubbed(:project, account: account)

      ctx = described_class.build(strategy_type: "auto_pick", project: project)

      expect(ctx.account).to eq(account)
    end

    it "uses the explicit account when provided" do
      account = build_stubbed(:account)
      other_account = build_stubbed(:account)
      project = build_stubbed(:project, account: other_account)

      ctx = described_class.build(
        strategy_type: "auto_pick",
        project: project,
        account: account
      )

      expect(ctx.account).to eq(account)
    end

    it "leaves account nil when neither project nor account is given" do
      ctx = described_class.build(strategy_type: "auto_pick")

      expect(ctx.account).to be_nil
    end
  end
end
