# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-005
RSpec.describe AppleVerification::Setup::Plan do
  let(:passed_result) do
    AppleVerification::Setup::Preflight::Result.new(
      id: :tart_binary, status: :pass, detail: "ok", fix: nil
    )
  end

  let(:gapped_result) do
    AppleVerification::Setup::Preflight::Result.new(
      id: :tart_binary, status: :gap, detail: "tart missing", fix: "brew install tart"
    )
  end

  let(:report) do
    AppleVerification::Setup::Preflight::Report.new(results: [ passed_result, gapped_result ])
  end

  describe "#call" do
    it "maps every preflight gap to the canonical manual action registered for that check" do
      actions = described_class.new(report).call

      expect(actions.size).to eq(1)
      action = actions.first
      expect(action[:title]).to include("Install or upgrade Tart")
      expect(action[:commands]).to include("brew install cirruslabs/cli/tart")
      expect(action[:proof]).to include("major 2")
      expect(action[:guide_section]).to eq("Install Tart and Softnet")
    end

    it "renders the capacity action with disk, VM reconciliation, and host-memory verification commands" do
      capacity_gap = AppleVerification::Setup::Preflight::Result.new(
        id: :capacity, status: :gap, detail: "free host memory 10% < operator minimum 25%",
        fix: "stop other workloads"
      )
      capacity_report = AppleVerification::Setup::Preflight::Report.new(results: [ capacity_gap ])

      action = described_class.new(capacity_report).call.first

      expect(action[:commands]).to include("df -g /")
      expect(action[:commands]).to include("bin/paid apple-worker reconcile --destroy-orphans")
      expect(action[:commands]).to include("vm_stat | awk '/free/ {print $3}'")
      expect(action[:proof]).to include("60 GiB")
      expect(action[:proof]).to include("25% free host memory")
    end

    it "returns an empty action list when the preflight is ready" do
      ready_report = AppleVerification::Setup::Preflight::Report.new(results: [ passed_result ])
      expect(described_class.new(ready_report).call).to be_empty
    end

    it "raises a clear error when a gap has no registered manual action" do
      orphan = AppleVerification::Setup::Preflight::Result.new(
        id: :no_such_check, status: :gap, detail: "x", fix: "y"
      )
      report = AppleVerification::Setup::Preflight::Report.new(results: [ orphan ])

      expect { described_class.new(report).call }
        .to raise_error(AppleVerification::Setup::Plan::MissingActionError, /no_such_check/)
    end
  end

  describe "#to_markdown" do
    it "renders a Markdown plan that points operators to the canonical guide section" do
      markdown = described_class.new(report).to_markdown

      expect(markdown).to include("# Manual operator actions")
      expect(markdown).to include("## 1. Install or upgrade Tart")
      expect(markdown).to include("```bash")
      expect(markdown).to include("brew install cirruslabs/cli/tart")
      expect(markdown).to include("docs/rdrs/apple-worker-operator-guide.md#Install Tart and Softnet")
    end

    it "returns a 'no actions' message when preflight is ready" do
      ready_report = AppleVerification::Setup::Preflight::Report.new(results: [ passed_result ])
      expect(described_class.new(ready_report).to_markdown).to include("no manual actions")
    end
  end
end
