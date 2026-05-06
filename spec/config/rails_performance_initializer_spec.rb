# frozen_string_literal: true

require "rails_helper"

RailsPerformanceInitializer = Class.new unless defined?(RailsPerformanceInitializer)
unless defined?(RailsPerformanceInitializerConfig)
  RailsPerformanceInitializerConfig = Class.new do
    attr_writer :redis, :duration, :ignored_paths, :enabled
  end
end
unless defined?(RedisClientConnection)
  RedisClientConnection = Class.new do
    def ping
    end
  end
end

RSpec.describe RailsPerformanceInitializer, :no_db do
  let(:initializer_path) { Rails.root.join("config/initializers/rails_performance.rb") }
  let(:config) { instance_double(RailsPerformanceInitializerConfig) }
  let(:redis_client) { instance_double(RedisClientConnection) }
  let(:rails_performance_module) do
    Module.new do
      def self.setup
      end
    end
  end
  let(:redis_error_class) { Class.new(StandardError) }
  let(:redis_client_error_class) { Class.new(StandardError) }
  let(:redis_class) do
    Class.new do
      def self.new(*)
      end
    end
  end

  before do
    stub_const("RailsPerformance", rails_performance_module)
    stub_const("Redis", redis_class)
    stub_const("Redis::CannotConnectError", redis_error_class)
    stub_const("RedisClient", Module.new)
    stub_const("RedisClient::CannotConnectError", redis_client_error_class)
    allow(RailsPerformance).to receive(:setup).and_yield(config)
    allow(config).to receive(:redis=)
    allow(config).to receive(:duration=)
    allow(config).to receive(:ignored_paths=)
    allow(config).to receive(:enabled=)
    allow(Redis).to receive(:new).and_return(redis_client)
    allow(redis_client).to receive(:ping).and_return("PONG")
    allow(ENV).to receive(:fetch).and_call_original
    allow(Rails.logger).to receive(:warn)
  end

  it "defaults REDIS_URL for local development when the env var is absent" do
    allow(ENV).to receive(:fetch).with("REDIS_URL", "redis://127.0.0.1:6379/0").and_return("redis://127.0.0.1:6379/0")

    load initializer_path

    expect(Redis).to have_received(:new).with(url: "redis://127.0.0.1:6379/0")
    expect(config).to have_received(:duration=).with(4.hours)
    expect(config).to have_received(:ignored_paths=).with([ "/rails/performance" ])
    expect(config).to have_received(:enabled=).with(true)
  end

  it "uses REDIS_URL when explicitly configured" do
    allow(ENV).to receive(:fetch).with("REDIS_URL", "redis://127.0.0.1:6379/0").and_return("redis://example.test:6379/5")

    load initializer_path

    expect(Redis).to have_received(:new).with(url: "redis://example.test:6379/5")
    expect(config).to have_received(:enabled=).with(true)
  end

  it "disables rails_performance when Redis is unavailable" do
    allow(ENV).to receive(:fetch).with("REDIS_URL", "redis://127.0.0.1:6379/0").and_return("redis://127.0.0.1:6379/0")
    allow(redis_client).to receive(:ping).and_raise(Redis::CannotConnectError.new("Connection refused"))

    load initializer_path

    expect(config).to have_received(:redis=).with(redis_client)
    expect(config).to have_received(:enabled=).with(false)
    expect(Rails.logger).to have_received(:warn).with(
      message: "rails_performance.disabled",
      redis_url: "redis://127.0.0.1:6379/0",
      error_class: "Redis::CannotConnectError",
      error_message: "Connection refused"
    )
  end
end
