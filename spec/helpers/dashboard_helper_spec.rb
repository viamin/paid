# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardHelper, :no_db do
  describe "#dashboard_filter_link" do
    # @spec DASHBOARD-FILTER-A11Y-001
    it "sets aria-current=page when active" do
      html = helper.dashboard_filter_link("All Runs", "/dashboard", true)

      link = Nokogiri::HTML.fragment(html).at_css("a")
      expect(link["aria-current"]).to eq("page")
      expect(link["class"]).to eq(helper.filter_button_classes(true))
    end

    # @spec DASHBOARD-FILTER-A11Y-001
    it "omits aria-current when inactive" do
      html = helper.dashboard_filter_link("All Runs", "/dashboard", false)

      link = Nokogiri::HTML.fragment(html).at_css("a")
      expect(link.attribute("aria-current")).to be_nil
      expect(link["class"]).to eq(helper.filter_button_classes(false))
    end

    it "preserves additional link options such as data attributes" do
      html = helper.dashboard_filter_link("All Runs", "/dashboard", true, data: { turbo_frame: "_top" })

      link = Nokogiri::HTML.fragment(html).at_css("a")
      expect(link["data-turbo-frame"]).to eq("_top")
    end
  end

  describe "#dashboard_chart_colors" do
    # @spec DASHBOARD-CHART-A11Y-010
    it "sources duration_trend colors from dedicated tokens, not generic ones with different hex values" do
      expect(helper.dashboard_chart_colors(:duration_trend)).to eq(%w[
        var(--dashboard-chart-accent)
        var(--dashboard-chart-duration-median)
        var(--dashboard-chart-duration-trend)
      ])
    end

    # @spec DASHBOARD-CHART-A11Y-010
    it "sources pr_cycle_time colors from dedicated tokens, not generic ones with different hex values" do
      expect(helper.dashboard_chart_colors(:pr_cycle_time)).to eq(%w[
        var(--dashboard-chart-pr-cycle-average)
        var(--dashboard-chart-pr-cycle-median)
        var(--dashboard-chart-pr-cycle-trend)
      ])
    end
  end

  describe "#dashboard_outcome_chart_colors" do
    # @spec DASHBOARD-CHART-A11Y-010
    it "sources the rate_limited color from a dedicated token, not the shared warning token" do
      colors = helper.dashboard_outcome_chart_colors([ { name: "rate_limited" } ])

      expect(colors).to eq(%w[var(--dashboard-chart-rate-limited)])
    end
  end
end
