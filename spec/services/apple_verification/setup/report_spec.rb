# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-005
RSpec.describe AppleVerification::Setup::Report do
  let(:preflight_result) do
    AppleVerification::Setup::Preflight::Result.new(
      id: :tart_binary, status: :gap, detail: "tart missing", fix: "brew install tart"
    )
  end

  let(:preflight) do
    AppleVerification::Setup::Preflight::Report.new(results: [ preflight_result ])
  end

  let(:plan) do
    [
      {
        index: 1, id: :tart_binary, title: "Install or upgrade Tart",
        detail: "tart missing", commands: [ "brew install cirruslabs/cli/tart" ],
        proof: "must print major 2 or later",
        guide_section: "Install Tart and Softnet"
      }
    ]
  end

  describe "#render" do
    it "includes every preflight check row" do
      markdown = described_class.new(preflight:, plan:).render

      expect(markdown).to include("Apple worker setup report")
      expect(markdown).to include("tart_binary")
      expect(markdown).to include("`gap`")
      expect(markdown).to include("brew install tart")
    end

    it "renders the operator action plan when preflight has gaps" do
      markdown = described_class.new(preflight:, plan:).render

      expect(markdown).to include("Operator action plan")
      expect(markdown).to include("Install or upgrade Tart")
      expect(markdown).to include("brew install cirruslabs/cli/tart")
      expect(markdown).to include("docs/rdrs/apple-worker-operator-guide.md#Install Tart and Softnet")
    end

    it "omits the plan section when preflight is ready" do
      ready = AppleVerification::Setup::Preflight::Report.new(
        results: [ AppleVerification::Setup::Preflight::Result.new(id: :tart_binary, status: :pass, detail: "ok", fix: nil) ]
      )

      markdown = described_class.new(preflight: ready, plan: []).render
      expect(markdown).not_to include("Operator action plan")
    end

    it "renders smoke results when provided" do
      smoke = AppleVerification::Setup::SmokeTests::Summary.new(
        results: [ AppleVerification::Setup::SmokeTests::Result.new(
          scenario_id: "permitted-dependency-access", status: :passed,
          detail: "ok", references: [], recorded_at: Time.current
        ) ],
        started_at: Time.current, finished_at: Time.current
      )

      markdown = described_class.new(preflight:, plan:, smoke:).render
      expect(markdown).to include("Smoke tests")
      expect(markdown).to include("permitted-dependency-access")
    end

    it "points operators at the canonical guide so no duplicate is introduced" do
      markdown = described_class.new(preflight:, plan:).render
      expect(markdown).to include("docs/rdrs/apple-worker-operator-guide.md")
    end
  end
end
