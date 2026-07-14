# frozen_string_literal: true

require "rails_helper"

RSpec.describe "projects/_trace_viewer", :no_db, type: :view do
  context "when a trace is available" do
    let(:embed_url) { "https://example.test/trace-viewer/index.html&trace=encoded" }

    it "renders the trace viewer iframe pointing at the embed URL" do
      render partial: "projects/trace_viewer", locals: { available: true, embed_url: embed_url }

      expect(rendered).to have_selector("iframe[src='#{embed_url}']")
      expect(rendered).to have_selector("[data-testid='trace-viewer']")
      expect(rendered).to include("Open in new tab")
    end

    it "shows a loading indicator while the viewer boots" do
      render partial: "projects/trace_viewer", locals: { available: true, embed_url: embed_url }

      expect(rendered).to have_selector("[data-testid='trace-viewer-loading']")
      expect(rendered).to include("Loading trace viewer")
    end
  end

  context "when a trace is unavailable" do
    it "renders a graceful degradation message instead of an iframe" do
      render partial: "projects/trace_viewer", locals: { available: false, embed_url: nil }

      expect(rendered).to have_selector("[data-testid='trace-viewer-unavailable']")
      expect(rendered).to include("No trace available")
      expect(rendered).not_to have_selector("iframe")
    end
  end

  context "when availability is inferred from the embed URL" do
    it "treats a present embed URL as available" do
      render partial: "projects/trace_viewer", locals: { embed_url: "https://example.test/viewer" }

      expect(rendered).to have_selector("iframe")
    end

    it "treats a blank embed URL as unavailable" do
      render partial: "projects/trace_viewer", locals: { embed_url: nil }

      expect(rendered).to have_selector("[data-testid='trace-viewer-unavailable']")
    end
  end
end
