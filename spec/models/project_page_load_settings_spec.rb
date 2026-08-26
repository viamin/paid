# frozen_string_literal: true

require "rails_helper"

RSpec.describe Project do
  describe "page load performance settings" do
    # @spec PAGE-LOAD-CONFIG-001
    it "defaults measurement on, follow-up off, with LCP thresholds" do
      project = build(:project, screenshot_settings: { "enabled" => true })

      expect(project.effective_screenshot_settings["performance"]).to eq(
        "enabled" => true,
        "followup_enabled" => false,
        "comparison_metric" => "lcp_ms",
        "regression_ratio" => 0.25,
        "regression_floor_ms" => 150,
        "samples" => 3
      )
    end

    # @spec PAGE-LOAD-CONFIG-001
    it "merges stored overrides onto the defaults" do
      project = build(:project, screenshot_settings: {
        "enabled" => true,
        "performance" => { "followup_enabled" => true, "samples" => 5 }
      })

      expect(project.effective_screenshot_settings["performance"]).to include(
        "followup_enabled" => true,
        "samples" => 5,
        "comparison_metric" => "lcp_ms"
      )
    end

    # @spec PAGE-LOAD-CONFIG-002
    it "rejects a comparison metric outside the recorded metric set" do
      project = build(:project, screenshot_settings: {
        "enabled" => true, "performance" => { "comparison_metric" => "time_to_joy" }
      })

      expect(project).not_to be_valid
      expect(project.errors[:screenshot_settings].join).to include("comparison_metric")
    end

    # @spec PAGE-LOAD-CONFIG-002
    it "rejects a non-positive ratio" do
      project = build(:project, screenshot_settings: {
        "enabled" => true, "performance" => { "regression_ratio" => 0 }
      })

      expect(project).not_to be_valid
      expect(project.errors[:screenshot_settings].join).to include("regression_ratio")
    end

    # @spec PAGE-LOAD-CONFIG-002
    it "rejects a negative floor" do
      project = build(:project, screenshot_settings: {
        "enabled" => true, "performance" => { "regression_floor_ms" => -1 }
      })

      expect(project).not_to be_valid
      expect(project.errors[:screenshot_settings].join).to include("regression_floor_ms")
    end

    # @spec PAGE-LOAD-CONFIG-002
    it "rejects a sample count outside 1..10" do
      project = build(:project, screenshot_settings: {
        "enabled" => true, "performance" => { "samples" => 25 }
      })

      expect(project).not_to be_valid
      expect(project.errors[:screenshot_settings].join).to include("samples")
    end
  end
end
