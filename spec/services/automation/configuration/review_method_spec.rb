# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Configuration::ReviewMethod do
  describe ".from_hash" do
    it "defaults to disabled with empty termination when given nil" do
      method = described_class.from_hash(:paid_agent, nil)

      expect(method.name).to eq(:paid_agent)
      expect(method.enabled?).to be false
      expect(method.action_name).to be_nil
      expect(method.reviewer_login).to be_nil
      expect(method.termination).to eq(Automation::Configuration::Termination::EMPTY)
    end

    it "normalizes action_name and reviewer_login, stripping blanks to nil" do
      method = described_class.from_hash(
        :ci_action,
        "enabled" => true,
        "action_name" => "Claude Code Review",
        "reviewer_login" => " ",
        "termination" => { "timeout_minutes" => 45 }
      )

      expect(method.enabled?).to be true
      expect(method.action_name).to eq("Claude Code Review")
      expect(method.reviewer_login).to be_nil
      expect(method.timeout_minutes).to eq(45)
    end

    it "exposes termination accessors directly on the method" do
      method = described_class.from_hash(
        :paid_agent,
        "enabled" => true,
        "termination" => {
          "max_review_rounds" => 10,
          "max_review_goal_retries" => 2,
          "stop_when_no_comments" => true,
          "token_budget" => 75_000
        }
      )

      expect(method.max_review_rounds).to eq(10)
      expect(method.max_review_goal_retries).to eq(2)
      expect(method.stop_when_no_comments?).to be true
      expect(method.token_budget).to eq(75_000)
    end

    it "returns nil token_budget when termination omits it" do
      method = described_class.from_hash(:copilot, "enabled" => true, "termination" => { "max_review_rounds" => 5 })
      expect(method.token_budget).to be_nil
    end
  end

  it "lists the canonical NAMES" do
    expect(described_class::NAMES).to eq(%i[copilot paid_agent codex ci_action manual])
  end
end
