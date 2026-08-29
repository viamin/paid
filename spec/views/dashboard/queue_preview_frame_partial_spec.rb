# frozen_string_literal: true

require "rails_helper"

RSpec.describe "dashboard/_queue_preview_frame", :no_db, type: :view do
  it "renders the skeleton placeholder motion-safe when only src is provided" do # @spec DASHBOARD-FRAME-CACHE-008
    render partial: "dashboard/queue_preview_frame", locals: { src: "/dashboard/queue-preview" }

    skeleton = Nokogiri::HTML.fragment(rendered).at_css("#dashboard-queue-preview > div")

    expect(skeleton).to be_present
    expect(skeleton["class"]).to include("motion-safe:animate-pulse")
    expect(skeleton["class"]).to include("motion-reduce:animate-none")
  end
end
