# frozen_string_literal: true

require "rails_helper"

class CapybaraTenantContextFile < Pathname
end

RSpec.describe CapybaraTenantContextFile, :no_db do
  # @spec POSTGRESQL-PERSISTENCE-012
  it "initializes browser-server connections before Warden deserializes the session user" do
    source = Rails.root.join("spec/support/capybara.rb").read

    expect(source).to include("Rails.application.executor.to_run { TenantContext.apply_system_access! }")
  end

  # @spec POSTGRESQL-PERSISTENCE-012
  it "applies system access when the application executor begins a request" do
    allow(TenantContext).to receive(:apply_system_access!)

    Rails.application.executor.wrap { }

    expect(TenantContext).to have_received(:apply_system_access!)
  end
end
