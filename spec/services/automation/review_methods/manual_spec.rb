# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Manual do
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
    described_class.new(method: config.method_for(:manual), config: config, signals: signals)
  end

  it "identifies as :human" do
    expect(build_plugin(config: build_config).kind).to eq(:human)
  end

  it "blocks by default when wait_for_reviews is on" do
    expect(build_plugin(config: build_config(wait_for_reviews: true)).blocking_by_default?).to be true
    expect(build_plugin(config: build_config(wait_for_reviews: false)).blocking_by_default?).to be false
  end

  describe "#evaluate" do
    it "reports not_applicable when manual is disabled and no trigger is present" do
      expect(build_plugin(config: build_config).evaluate).to be_not_applicable
    end

    it "reports pending (blocking) when a manual_review_pending trigger is present and wait_for_reviews is on" do
      plugin = build_plugin(
        config: build_config(manual: { "enabled" => true, "reviewer_login" => "alice" }),
        triggers: [ { type: "manual_review_pending", reviewer_login: "alice" } ]
      )

      outcome = plugin.evaluate
      expect(outcome).to be_pending
      expect(outcome).to be_blocking
      expect(outcome.metadata[:reviewer_login]).to eq("alice")
    end

    it "reports pending (sidecar) when wait_for_reviews is off" do
      plugin = build_plugin(
        config: build_config(wait_for_reviews: false, manual: { "enabled" => true, "reviewer_login" => "alice" }),
        triggers: [ { type: "manual_review_pending", reviewer_login: "alice" } ]
      )

      expect(plugin.evaluate).to be_sidecar
    end
  end

  describe "#decision" do
    it "requests review from the trigger's reviewer_login" do
      plugin = build_plugin(
        config: build_config(manual: { "enabled" => true, "reviewer_login" => "alice" }),
        triggers: [ { type: "manual_review_pending", reviewer_login: "alice" } ]
      )

      expect(plugin.decision.payload).to eq(pr_number: 50, reviewers: [ "alice" ])
    end

    it "returns nil when the pending trigger has no reviewer_login" do
      plugin = build_plugin(
        config: build_config(manual: { "enabled" => true }),
        triggers: [ { type: "manual_review_pending" } ]
      )

      expect(plugin.decision).to be_nil
    end
  end
end
