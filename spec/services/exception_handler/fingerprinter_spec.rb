# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionHandler::Fingerprinter do
  describe ".call" do
    it "returns a 32-character hex string" do
      error = RuntimeError.new("test error")
      error.set_backtrace([ "/app/foo.rb:10:in `bar'" ])

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result).to match(/\A[0-9a-f]{32}\z/)
    end

    it "produces the same fingerprint for identical exceptions" do
      error1 = RuntimeError.new("test error")
      error1.set_backtrace([ "/app/foo.rb:10:in `bar'" ])

      error2 = RuntimeError.new("test error")
      error2.set_backtrace([ "/app/foo.rb:10:in `bar'" ])

      fp1 = described_class.call(exception: error1, subsystem: "knowledge")
      fp2 = described_class.call(exception: error2, subsystem: "knowledge")

      expect(fp1).to eq(fp2)
    end

    it "normalizes numeric IDs in messages" do
      error1 = RuntimeError.new("Record 123 not found")
      error1.set_backtrace([])

      error2 = RuntimeError.new("Record 456 not found")
      error2.set_backtrace([])

      fp1 = described_class.call(exception: error1, subsystem: "knowledge")
      fp2 = described_class.call(exception: error2, subsystem: "knowledge")

      expect(fp1).to eq(fp2)
    end

    it "produces different fingerprints for different subsystems" do
      error = RuntimeError.new("test error")
      error.set_backtrace([])

      fp1 = described_class.call(exception: error, subsystem: "knowledge")
      fp2 = described_class.call(exception: error, subsystem: "agent_runs")

      expect(fp1).not_to eq(fp2)
    end

    it "produces different fingerprints for different exception classes" do
      error1 = RuntimeError.new("test")
      error1.set_backtrace([])

      error2 = ArgumentError.new("test")
      error2.set_backtrace([])

      fp1 = described_class.call(exception: error1, subsystem: "knowledge")
      fp2 = described_class.call(exception: error2, subsystem: "knowledge")

      expect(fp1).not_to eq(fp2)
    end

    it "handles nil backtrace" do
      error = RuntimeError.new("test")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result).to match(/\A[0-9a-f]{32}\z/)
    end
  end
end
