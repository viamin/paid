# frozen_string_literal: true

require "rails_helper"

RailsPerformanceInitializer = Class.new unless defined?(RailsPerformanceInitializer)
unless defined?(RailsPerformanceInitializerConfig)
  RailsPerformanceInitializerConfig = Class.new do
    attr_writer :redis, :duration, :enabled
  end
end

RSpec.describe RailsPerformanceInitializer, :no_db do
  let(:initializer_path) { Rails.root.join("config/initializers/rails_performance.rb") }
  let(:config) { instance_double(RailsPerformanceInitializerConfig) }
  let(:redis_client) { Object.new }
  let(:rails_performance_module) do
    Module.new do
      def self.setup
      end
    end
  end
  let(:redis_class) do
    Class.new do
      def self.new(*)
      end
    end
  end

  before do
    stub_const("RailsPerformance", rails_performance_module)
    stub_const("Redis", redis_class)
    allow(RailsPerformance).to receive(:setup).and_yield(config)
    allow(config).to receive(:redis=)
    allow(config).to receive(:duration=)
    allow(config).to receive(:enabled=)
    allow(Redis).to receive(:new).and_return(redis_client)
    allow(ENV).to receive(:fetch).and_call_original
  end

  it "defaults REDIS_URL for local development when the env var is absent" do
    allow(ENV).to receive(:fetch).with("REDIS_URL", "redis://127.0.0.1:6379/0").and_return("redis://127.0.0.1:6379/0")

    load initializer_path

    expect(Redis).to have_received(:new).with(url: "redis://127.0.0.1:6379/0")
    expect(config).to have_received(:duration=).with(4.hours)
    expect(config).to have_received(:enabled=).with(true)
  end

  it "uses REDIS_URL when explicitly configured" do
    allow(ENV).to receive(:fetch).with("REDIS_URL", "redis://127.0.0.1:6379/0").and_return("redis://example.test:6379/5")

    load initializer_path

    expect(Redis).to have_received(:new).with(url: "redis://example.test:6379/5")
    expect(config).to have_received(:enabled=).with(true)
  end
end
