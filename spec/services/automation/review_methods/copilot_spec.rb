# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Copilot do
  def build_config(**methods)
    method_hashes = Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |name, h|
      h[name.to_s] = methods[name] || { "enabled" => false }
    end
    review_settings = Automation::Configuration::ReviewSettings.from_hash(
      "enabled" => true,
      "methods" => method_hashes
    )
    Automation::Configuration::AutoReview.new(review_settings: review_settings)
  end

  def build_plugin(config:, triggers: [])
    signals = Automation::Strategies::AutoReview::Signals.from_scan(
      issue_id: 1,
      pr_number: 50,
      phase: "draft",
      triggers: triggers
    )
    described_class.new(method: config.method_for(:copilot), config: config, signals: signals)
  end

  it "identifies as :bot" do
    expect(build_plugin(config: build_config).kind).to eq(:bot)
  end

  describe "#evaluate" do
    it "reports not_applicable when copilot is disabled and no trigger is present" do
      plugin = build_plugin(config: build_config)

      expect(plugin.evaluate).to be_not_applicable
    end

    it "reports satisfied when copilot is enabled and no trigger is present" do
      plugin = build_plugin(config: build_config(copilot: { "enabled" => true }))

      expect(plugin.evaluate).to be_satisfied
    end

    it "reports pending (sidecar) when a review_bot_review_pending trigger is present" do
      plugin = build_plugin(
        config: build_config(copilot: { "enabled" => true }),
        triggers: [ { type: "review_bot_review_pending", request_login: "copilot" } ]
      )

      outcome = plugin.evaluate
      expect(outcome).to be_pending
      expect(outcome).to be_sidecar
      expect(outcome.metadata[:reviewer_login]).to eq("copilot")
    end
  end

  describe "#decision" do
    it "requests review from the copilot login when the trigger targets copilot" do
      plugin = build_plugin(
        config: build_config(copilot: { "enabled" => true }),
        triggers: [ { type: "review_bot_review_pending", request_login: "copilot" } ]
      )

      decision = plugin.decision
      expect(decision.type).to eq("request_review")
      expect(decision.payload).to include(pr_number: 50, reviewers: [ "copilot" ])
    end

    it "is nil when the trigger targets a different bot (e.g. codex)" do
      plugin = build_plugin(
        config: build_config(copilot: { "enabled" => true }),
        triggers: [ { type: "review_bot_review_pending", request_login: "chatgpt-codex-connector" } ]
      )

      expect(plugin.decision).to be_nil
    end

    it "is nil when no trigger is present" do
      plugin = build_plugin(config: build_config(copilot: { "enabled" => true }))

      expect(plugin.decision).to be_nil
    end
  end
end
