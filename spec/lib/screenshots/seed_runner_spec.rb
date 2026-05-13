# frozen_string_literal: true

require "rails_helper"
require "screenshots/seed_runner"

RSpec.describe Screenshots::SeedRunner do
  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end

  def install_seed_script_fakes(with_tenant_context: true)
    if with_tenant_context
      stub_const("TenantContext", Class.new do
        def self.with_system_access
          yield
        end
      end)
    elsif Object.const_defined?(:TenantContext)
      hide_const("TenantContext")
    end

    stub_const("FakeSeedRecord", Struct.new(:attributes))
    stub_const("Screenshots::SeedData::Fake", Class.new do
      def self.call
        scalar_record
      end

      def self.scalar_record
        ::FakeSeedRecord.new({ "id" => 1, "username" => "screenshot", "admin" => true, "metadata" => { "ignored" => true } })
      end
    end)
  end

  def run_seed_script(config)
    ENV["SCREENSHOT_SEED_CONFIG"] = JSON.generate(config)
    output = capture_stdout do
      eval(described_class::SCRIPT, binding, "screenshots_seed_runner_spec", 1)
    end
    JSON.parse(output)
  ensure
    ENV.delete("SCREENSHOT_SEED_CONFIG")
  end

  let(:config) do
    Screenshots::Configuration.from_hash(
      "driver" => "cuprite",
      "routes" => [ { "path" => "/", "name" => "home" } ],
      "seed" => [
        {
          "key" => "__all__",
          "runner" => "Screenshots::SeedData::Paid.call"
        }
      ]
    )
  end

  it "expands composite runner output into open structs keyed by seed name" do
    stdout = JSON.generate(
      "user" => { "id" => 1, "email" => "screenshot@example.com", "password" => "secret" },
      "project" => { "id" => 2, "name" => "Paid" }
    )
    allow(Open3).to receive(:capture3).and_return([ stdout, "", instance_double(Process::Status, success?: true) ])

    result = described_class.new.call(config:, repo_path: Rails.root.to_s, driver_name: "cuprite")

    expect(result[:user].email).to eq("screenshot@example.com")
    expect(result[:project].id).to eq(2)
  end

  it "preserves scalar runner output values" do
    stdout = JSON.generate(
      "user" => { "id" => 1, "email" => "screenshot@example.com" },
      "password" => "secret"
    )
    allow(Open3).to receive(:capture3).and_return([ stdout, "", instance_double(Process::Status, success?: true) ])

    result = described_class.new.call(config:, repo_path: Rails.root.to_s, driver_name: "cuprite")

    expect(result[:user].email).to eq("screenshot@example.com")
    expect(result[:password]).to eq("secret")
  end

  it "skips seed execution for non-cuprite drivers" do
    result = described_class.new.call(config:, repo_path: Rails.root.to_s, driver_name: "playwright")

    expect(result).to eq({})
  end

  it "serializes all scalar record attributes for interpolation" do
    install_seed_script_fakes
    result = run_seed_script([ { "key" => "user", "runner" => "Screenshots::SeedData::Fake.call" } ])

    expect(result.fetch("user")).to include(
      "id" => 1,
      "username" => "screenshot",
      "admin" => true
    )
    expect(result.fetch("user")).not_to have_key("metadata")
  end

  it "runs without TenantContext when used outside Paid" do
    install_seed_script_fakes(with_tenant_context: false)

    result = run_seed_script([ { "key" => "user", "runner" => "Screenshots::SeedData::Fake.call" } ])

    expect(result.fetch("user")).to include("id" => 1, "username" => "screenshot")
  end

  it "rejects arbitrary ruby runner strings" do
    install_seed_script_fakes

    expect {
      run_seed_script([ { "key" => "user", "runner" => "system('rm -rf /')" } ])
    }.to raise_error(ArgumentError, /Screenshots::SeedData::<Runner>\.call/)
  end
end
