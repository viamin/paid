# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::BaseTool do
  describe "system access guard" do
    it "does not allow TenantContext.with_system_access in tool bodies" do
      offending_files = Dir.glob(Rails.root.join("app/mcp/tools/**/*.rb")).filter_map do |path|
        path if File.read(path).include?("TenantContext.with_system_access")
      end

      expect(offending_files).to eq([])
    end
  end
end
