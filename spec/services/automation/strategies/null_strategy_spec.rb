# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::NullStrategy do
  subject(:strategy) { described_class.new }

  let(:project) { build_stubbed(:project) }

  describe "#evaluate" do
    it "returns a noop result for any context" do
      context = Automation::Context.build(record: nil, project: project, metadata: {})

      result = strategy.evaluate(context)

      expect(result).to be_a(Automation::Result)
      expect(result.decisions.size).to eq(1)
      expect(result.decisions.first.type).to eq("noop")
    end
  end
end
