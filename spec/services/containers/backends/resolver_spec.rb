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
  end

  describe ".for" do
    it "raises for unknown backends" do
      expect {
        described_class.for(:missing)
      }.to raise_error(described_class::UnknownBackendError, /missing/)
    end
  end
end
