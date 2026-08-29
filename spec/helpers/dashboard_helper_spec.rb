# frozen_string_literal: true

require "rails_helper"

RSpec.describe DashboardHelper, :no_db do
  describe "#dashboard_chartkick_chart" do
    # @spec DASHBOARD-CHART-A11Y-001
    it "hides the chart canvas from assistive tech and renders an adjacent data table" do
      html = helper.dashboard_chartkick_chart("ColumnChart", [
        { name: "Completed", data: { Date.new(2026, 1, 1) => 3, Date.new(2026, 1, 2) => 5 } }
      ], id: "test-chart")

      fragment = Nokogiri::HTML.fragment(html)
      chart_div = fragment.at_css("#test-chart")
      table = fragment.at_css("table")

      expect(chart_div["aria-hidden"]).to eq("true")
      expect(table["class"]).to eq("sr-only")
    end

    # @spec DASHBOARD-CHART-A11Y-002
    it "builds one column per series and one row per x-axis label for multi-series data" do
      html = helper.dashboard_chartkick_chart("ColumnChart", [
        { name: "Completed", data: { "2026-01-01" => 3, "2026-01-02" => 5 } },
        { name: "Failed", data: { "2026-01-01" => 1, "2026-01-02" => 0 } }
      ])

      table = Nokogiri::HTML.fragment(html).at_css("table")
      headers = table.css("thead th").map(&:text)
      rows = table.css("tbody tr").map { |tr| tr.css("th, td").map(&:text) }

      expect(headers).to eq([ "", "Completed", "Failed" ])
      expect(rows).to eq([
        [ "2026-01-01", "3", "1" ],
        [ "2026-01-02", "5", "0" ]
      ])
    end

    # @spec DASHBOARD-CHART-A11Y-002
    it "includes columns for series that are absent from the first x-axis label" do
      html = helper.dashboard_chartkick_chart("ColumnChart", [
        { name: "Completed", data: { "2026-01-01" => 3, "2026-01-02" => 5, "2026-01-03" => 2 } },
        { name: "Failed", data: { "2026-01-03" => 1 } }
      ])

      table = Nokogiri::HTML.fragment(html).at_css("table")
      headers = table.css("thead th").map(&:text)
      rows = table.css("tbody tr").map { |tr| tr.css("th, td").map(&:text) }

      expect(headers).to eq([ "", "Completed", "Failed" ])
      expect(rows).to eq([
        [ "2026-01-01", "3", "No data" ],
        [ "2026-01-02", "5", "No data" ],
        [ "2026-01-03", "2", "1" ]
      ])
    end

    # @spec DASHBOARD-CHART-A11Y-003
    it "renders a single Value column for a bare hash data source" do
      html = helper.dashboard_chartkick_chart("LineChart", { "2026-01-01" => 92.5, "2026-01-02" => 88.0 })

      headers = Nokogiri::HTML.fragment(html).at_css("table thead th:not(:first-child)")
      expect(headers.text).to eq("Value")
    end

    # @spec DASHBOARD-CHART-A11Y-004
    it "renders a caption when provided and omits it otherwise" do
      with_caption = helper.dashboard_chartkick_chart("LineChart", { "2026-01-01" => 1 }, caption: "Daily total")
      without_caption = helper.dashboard_chartkick_chart("LineChart", { "2026-01-01" => 1 })

      expect(Nokogiri::HTML.fragment(with_caption).at_css("table caption").text).to eq("Daily total")
      expect(Nokogiri::HTML.fragment(without_caption).at_css("table caption")).to be_nil
    end

    # @spec DASHBOARD-CHART-A11Y-005
    it "renders nil values as 'No data' instead of a blank cell" do
      html = helper.dashboard_chartkick_chart("LineChart", { "2026-01-01" => nil, "2026-01-02" => 4 })

      cells = Nokogiri::HTML.fragment(html).css("tbody td").map(&:text)
      expect(cells).to eq([ "No data", "4" ])
    end

    it "formats numeric values with thousands delimiters" do
      html = helper.dashboard_chartkick_chart("LineChart", { "2026-01-01" => 12_345 })

      cell = Nokogiri::HTML.fragment(html).at_css("tbody td")
      expect(cell.text).to eq("12,345")
    end
  end
end
