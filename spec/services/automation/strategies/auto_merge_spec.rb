# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoMerge, :no_db do
  subject(:strategy) { described_class.new }

  let(:project) do
    Class.new do
      attr_accessor :merge_method, :auto_fix_merge_conflicts

      def auto_merge_enabled? = true
    end.new
  end

  def build_context(signals: nil)
    Automation::Context.build(
      record: nil,
      project: project,
      metadata: { Automation::Strategies::AutoMerge::SIGNALS_KEY => signals }
    )
  end

  def human_signals(overrides = {})
    Automation::Strategies::AutoMerge::Signals.build(
      issue_id: 42,
      pr_number: 10,
      owner_approved: true,
      checks_green: true,
      mergeable: true,
      review_feedback_clear: true,
      blocking_reviews_complete: true,
      reviews_fresh: true,
      dependencies_resolved: true,
      **overrides
    )
  end

  def bot_signals(overrides = {})
    Automation::Strategies::AutoMerge::Signals.build(
      issue_id: 42,
      pr_number: 10,
      bot_authored: true,
      dependabot_eligible: true,
      checks_green: true,
      mergeable: true,
      dependencies_resolved: true,
      **overrides
    )
  end

  before do
    allow(project).to receive_messages(
      auto_merge_enabled?: true,
      merge_method: "squash",
      auto_fix_merge_conflicts: false
    )
  end

  describe "#evaluate" do
    context "when auto-merge is disabled" do
      before { allow(project).to receive(:auto_merge_enabled?).and_return(false) }

      it "returns a noop result" do
        result = strategy.evaluate(build_context(signals: human_signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end
    end

    context "when signals are nil" do
      it "returns a noop result" do
        result = strategy.evaluate(build_context(signals: nil))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end
    end

    context "when skip_auto_merge label is present" do
      it "returns noop for a human-authored PR" do
        signals = human_signals(skip_auto_merge: true)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop for a bot-authored PR" do
        signals = bot_signals(skip_auto_merge: true)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end
    end

    context "with a human-authored PR" do
      it "returns a merge decision when all preconditions are met" do
        result = strategy.evaluate(build_context(signals: human_signals))

        expect(result.decisions.size).to eq(1)
        expect(result.decisions.first.type).to eq("merge")
        expect(result.decisions.first.payload[:issue_id]).to eq(42)
        expect(result.decisions.first.payload[:pr_number]).to eq(10)
      end

      it "returns noop when owner has not approved" do
        signals = human_signals(owner_approved: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when checks are not green" do
        signals = human_signals(checks_green: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when PR is not mergeable" do
        signals = human_signals(mergeable: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when review feedback is outstanding" do
        signals = human_signals(review_feedback_clear: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when blocking reviews are incomplete" do
        signals = human_signals(blocking_reviews_complete: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when reviews are stale" do
        signals = human_signals(reviews_fresh: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when dependencies are unresolved" do
        signals = human_signals(dependencies_resolved: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end
    end

    context "with a bot-authored PR" do
      it "returns a merge decision when bot preconditions are met" do
        result = strategy.evaluate(build_context(signals: bot_signals))

        expect(result.decisions.size).to eq(1)
        expect(result.decisions.first.type).to eq("merge")
        expect(result.decisions.first.payload[:issue_id]).to eq(42)
      end

      it "returns noop when dependabot auto-merge is not eligible" do
        signals = bot_signals(dependabot_eligible: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when checks are not green" do
        signals = bot_signals(checks_green: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when PR is not mergeable" do
        signals = bot_signals(mergeable: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "returns noop when dependencies are unresolved" do
        signals = bot_signals(dependencies_resolved: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.map(&:type)).to eq([ "noop" ])
      end

      it "does not require owner approval" do
        signals = bot_signals(owner_approved: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.first.type).to eq("merge")
      end

      it "does not require review feedback to be clear" do
        signals = bot_signals(review_feedback_clear: false)
        result = strategy.evaluate(build_context(signals: signals))

        expect(result.decisions.first.type).to eq("merge")
      end
    end
  end
end
