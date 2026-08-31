# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChartkickHelper, :no_db do
  describe "#chartkick_chart via the Chartkick gem helpers" do
    # @spec DASHBOARD-CHART-A11Y-001
    it "hides the chart canvas from assistive tech and renders an adjacent data table" do
      html = helper.column_chart([
        { name: "Completed", data: { Date.new(2026, 1, 1) => 3, Date.new(2026, 1, 2) => 5 } }
      ], id: "test-chart")

      fragment = Nokogiri::HTML.fragment(html)
      chart_div = fragment.at_css("#test-chart")
      table = fragment.at_css("table")

      expect(chart_div["aria-hidden"]).to eq("true")
      expect(chart_div["data-controller"]).to eq("chartkick")
      expect(table["class"]).to eq("sr-only")
    end

    # @spec RUNNERS-INDEX-008
    it "renders Stimulus data attributes with no inline script" do
      html = helper.column_chart({ "2026-01-01" => 3 }, id: "csp-chart", stacked: true)

      fragment = Nokogiri::HTML.fragment(html)
      chart_div = fragment.at_css("#csp-chart")

      expect(chart_div["data-chartkick-type-value"]).to eq("ColumnChart")
      expect(chart_div["data-chartkick-data-value"]).to be_present
      expect(chart_div["data-chartkick-options-value"]).to include("\"stacked\":true")
      expect(fragment.css("script")).to be_empty
    end

    # @spec DASHBOARD-CHART-A11Y-002
    it "builds one column per series and one row per x-axis label for multi-series data" do
      html = helper.column_chart([
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
      html = helper.column_chart([
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
      html = helper.line_chart({ "2026-01-01" => 92.5, "2026-01-02" => 88.0 })

      headers = Nokogiri::HTML.fragment(html).at_css("table thead th:not(:first-child)")
      expect(headers.text).to eq("Value")
    end

    # @spec DASHBOARD-CHART-A11Y-007
    it "treats an Array of [label, value] pairs as a single-series point array" do
      html = helper.line_chart([
        [ "2026-01-01", 0.5 ],
        [ "2026-01-02", 0.6 ],
        [ "2026-01-03", 0.55 ]
      ])

      fragment = Nokogiri::HTML.fragment(html)
      table = fragment.at_css("table")
      headers = table.css("thead th").map(&:text)
      rows = table.css("tbody tr").map { |tr| tr.css("th, td").map(&:text) }

      expect(headers).to eq([ "", "Value" ])
      expect(rows).to eq([
        [ "2026-01-01", "0.5" ],
        [ "2026-01-02", "0.6" ],
        [ "2026-01-03", "0.55" ]
      ])
    end

    # @spec DASHBOARD-CHART-A11Y-007
    it "handles an empty point array without raising" do
      html = helper.column_chart([])

      fragment = Nokogiri::HTML.fragment(html)
      chart_div = fragment.at_css("div")
      expect(chart_div).to be_present
      expect(fragment.at_css("table")).to be_nil
    end

    # @spec DASHBOARD-CHART-A11Y-004
    it "renders a caption when provided and omits it otherwise" do
      with_caption = helper.line_chart({ "2026-01-01" => 1 }, caption: "Daily total")
      without_caption = helper.line_chart({ "2026-01-01" => 1 })

      expect(Nokogiri::HTML.fragment(with_caption).at_css("table caption").text).to eq("Daily total")
      expect(Nokogiri::HTML.fragment(without_caption).at_css("table caption")).to be_nil
    end

    # @spec DASHBOARD-CHART-A11Y-005
    it "renders nil values as 'No data' instead of a blank cell" do
      html = helper.line_chart({ "2026-01-01" => nil, "2026-01-02" => 4 })

      cells = Nokogiri::HTML.fragment(html).css("tbody td").map(&:text)
      expect(cells).to eq([ "No data", "4" ])
    end

    it "formats numeric values with thousands delimiters" do
      html = helper.line_chart({ "2026-01-01" => 12_345 })

      cell = Nokogiri::HTML.fragment(html).at_css("tbody td")
      expect(cell.text).to eq("12,345")
    end

    it "shows the loading placeholder text" do
      html = helper.column_chart({ "2026-01-01" => 1 }, id: "loading-chart")

      expect(Nokogiri::HTML.fragment(html).at_css("#loading-chart").text).to eq("Loading...")
    end

    # @spec DASHBOARD-CHART-A11Y-008
    it "rejects invalid height or width on the default placeholder path" do
      expect {
        helper.column_chart({ "2026-01-01" => 1 }, height: "300px; background:red")
      }.to raise_error(ArgumentError, "Invalid height or width")

      expect {
        helper.column_chart({ "2026-01-01" => 1 }, width: "100%; background:red")
      }.to raise_error(ArgumentError, "Invalid height or width")

      expect {
        helper.column_chart({ "2026-01-01" => 1 }, height: "300px; background:red", html: '<div id="%{id}"></div>')
      }.to raise_error(ArgumentError, "Invalid height or width")
    end

    # @spec DASHBOARD-CHART-A11Y-001
    it "honors a caller-supplied html: placeholder override instead of the default div" do
      html = helper.line_chart({ "2026-01-01" => 1 }, html: '<div id="custom" class="x">X</div>')

      fragment = Nokogiri::HTML.fragment(html)
      custom_div = fragment.at_css("#custom")

      expect(custom_div["class"]).to eq("x")
      expect(custom_div.text).to eq("X")
      expect(fragment.at_css("[data-controller=\"chartkick\"]")).to be_nil
    end

    # @spec DASHBOARD-CHART-A11Y-001
    it "interpolates %{id}/%{height}/%{width}/%{loading} into a custom html: template" do
      html = helper.line_chart(
        { "2026-01-01" => 1 },
        id: "templated-chart",
        loading: "Fetching...",
        html: '<div id="%{id}" data-height="%{height}">%{loading}</div>'
      )

      custom_div = Nokogiri::HTML.fragment(html).at_css("#templated-chart")
      expect(custom_div["data-height"]).to eq("300px")
      expect(custom_div.text).to eq("Fetching...")
    end
  end
end
