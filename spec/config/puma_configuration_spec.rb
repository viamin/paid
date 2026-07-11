# frozen_string_literal: true

require "rails_helper"
require "puma"
require "puma/configuration"
require "puma/cluster"

class PumaConfiguration < Pathname
end

RSpec.describe PumaConfiguration, :no_db do
  let(:puma_env_keys) do
    %w[
      WEB_CONCURRENCY
      WEB_CONCURRENCY_AUTO
      RAILS_PRELOAD_APP
      WORKER_TIMEOUT
      WORKER_SHUTDOWN_TIMEOUT
      RAILS_MAX_THREADS
    ]
  end

  around do |example|
    saved = ENV.to_h.slice(*puma_env_keys)
    puma_env_keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    puma_env_keys.each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
  end

  def loaded_options
    config = Puma::Configuration.new(config_files: Array(Rails.root.join("config/puma.rb").to_s))
    config.load
    config.clamp
    config.options
  end

  it "loads config/puma.rb without error" do
    expect { loaded_options }.not_to raise_error
  end

  describe "default behavior (development unchanged)" do
    it "runs a single worker" do
      expect(loaded_options[:workers]).to eq(0)
    end

    it "does not preload the app" do
      expect(loaded_options[:preload_app]).to be(false)
    end
  end

  describe "worker_timeout" do
    it "defaults to a generous 3600 seconds" do
      expect(loaded_options[:worker_timeout]).to eq(3600)
    end

    it "is configurable via WORKER_TIMEOUT" do
      ENV["WORKER_TIMEOUT"] = "600"
      expect(loaded_options[:worker_timeout]).to eq(600)
    end
  end

  describe "worker_shutdown_timeout" do
    it "defaults to 30 seconds" do
      expect(loaded_options[:worker_shutdown_timeout]).to eq(30)
    end

    it "is configurable via WORKER_SHUTDOWN_TIMEOUT" do
      ENV["WORKER_SHUTDOWN_TIMEOUT"] = "45"
      expect(loaded_options[:worker_shutdown_timeout]).to eq(45)
    end
  end

  describe "multi-worker via WEB_CONCURRENCY" do
    it "runs an explicit worker count" do
      ENV["WEB_CONCURRENCY"] = "2"
      expect(loaded_options[:workers]).to eq(2)
    end

    it "expands auto to WEB_CONCURRENCY_AUTO workers" do
      ENV["WEB_CONCURRENCY"] = "auto"
      ENV["WEB_CONCURRENCY_AUTO"] = "3"
      expect(loaded_options[:workers]).to eq(3)
    end

    it "defaults auto to 2 workers" do
      ENV["WEB_CONCURRENCY"] = "auto"
      expect(loaded_options[:workers]).to eq(2)
    end
  end

  describe "preload_app" do
    it "is enabled via RAILS_PRELOAD_APP" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      expect(loaded_options[:preload_app]).to be(true)
    end
  end
end
