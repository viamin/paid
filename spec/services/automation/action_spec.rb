# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Action do
  it "is the same vocabulary as Automation::Decision" do
    expect(described_class).to be(Automation::Decision)
  end

  it "constructs via the shared factory methods" do
    action = described_class.noop

    expect(action).to be_a(Automation::Decision)
    expect(action.to_h).to eq(type: "noop")
  end
end
