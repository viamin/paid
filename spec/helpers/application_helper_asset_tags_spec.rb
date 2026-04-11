# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationHelper do
  describe "#safe_stylesheet_link_tag" do
    it "returns nil in test when Propshaft cannot find the asset" do
      allow(helper).to receive(:stylesheet_link_tag).and_raise(Propshaft::MissingAssetError.new("missing"))

      expect(helper.safe_stylesheet_link_tag("application")).to be_nil
    end
  end

  describe "#safe_javascript_include_tag" do
    it "returns nil in test when Propshaft cannot find the asset" do
      allow(helper).to receive(:javascript_include_tag).and_raise(Propshaft::MissingAssetError.new("missing"))

      expect(helper.safe_javascript_include_tag("application")).to be_nil
    end
  end
end
