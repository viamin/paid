# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::ReviewMethods::Registry do
  after { described_class.reset! }

  it "resolves each of the five known review methods" do
    expect(described_class.resolve(:paid_agent)).to eq(Automation::ReviewMethods::PaidAgent)
    expect(described_class.resolve(:copilot)).to eq(Automation::ReviewMethods::Copilot)
    expect(described_class.resolve(:codex)).to eq(Automation::ReviewMethods::Codex)
    expect(described_class.resolve(:manual)).to eq(Automation::ReviewMethods::Manual)
    expect(described_class.resolve(:ci_action)).to eq(Automation::ReviewMethods::CiAction)
  end

  it "accepts string names" do
    expect(described_class.resolve("copilot")).to eq(Automation::ReviewMethods::Copilot)
  end

  it "raises an UnknownMethodError for unknown names" do
    expect { described_class.resolve(:mystery) }
      .to raise_error(described_class::UnknownMethodError, /mystery/)
  end

  it "lets tests swap in a fake plugin and then reset" do
    fake = Class.new(Automation::ReviewMethods::Base)
    described_class.register(:copilot, fake)
    expect(described_class.resolve(:copilot)).to eq(fake)

    described_class.reset!
    expect(described_class.resolve(:copilot)).to eq(Automation::ReviewMethods::Copilot)
  end

  it "lists the canonical names" do
    expect(described_class.known).to match_array(%i[paid_agent copilot codex manual ci_action])
  end
end
