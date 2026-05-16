# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers, ".all_backends", :no_db do
  let(:local_backend) { instance_double(Containers::Backends::Base, identifier: "local", remote?: false) }
  let(:remote_backend) { instance_double(Containers::Backends::Base, identifier: "worker-1", remote?: true) }
  let(:swarm_backend) { instance_double(Containers::Backends::Base, identifier: "swarm", remote?: false) }

  before do
    allow(described_class).to receive(:backend).and_return(local_backend)
    allow(Containers::Backends::Resolver).to receive(:for).with(:local).and_return(local_backend)
    allow(Containers::Backends::Resolver).to receive(:for).with(:remote).and_return(remote_backend)
    allow(Containers::Backends::Resolver).to receive(:for).with(:swarm).and_return(swarm_backend)
  end

  it "returns the active local backend and a configured remote backend once" do
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local, :remote, :swarm ])

    expect(described_class.all_backends).to eq([ local_backend, remote_backend ])
  end

  it "deduplicates the active backend when it is already local" do
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local, :remote ])

    expect(described_class.all_backends.count { |backend| backend == local_backend }).to eq(1)
  end

  it "returns the active backend when no additional backends are registered" do
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local ])

    expect(described_class.all_backends).to eq([ local_backend ])
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:remote)
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:swarm)
  end

  it "adds the local backend when the active backend is remote" do
    allow(described_class).to receive(:backend).and_return(remote_backend)
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local, :remote ])

    expect(described_class.all_backends).to eq([ remote_backend, local_backend ])
  end

  it "does not fan out to other backend aliases when swarm is active" do
    allow(described_class).to receive(:backend).and_return(swarm_backend)
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local, :remote, :swarm ])

    expect(described_class.all_backends).to eq([ swarm_backend ])
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:local)
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:remote)
  end
end
