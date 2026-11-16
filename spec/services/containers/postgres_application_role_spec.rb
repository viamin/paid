# frozen_string_literal: true

require "rails_helper"

# @spec CONTAINER-RUNTIME-052 POSTGRESQL-PERSISTENCE-006
RSpec.describe Containers::PostgresApplicationRole do
  let(:service) { build_stubbed(:service_container, env: { "POSTGRES_PASSWORD" => "bootstrap-secret" }) }

  it "keeps retries stable while separating concurrent run credentials from bootstrap" do
    first = described_class.credentials_for(service, "agent_run_1_attempt_0")
    second = described_class.credentials_for(service, "agent_run_2_attempt_0")

    expect(described_class.credentials_for(service, "agent_run_1_attempt_0")).to eq(first)
    expect(first[:user]).to match(/\Apaid_app_[0-9a-f]{24}\z/)
    expect(second[:user]).not_to eq(first[:user])
    expect(first[:password]).to match(/\A[0-9a-f]{64}\z/)
    expect(second[:password]).not_to eq(first[:password])
    expect(first[:password]).not_to eq("bootstrap-secret")
  end

  it "does not expose credential-bearing transport errors" do
    backend = instance_double(Containers::Backends::LocalDocker)
    container = instance_double(Docker::Container)
    allow(backend).to receive(:exec_in_container).and_raise(Docker::Error::DockerError, "secret SQL")

    expect do
      described_class.provision!(service_container: service, database_name: "agent_run_1_attempt_0",
        backend:, container:, admin_user: "bootstrap", admin_database: "postgres")
    end.to raise_error(Containers::ServiceProvisioner::DatabaseError, "PostgreSQL application role transport failed")
  end

  it "refuses to demote the bootstrap role if its name collides with the application role" do
    backend = instance_double(Containers::Backends::LocalDocker)
    container = instance_double(Docker::Container)
    expect(backend).not_to receive(:exec_in_container)
    role = described_class.credentials_for(service, "agent_run_1_attempt_0").fetch(:user)

    expect do
      described_class.provision!(service_container: service, database_name: "agent_run_1_attempt_0",
        backend:, container:, admin_user: role, admin_database: "postgres")
    end.to raise_error(Containers::ServiceProvisioner::DatabaseError, "PostgreSQL application and bootstrap roles must differ")
  end
end
