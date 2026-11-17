# frozen_string_literal: true

require "rails_helper"

class CapybaraTenantContextFile < Pathname
end

RSpec.describe CapybaraTenantContextFile, :no_db do
  # @spec POSTGRESQL-PERSISTENCE-012
  it "initializes browser-server connections before Warden deserializes the session user" do
    app = instance_double(Proc)
    environment = { "PATH_INFO" => "/" }
    allow(app).to receive(:call).with(environment).and_return([ 200, {}, [] ])
    allow(TenantContext).to receive(:with_system_access).and_yield

    response = CapybaraTenantContext.new(app).call(environment)

    expect(response).to eq([ 200, {}, [] ])
    expect(TenantContext).to have_received(:with_system_access)
    expect(app).to have_received(:call).with(environment)
  end
end
