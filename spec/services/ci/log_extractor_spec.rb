# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ci::LogExtractor do
  describe ".call" do
    it "returns small logs directly" do
      log = "bundle exec rspec\nrole \"root\" does not exist\n"

      expect(described_class.call(log)).to eq(log)
    end

    it "extracts error context from large logs" do
      log = [
        Array.new(600, "setup noise"),
        "Running spec/models/user_spec.rb",
        "expected: true",
        "     got: false",
        "Failure/Error: expect(user.active?).to be(true)",
        "stack frame 1",
        "stack frame 2",
        "stack frame 3",
        Array.new(600, "teardown noise")
      ].flatten.join("\n")

      extracted = described_class.call(log)

      expect(extracted).to include("expected: true")
      expect(extracted).to include("Failure/Error")
      expect(extracted).to include("stack frame 3")
      expect(extracted).not_to include("setup noise\nsetup noise\nsetup noise\nsetup noise")
    end

    it "caps extracted output" do
      log = Array.new(1_200) { |index| "line #{index}: error details" }.join("\n")

      extracted = described_class.call(log, max_chars: 100)

      expect(extracted.length).to be > 100
      expect(extracted).to include("[truncated]")
    end
  end
end
