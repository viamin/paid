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

    it "expands auto to WEB_CONCURRENCY_AUTO when set" do
      ENV["WEB_CONCURRENCY"] = "auto"
      ENV["WEB_CONCURRENCY_AUTO"] = "3"
      expect(loaded_options[:workers]).to eq(3)
    end

    it "expands auto to the available processor count when WEB_CONCURRENCY_AUTO is unset" do
      ENV["WEB_CONCURRENCY"] = "auto"
      require "concurrent"
      expect(loaded_options[:workers]).to eq(Integer(Concurrent.available_processor_count))
    end

    it "ignores WEB_CONCURRENCY_AUTO without WEB_CONCURRENCY=auto" do
      ENV["WEB_CONCURRENCY_AUTO"] = "3"
      expect(loaded_options[:workers]).to eq(0)
    end
  end

  describe "preload_app" do
    it "is enabled via RAILS_PRELOAD_APP" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      expect(loaded_options[:preload_app]).to be(true)
    end
  end

  describe "before_worker_boot hook" do
    let(:hook_key) { :before_worker_boot }

    def hook_blocks
      config = Puma::Configuration.new(config_files: Array(Rails.root.join("config/puma.rb").to_s))
      config.load
      config.clamp
      config.options.all_of(hook_key).map { |entry| entry[:block] }
    end

    it "is registered when RAILS_PRELOAD_APP=true and WEB_CONCURRENCY >= 2" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      ENV["WEB_CONCURRENCY"] = "4"
      expect(hook_blocks).not_to be_empty
    end

    it "is registered when RAILS_PRELOAD_APP=true and WEB_CONCURRENCY=auto with WEB_CONCURRENCY_AUTO override >= 2" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      ENV["WEB_CONCURRENCY"] = "auto"
      ENV["WEB_CONCURRENCY_AUTO"] = "2"
      expect(hook_blocks).not_to be_empty
    end

    it "is not registered when RAILS_PRELOAD_APP=true but WEB_CONCURRENCY is unset (single mode)" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      expect(hook_blocks).to be_empty
    end

    it "is not registered when WEB_CONCURRENCY=auto without an override (CPU count unknown)" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      ENV["WEB_CONCURRENCY"] = "auto"
      expect(hook_blocks).to be_empty
    end

    it "is not registered when RAILS_PRELOAD_APP=true and WEB_CONCURRENCY_AUTO=1" do
      ENV["RAILS_PRELOAD_APP"] = "true"
      ENV["WEB_CONCURRENCY"] = "auto"
      ENV["WEB_CONCURRENCY_AUTO"] = "1"
      expect(hook_blocks).to be_empty
    end

    it "is not registered when RAILS_PRELOAD_APP is unset" do
      ENV["WEB_CONCURRENCY"] = "4"
      expect(hook_blocks).to be_empty
    end
  end
end
