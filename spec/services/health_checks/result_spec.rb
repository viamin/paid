# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Result do
  let(:error_finding) do
    HealthChecks::Finding.new(code: :err, scope: :project, severity: :error, title: "error")
  end

  let(:warning_finding) do
    HealthChecks::Finding.new(code: :warn, scope: :project, severity: :warning, title: "warn")
  end

  let(:info_finding) do
    HealthChecks::Finding.new(code: :info, scope: :project, severity: :info, title: "info")
  end

  let(:runner_finding) do
    HealthChecks::Finding.new(code: :run, scope: :runner, severity: :warning, title: "runner")
  end

  describe "#healthy?" do
    it "returns true when there are no error findings" do
      result = described_class.new(findings: [ warning_finding, info_finding ])
      expect(result).to be_healthy
    end

    it "returns false when there is at least one error finding" do
      result = described_class.new(findings: [ error_finding, warning_finding ])
      expect(result).not_to be_healthy
    end

    it "returns true when there are no findings" do
      result = described_class.new(findings: [])
      expect(result).to be_healthy
    end
  end

  describe "#warnings?" do
    it "returns true when there is at least one warning" do
      result = described_class.new(findings: [ warning_finding, info_finding ])
      expect(result).to be_warnings
    end

    it "returns false when there are no warnings" do
      result = described_class.new(findings: [ error_finding, info_finding ])
      expect(result).not_to be_warnings
    end
  end

  describe "#for_scope" do
    it "filters findings by scope" do
      result = described_class.new(findings: [ error_finding, runner_finding ])

      expect(result.for_scope(:project)).to contain_exactly(error_finding)
      expect(result.for_scope(:runner)).to contain_exactly(runner_finding)
      expect(result.for_scope(:user)).to eq([])
    end
  end

  describe "#counts" do
    it "returns severity counts" do
      result = described_class.new(findings: [ error_finding, warning_finding, warning_finding, info_finding ])

      expect(result.counts).to eq(error: 1, warning: 2, info: 1)
    end

    it "returns an empty hash with no findings" do
      result = described_class.new(findings: [])

      expect(result.counts).to eq({})
    end
  end

  describe "defaults" do
    it "defaults checked_at to current time" do
      result = described_class.new(findings: [])
      expect(result.checked_at).to be_within(1.second).of(Time.current)
    end

    it "defaults duration_ms to 0" do
      result = described_class.new(findings: [])
      expect(result.duration_ms).to eq(0)
    end
  end
end
