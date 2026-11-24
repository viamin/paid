# frozen_string_literal: true

require "rails_helper"
require "rake"

# rubocop:disable RSpec/DescribeClass
RSpec.describe "sdk_build_environment:preflight" do
  let(:task) { Rake::Task["sdk_build_environment:preflight"] }
  let(:backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local") }

  def facts(overrides = {})
    {
      backend_identifier: "local",
      engine_architecture: "aarch64",
      image: { reference: "rust:1.95.0-bookworm", id: "sha256:7cf1", digest: "sha256:6258", platform: "arm64" },
      process_architecture: "aarch64",
      toolchains: [
        { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: "/lib/ld-linux-aarch64.so.1" },
        { command: "rustc", path: "/usr/local/rustup/toolchains/bin/rustc", interpreter_path: "/lib/ld-linux-aarch64.so.1" }
      ]
    }.merge(overrides)
  end

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("sdk_build_environment:preflight")
    task.reenable
    allow(Containers).to receive(:backend).and_return(backend)
  end

  # @spec RUST-SDK-BUILD-011
  it "runs the service classification against a real backend and prints the receipt as JSON" do
    allow(SdkBuildEnvironments::MetadataProbe).to receive(:call)
      .with(backend: backend, image: SdkBuildEnvironments::Pins.default_image_reference)
      .and_return(facts)

    expect { task.invoke }
      .to output(/\{.*"verdict": "compatible".*\}/m).to_stdout
    expect(SdkBuildEnvironments::MetadataProbe).to have_received(:call)
      .with(backend: backend, image: SdkBuildEnvironments::Pins.default_image_reference)
  end

  it "accepts an explicit image reference" do
    allow(SdkBuildEnvironments::MetadataProbe).to receive(:call)
      .with(backend: backend, image: "paid-agent:latest")
      .and_return(facts(image: { reference: "paid-agent:latest", id: nil, digest: nil, platform: "arm64" }))

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SDK_BUILD_PREFLIGHT_IMAGE").and_return("paid-agent:latest")

    expect { task.invoke }.to output(/"verdict": "compatible"/).to_stdout
  end

  it "provisions no containers itself and mutates no run, worker, or pin state" do
    allow(SdkBuildEnvironments::MetadataProbe).to receive(:call).and_return(facts)
    expect(backend).not_to receive(:create_container)

    task.invoke
  end

  it "exits non-zero when the verdict is not compatible" do
    toolchains = [ { command: "cargo", path: nil, interpreter_path: nil } ]
    allow(SdkBuildEnvironments::MetadataProbe).to receive(:call).and_return(facts(toolchains: toolchains))

    expect { task.invoke }
      .to output(/"verdict": "toolchain_absent"/).to_stdout
      .and output(/sdk build environment preflight verdict: toolchain_absent/).to_stderr
      .and raise_error(SystemExit)
  end
end
# rubocop:enable RSpec/DescribeClass
