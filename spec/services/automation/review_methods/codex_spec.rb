# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Codex do
  def build_config(**methods)
    method_hashes = Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |name, h|
      h[name.to_s] = methods[name] || { "enabled" => false }
    end
    Automation::Configuration::AutoReview.new(
      review_settings: Automation::Configuration::ReviewSettings.from_hash(
        "enabled" => true,
        "methods" => method_hashes
      )
    )
  end

  def build_plugin(config:, triggers: [])
    signals = Automation::Strategies::AutoReview::Signals.from_scan(
      issue_id: 1, pr_number: 50, phase: "ready", triggers: triggers
    )
    described_class.new(method: config.method_for(:codex), config: config, signals: signals)
  end

  it "identifies as :comment_bot" do
    expect(build_plugin(config: build_config).kind).to eq(:comment_bot)
  end

  it "reports satisfied when enabled with no trigger, not_applicable when disabled with no trigger" do
    expect(build_plugin(config: build_config(codex: { "enabled" => true })).evaluate).to be_satisfied
    expect(build_plugin(config: build_config).evaluate).to be_not_applicable
  end

  it "reports pending (sidecar) with the codex login when its trigger fires" do
    plugin = build_plugin(
      config: build_config(codex: { "enabled" => true }),
      triggers: [ { type: "review_bot_review_pending", request_login: "chatgpt-codex-connector" } ]
    )

    outcome = plugin.evaluate
    expect(outcome).to be_pending
    expect(outcome).to be_sidecar
    expect(outcome.metadata[:reviewer_login]).to eq("chatgpt-codex-connector")
  end

  it "ignores a trigger addressed to a different bot (e.g. copilot)" do
    plugin = build_plugin(
      config: build_config(codex: { "enabled" => true }),
      triggers: [ { type: "review_bot_review_pending", request_login: "copilot" } ]
    )

    expect(plugin.evaluate).to be_satisfied
  end

  describe "#decision" do
    it "requests review from the codex login when the trigger targets codex" do
      plugin = build_plugin(
        config: build_config(codex: { "enabled" => true }),
        triggers: [ { type: "review_bot_review_pending", request_login: "chatgpt-codex-connector" } ]
      )

      expect(plugin.decision.payload[:reviewers]).to eq([ "chatgpt-codex-connector" ])
    end

    it "is nil when the trigger targets a different bot (e.g. copilot)" do
      plugin = build_plugin(
        config: build_config(codex: { "enabled" => true }),
        triggers: [ { type: "review_bot_review_pending", request_login: "copilot" } ]
      )

      expect(plugin.decision).to be_nil
    end
  end
end
