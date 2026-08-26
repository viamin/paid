# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-001
# @spec AUTO-MERGE-002
# @spec AUTO-MERGE-005
RSpec.describe Automation::Strategies::AutoMerge, :no_db do
  subject(:strategy) { described_class.new }

  let(:project) do
    Class.new do
      attr_accessor :merge_method, :auto_fix_merge_conflicts, :owner_reviewer_login

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
      auto_fix_merge_conflicts: false,
      owner_reviewer_login: "viamin"
    )
  end

  describe "#analyze" do
    def blocker_payloads(analysis, kind)
      analysis.public_send("#{kind}_blockers").map(&:to_h)
    end

    def blocker(signal:, status:, reason_code:, sanitized_message:, next_action:)
      {
        signal:,
        status:,
        reason_code:,
        sanitized_message:,
        next_action:
      }
    end

    it "reports a stale approval as the only failed blocker and marks dependencies as not evaluated" do
      analysis = strategy.analyze(
        human_signals(reviews_fresh: false, dependencies_resolved: false),
        owner_reviewer_login: "viamin"
      )

      expect(analysis).not_to be_eligible
      expect(blocker_payloads(analysis, :failed)).to eq([ stale_approval_blocker ])
      expect(blocker_payloads(analysis, :not_evaluated)).to eq([ dependency_not_evaluated_blocker ])
    end

    it "reports multiple simultaneous blockers in evaluation order" do
      analysis = strategy.analyze(
        human_signals(owner_approved: false, checks_green: false, mergeable: false),
        owner_reviewer_login: "viamin"
      )

      expect(blocker_payloads(analysis, :failed)).to eq(multiple_failed_blockers)
    end

    def stale_approval_blocker
      blocker(
        signal: "reviews_fresh",
        status: "failed",
        reason_code: "stale_approval",
        sanitized_message: "The owner approval is stale for the current HEAD commit.",
        next_action: "Ask @viamin to re-approve this pull request for the current HEAD commit, then wait for the next automatic merge evaluation."
      )
    end

    def dependency_not_evaluated_blocker
      blocker(
        signal: "dependencies_resolved",
        status: "not_evaluated",
        reason_code: "dependencies_unresolved",
        sanitized_message: "Dependency resolution was not evaluated because an earlier auto-merge gate already failed.",
        next_action: "Resolve the earlier auto-merge blockers first, then let Paid re-evaluate dependency resolution."
      )
    end

    def multiple_failed_blockers
      [
        blocker(
          signal: "owner_approved",
          status: "failed",
          reason_code: "owner_approval_missing",
          sanitized_message: "The required owner approval is missing.",
          next_action: "Ask @viamin to approve this pull request, then wait for the next automatic merge evaluation."
        ),
        blocker(
          signal: "checks_green",
          status: "failed",
          reason_code: "checks_not_green",
          sanitized_message: "Required checks are not green yet.",
          next_action: "Wait for required checks to pass, then let auto-merge evaluate the pull request again."
        ),
        blocker(
          signal: "mergeable",
          status: "failed",
          reason_code: "not_mergeable",
          sanitized_message: "GitHub is not reporting this pull request as mergeable yet.",
          next_action: "Resolve merge conflicts or other mergeability blockers, then wait for the next automatic check."
        )
      ]
    end
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
