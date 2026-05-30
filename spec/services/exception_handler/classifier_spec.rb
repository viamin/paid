# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionHandler::Classifier do
  describe ".call" do
    it "allowlists the seed subsystems for issue filing" do
      expect(described_class::ISSUE_FILING_ALLOWLIST).to contain_exactly(
        "knowledge",
        "agent_runs",
        "container_manager",
        "secrets_proxy"
      )
    end

    it "classifies transient timeout errors as logged" do
      error = Net::OpenTimeout.new("execution expired")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.action).to eq("logged")
      expect(result.reason).to include("timeout")
    end

    it "classifies rate limit errors as logged" do
      error = RuntimeError.new("API rate limit exceeded")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.action).to eq("logged")
      expect(result.reason).to include("rate limiting")
    end

    it "classifies database errors as P1" do
      error = ActiveRecord::ConnectionNotEstablished.new("connection failed")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.severity).to eq("p1")
      expect(result.action).to eq("issue_filed")
    end

    it "classifies PG subclasses as P1 via ancestry" do
      error = PG::ConnectionBad.new("could not connect")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.severity).to eq("p1")
      expect(result.action).to eq("issue_filed")
      expect(result.reason).to eq("database connection failure")
    end

    it "does not classify DB pool exhaustion as transient" do
      error = ActiveRecord::ConnectionTimeoutError.new("could not obtain a connection from the pool")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.action).to eq("issue_filed")
      expect(result.severity).to eq("p1")
    end

    it "classifies agent_runs subsystem errors as P1" do
      error = RuntimeError.new("agent execution failed")

      result = described_class.call(exception: error, subsystem: "agent_runs")

      expect(result.severity).to eq("p1")
      expect(result.action).to eq("issue_filed")
    end

    it "classifies knowledge subsystem errors as P2" do
      error = RuntimeError.new("collection failed")

      result = described_class.call(exception: error, subsystem: "knowledge")

      expect(result.severity).to eq("p2")
      expect(result.action).to eq("issue_filed")
    end

    it "returns a Classification data object" do
      error = RuntimeError.new("test")

      result = described_class.call(exception: error, subsystem: "general")

      expect(result).to be_a(described_class::Classification)
      expect(result).to respond_to(:severity, :action, :reason)
    end
  end
end
