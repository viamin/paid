# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Base do
  let(:config) do
    Automation::Configuration::AutoReview.new(
      review_settings: Automation::Configuration::ReviewSettings.from_hash(
        "enabled" => true,
        "methods" => Automation::Configuration::ReviewMethod::NAMES.each_with_object({}) do |n, h|
          h[n.to_s] = { "enabled" => false }
        end
      )
    )
  end
  let(:signals) { Automation::Strategies::AutoReview::Signals.from_scan(pr_number: 1) }
  let(:method_value) { config.method_for(:copilot) }

  it "requires subclasses to implement #kind and #evaluate" do
    base = described_class.new(method: method_value, config: config, signals: signals)

    expect { base.kind }.to raise_error(NotImplementedError)
    expect { base.evaluate }.to raise_error(NotImplementedError)
  end

  it "returns nil from #decision by default" do
    base = described_class.new(method: method_value, config: config, signals: signals)

    expect(base.decision).to be_nil
  end

  it "reports its method name via Base#name" do
    base = described_class.new(method: method_value, config: config, signals: signals)
    expect(base.name).to eq(:copilot)
  end

  it "is non-blocking by default" do
    base = described_class.new(method: method_value, config: config, signals: signals)
    expect(base.blocking_by_default?).to be false
  end
end
