# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::CiAction do
  def build_config(wait_for_reviews: true, **methods)
    method_hashes = Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |name, h|
      h[name.to_s] = methods[name] || { "enabled" => false }
    end
    Automation::Configuration::AutoReview.new(
      review_settings: Automation::Configuration::ReviewSettings.from_hash(
        "enabled" => true,
        "wait_for_reviews" => wait_for_reviews,
        "methods" => method_hashes
      )
    )
  end

  def build_plugin(config:, triggers: [])
    signals = Automation::Strategies::AutoReview::Signals.from_scan(
      issue_id: 1, pr_number: 50, phase: "ready", triggers: triggers
    )
    described_class.new(method: config.method_for(:ci_action), config: config, signals: signals)
  end

  it "identifies as :ci" do
    expect(build_plugin(config: build_config).kind).to eq(:ci)
  end

  it "blocks by default when wait_for_reviews is on" do
    expect(build_plugin(config: build_config(wait_for_reviews: true)).blocking_by_default?).to be true
    expect(build_plugin(config: build_config(wait_for_reviews: false)).blocking_by_default?).to be false
  end

  describe "#evaluate" do
    it "reports not_applicable when ci_action is disabled and no trigger is present" do
      expect(build_plugin(config: build_config).evaluate).to be_not_applicable
    end

    it "reports pending (blocking) when a ci_action_pending trigger fires" do
      plugin = build_plugin(
        config: build_config(ci_action: { "enabled" => true, "action_name" => "Claude Code Review" }),
        triggers: [ { type: "ci_action_pending", dispatch_required: true } ]
      )

      outcome = plugin.evaluate
      expect(outcome).to be_pending
      expect(outcome).to be_blocking
      expect(outcome.metadata[:action_name]).to eq("Claude Code Review")
      expect(outcome.metadata[:dispatch_required]).to be true
    end

    it "reports satisfied when ci_action is enabled and no trigger is present" do
      plugin = build_plugin(
        config: build_config(ci_action: { "enabled" => true, "action_name" => "Claude Code Review" })
      )

      expect(plugin.evaluate).to be_satisfied
    end
  end

  it "produces a dispatch decision when the action must be triggered" do
    plugin = build_plugin(
      config: build_config(ci_action: { "enabled" => true, "action_name" => "Claude Code Review" }),
      triggers: [ { type: "ci_action_pending", dispatch_required: true } ]
    )

    expect(plugin.decision.to_h).to eq(
      type: "dispatch_claude_review",
      pr_number: 50
    )
  end
end
