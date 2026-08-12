# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::GlobalLimit do
  describe ".max_concurrent_executions" do
    it "returns the default when ENV is unset" do
      expect(described_class.max_concurrent_executions(env: {})).to eq(50)
    end

    it "reads the value from ENV" do
      expect(described_class.max_concurrent_executions(env: { "MAX_GLOBAL_CONCURRENT_EXECUTIONS" => "100" })).to eq(100)
    end

    it "falls back to the default on invalid input" do
      expect(described_class.max_concurrent_executions(env: { "MAX_GLOBAL_CONCURRENT_EXECUTIONS" => "not_a_number" })).to eq(50)
    end
  end

  describe ".enabled?" do
    it "returns true when the limit is positive" do
      expect(described_class.enabled?(env: { "MAX_GLOBAL_CONCURRENT_EXECUTIONS" => "10" })).to be true
    end

    it "returns false when the limit is zero" do
      expect(described_class.enabled?(env: { "MAX_GLOBAL_CONCURRENT_EXECUTIONS" => "0" })).to be false
    end
  end
end
