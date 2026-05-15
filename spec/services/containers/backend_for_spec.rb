# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers, ".backend_for", :no_db do
  let(:local_backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local") }

  before do
    allow(described_class).to receive(:backend).and_return(local_backend)
  end

  it "returns the process-global backend when host is nil" do
    expect(described_class.backend_for(nil)).to eq(local_backend)
  end

  it "returns the process-global backend when host is blank" do
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
