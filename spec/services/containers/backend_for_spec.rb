# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers, ".backend_for", :no_db do
  let(:local_backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local", owns_host?: false) }

  before do
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([])
    allow(described_class).to receive(:backend).and_return(local_backend)
  end

  it "returns the process-global backend when host is nil" do
    expect(described_class.backend_for(nil)).to eq(local_backend)
  end

  it "returns the process-global backend when host is blank" do
    expect(described_class.backend_for("")).to eq(local_backend)
  end

  it "returns the process-global backend when host matches the active backend identifier" do
    expect(described_class.backend_for("local")).to eq(local_backend)
  end

  it "returns the process-global backend when the active backend owns the persisted host" do
    allow(local_backend).to receive(:owns_host?).with("worker-1").and_return(true)

    expect(described_class.backend_for("worker-1")).to eq(local_backend)
  end

  it "keeps routing persisted worker hostnames back to the active backend" do
    swarm_backend = instance_double(Containers::Backends::Base, identifier: "swarm", owns_host?: true)
    allow(described_class).to receive(:backend).and_return(swarm_backend)

    expect(described_class.backend_for("worker-1")).to eq(swarm_backend)
  end

  it "routes blank legacy hosts to the local backend even when a remote backend is active" do
    remote_backend = instance_double(Containers::Backends::Base, identifier: "remote", owns_host?: false)
    allow(described_class).to receive(:backend).and_return(remote_backend)
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local ])
    allow(Containers::Backends::Resolver).to receive(:for).with(:local).and_return(local_backend)

    expect(described_class.backend_for(nil)).to eq(local_backend)
    expect(described_class.backend_for("")).to eq(local_backend)
  end

  it "resolves a registered backend by host name" do
    remote_backend = instance_double(Containers::Backends::Base, identifier: "remote")
    Containers::Backends::Resolver.register(:remote, -> { remote_backend })

    expect(described_class.backend_for("remote")).to eq(remote_backend)
  ensure
    Containers::Backends::Resolver.reset!(:remote)
  end

  it "raises for unknown persisted hosts" do
    expect { described_class.backend_for("nonexistent") }
      .to raise_error(Containers::Backends::Resolver::UnknownBackendError, /nonexistent/)
  end
end
