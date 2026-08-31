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
end
