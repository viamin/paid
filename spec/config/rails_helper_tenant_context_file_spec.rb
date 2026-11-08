# frozen_string_literal: true

require "rails_helper"

class RailsHelperTenantContextFile < Pathname
end

RSpec.describe RailsHelperTenantContextFile, :no_db do
  # @spec POSTGRESQL-PERSISTENCE-002
  it "restores system access after each database-backed example" do
    source = Rails.root.join("spec/rails_helper.rb").read
    cleanup = source.match(/config\.around do \|example\|.*?ensure\n(?<body>.*?)\n  end/m)

    expect(cleanup).not_to be_nil
    expect(source).to include("database_available && !example.metadata[:tenant_isolation] && !example.metadata[:no_db]")
    expect(cleanup[:body]).to include("next unless database_available && !example.metadata[:no_db]")
    expect(cleanup[:body]).to include("TenantContext.apply_system_access!")
    expect(cleanup[:body]).not_to include("TenantContext.clear!")
  end
end
