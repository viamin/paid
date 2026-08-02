# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Registry do
  describe ".all" do
    it "returns an empty array by default (no checks registered in phase 1)" do
      expect(described_class.all).to eq([])
    end
  end

  describe ".for_scope" do
    it "returns an empty array when no checks are registered" do
      expect(described_class.for_scope(:project)).to eq([])
      expect(described_class.for_scope(:user)).to eq([])
      expect(described_class.for_scope(:runner)).to eq([])
    end
  end

  describe ".local_for_scope" do
    it "returns an empty array when no checks are registered" do
      expect(described_class.local_for_scope(:project)).to eq([])
    end
  end

  describe ".register" do
    it "adds a check class to the registry" do
      fake_check = Class.new(HealthChecks::Check) do
        def self.scope = :project
        def self.network? = false
        def call(subject) = []
      end

      described_class.register(fake_check)

      expect(described_class.for_scope(:project)).to include(fake_check)

      described_class.instance_variable_set(:@registry, [])
      described_class.instance_variable_set(:@defaults_loaded, false)
    end
  end
end
