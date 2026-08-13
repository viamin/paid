# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::PaidAgent do
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

  def build_plugin(config:, triggers: [], **scan_overrides)
    signals = Automation::Strategies::AutoReview::Signals.from_scan({
      issue_id: 7,
      pr_number: 42,
      phase: "ready",
      triggers: triggers
    }.merge(scan_overrides))
    method = config.method_for(:paid_agent)
    described_class.new(method: method, config: config, signals: signals)
  end

  describe "#kind" do
    it "identifies as :agent" do
      expect(build_plugin(config: build_config).kind).to eq(:agent)
    end
  end

  describe "#evaluate" do
    it "reports satisfied when the method is enabled and no review trigger is present" do
      plugin = build_plugin(config: build_config(paid_agent: { "enabled" => true }))

      expect(plugin.evaluate).to be_satisfied
    end

    it "reports not_applicable when the method is disabled and no triggers are present" do
      plugin = build_plugin(config: build_config)

      expect(plugin.evaluate).to be_not_applicable
    end

    it "reports pending (sidecar) when paid_agent_review_pending fires and other methods are enabled" do
      config = build_config(paid_agent: { "enabled" => true }, copilot: { "enabled" => true })
      plugin = build_plugin(config: config, triggers: [ { type: "paid_agent_review_pending" } ])

      outcome = plugin.evaluate
      expect(outcome).to be_pending
      expect(outcome).to be_sidecar
      expect(outcome.metadata[:active_run]).to be false
      expect(outcome.metadata[:sole_method]).to be false
    end

    it "reports pending (blocking) when paid_agent is the sole enabled method" do
      config = build_config(paid_agent: { "enabled" => true })
      plugin = build_plugin(config: config, triggers: [ { type: "paid_agent_review_pending" } ])

      outcome = plugin.evaluate
      expect(outcome).to be_blocking
      expect(outcome.metadata[:sole_method]).to be true
    end

    it "reports retryable_failure when a review_goal_retry trigger is present" do
      plugin = build_plugin(
        config: build_config(paid_agent: { "enabled" => true }),
        triggers: [ { type: "review_goal_retry" } ],
        current_review_goal_retry_count: 2
      )

      outcome = plugin.evaluate
      expect(outcome).to be_retryable_failure
      expect(outcome.metadata[:retry_count]).to eq(2)
    end

    it "reports exhausted_retries on escalate_to_owner triggers naming paid_agent" do
      plugin = build_plugin(
        config: build_config(paid_agent: { "enabled" => true }),
        triggers: [ { type: "escalate_to_owner", details: "paid_agent retry budget exhausted" } ]
      )

      expect(plugin.evaluate).to be_exhausted_retries
    end
  end

  describe "#decision" do
    it "queues a review run when the pending trigger has no active_run" do
      plugin = build_plugin(
        config: build_config(paid_agent: { "enabled" => true }),
        triggers: [ { type: "paid_agent_review_pending" } ]
      )

      expect(plugin.decision.to_h).to eq(
        type: "queue_review_run",
        issue_id: 7,
        source_pull_request_number: 42,
        focus: "general"
      )
    end

    it "returns nil when the pending trigger reports active_run: true" do
      plugin = build_plugin(
        config: build_config(paid_agent: { "enabled" => true }),
        triggers: [ { type: "paid_agent_review_pending", active_run: true } ]
      )

      expect(plugin.decision).to be_nil
    end

    it "queues a review run for review_goal_retry triggers" do
      plugin = build_plugin(
        config: build_config(paid_agent: { "enabled" => true }),
        triggers: [ { type: "review_goal_retry" } ]
      )

      expect(plugin.decision.type).to eq("queue_review_run")
    end

    it "returns nil when no paid_agent trigger is present" do
      plugin = build_plugin(config: build_config(paid_agent: { "enabled" => true }))

      expect(plugin.decision).to be_nil
    end
  end

  describe "#blocking_by_default?" do
    it "is true when paid_agent is the sole enabled review method" do
      config = build_config(paid_agent: { "enabled" => true })
      expect(build_plugin(config: config).blocking_by_default?).to be true
    end

    it "is false when other methods are enabled alongside paid_agent" do
      config = build_config(paid_agent: { "enabled" => true }, manual: { "enabled" => true, "reviewer_login" => "alice" })
      expect(build_plugin(config: config).blocking_by_default?).to be false
    end
  end
end
