# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers, ".all_backends", :no_db do
  let(:local_backend) { instance_double(Containers::Backends::Base, identifier: "local") }
  let(:remote_backend) { instance_double(Containers::Backends::Base, identifier: "worker-1") }
  let(:swarm_backend) { instance_double(Containers::Backends::Base, identifier: "swarm") }

  before do
    allow(described_class).to receive(:backend).and_return(local_backend)
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local, :remote, :swarm ])
    allow(Containers::Backends::Resolver).to receive(:for).with(:local).and_return(local_backend)
    allow(Containers::Backends::Resolver).to receive(:for).with(:remote).and_return(remote_backend)
    allow(Containers::Backends::Resolver).to receive(:for).with(:swarm).and_return(swarm_backend)
  end

  it "returns every registered backend once" do
    expect(described_class.all_backends).to eq([ local_backend, remote_backend, swarm_backend ])
  end

  it "deduplicates the active backend when it is already local" do
    expect(described_class.all_backends.count { |backend| backend == local_backend }).to eq(1)
  end

  it "returns the active backend when no additional backends are registered" do
    allow(Containers::Backends::Resolver).to receive(:backend_types).and_return([ :local ])

    expect(described_class.all_backends).to eq([ local_backend ])
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:remote)
    expect(Containers::Backends::Resolver).not_to have_received(:for).with(:swarm)
  end
end
