# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::Backends::Resolver, :no_db do
  after do
    described_class.reset!
  end

  describe ".register" do
    it "stores factories keyed by backend type" do
      backend = instance_double(Containers::Backends::Base)
      factory = -> { backend }

      described_class.register(:local, factory)

      expect(described_class.for(:local)).to eq(backend)
    end

    it "rejects non-callable factories" do
      expect {
        described_class.register(:local, Object.new)
      }.to raise_error(ArgumentError, /Factory must respond to #call/)
    end

    it "supports replacing one backend without clearing others" do
      local_backend = instance_double(Containers::Backends::Base, identifier: "local")
      remote_backend = instance_double(Containers::Backends::Base, identifier: "remote")

      described_class.register(:local, -> { local_backend })
      described_class.register(:remote, -> { remote_backend })

      described_class.reset!(:local)
      described_class.register(:local, -> { local_backend })

      expect(described_class.for(:local)).to eq(local_backend)
      expect(described_class.for(:remote)).to eq(remote_backend)
    end
  end

  describe ".for" do
    it "raises for unknown backends" do
      expect {
        described_class.for(:missing)
      }.to raise_error(described_class::UnknownBackendError, /missing/)
    end
  end
end
