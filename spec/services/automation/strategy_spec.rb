# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategy do
  let(:base_strategy) do
    Class.new do
      include Automation::Strategy
    end
  end

  let(:concrete_strategy) do
    Class.new do
      include Automation::Strategy

      def evaluate(_context)
        Automation::Result.new(decisions: [ Automation::Decision.noop ])
      end
    end
  end

  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }
  let(:context) { Automation::Context.build(record: issue) }

  it "raises NotImplementedError when a strategy does not implement #evaluate" do
    expect { base_strategy.new.evaluate(context) }
      .to raise_error(NotImplementedError, /must implement #evaluate/)
  end

  it "lets strategies return a pre-built noop result" do
    klass = Class.new do
      include Automation::Strategy

      def evaluate(_context)
        noop_result
      end
    end

    expect(klass.new.evaluate(context).to_h)
      .to eq(decisions: [ { type: "noop" } ])
  end

  it "exposes the shared contract: Context in, Result out" do
    result = concrete_strategy.new.evaluate(context)

    expect(result).to be_a(Automation::Result)
    expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
  end
end
