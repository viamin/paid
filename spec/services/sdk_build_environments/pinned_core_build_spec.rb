# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "tmpdir"

RSpec.describe SdkBuildEnvironments::PinnedCoreBuild do
  let(:backend) { instance_double(Containers::Backends::LocalDocker, identifier: "local") }
  let(:container) { instance_double(Docker::Container) }
  let(:facts) do
    {
      backend_identifier: "local", engine_architecture: "arm64",
      image: { reference: SdkBuildEnvironments::Pins.default_image_reference, id: "sha256:image", digest: "sha256:digest", platform: "arm64" },
      process_architecture: "aarch64",
      toolchains: [
        { command: "cargo", path: "/usr/local/cargo/bin/cargo", interpreter_path: "/lib/ld-linux-aarch64.so.1", execution_status: 0 },
        { command: "rustc", path: "/usr/local/cargo/bin/rustc", interpreter_path: "/lib/ld-linux-aarch64.so.1", execution_status: 0 }
      ]
    }
  end
  let(:probe) { class_double(SdkBuildEnvironments::MetadataProbe, call: facts) }

  # @spec RUST-SDK-BUILD-013
  it "executes the pinned source layout in a bounded isolated build and check" do
    stub_successful_build

    receipt = described_class.call(backend:, probe:)

    expect_bounded_build
    expect_offline_check
    expect_pinned_command_to_execute(receipt.fetch(:command))
    expect(receipt).to include(exit_status: 0, cleanup: { container_removed: true, image_removed: true })
  end

  # @spec RUST-SDK-BUILD-013
  it "refuses the build before image creation when preflight is incompatible" do
    facts[:process_architecture] = "amd64"
    allow(backend).to receive(:build_image)

    expect { described_class.call(backend:, probe:) }.to raise_error(described_class::IncompatibleEnvironmentError)
    expect(backend).not_to have_received(:build_image)
  end

  # @spec RUST-SDK-BUILD-013
  it "removes the temporary image when container cleanup fails" do
    stub_successful_build
    allow(backend).to receive(:delete_container).and_raise(Docker::Error::DockerError, "container gone")

    expect { described_class.call(backend:, probe:) }.to raise_error(Docker::Error::DockerError, "container gone")
    expect(backend).to have_received(:delete_image)
  end

  # @spec RUST-SDK-BUILD-013
  it "attempts temporary image cleanup when the bounded image build fails" do
    allow(backend).to receive(:build_image).and_raise(Docker::Error::DockerError, "build interrupted")
    allow(backend).to receive(:delete_image)

    expect { described_class.call(backend:, probe:) }.to raise_error(Docker::Error::DockerError, "build interrupted")
    expect(backend).to have_received(:delete_image).with(
      a_string_starting_with("paid-sdk-core-build-"),
      deadline: be_between(1, described_class::BUILD_DEADLINE_SECONDS),
      force: true
    )
  end

  def stub_successful_build
    allow(backend).to receive_messages(
      build_image: nil,
      create_container: container,
      start_container: nil,
      exec_in_container: [ "checked", "", 0 ],
      delete_container: nil,
      delete_image: nil
    )
  end

  def expect_bounded_build
    expect(backend).to have_received(:build_image).with(
      a_string_including(
        "libclang-18-dev=1:18.1.3-1ubuntu1",
        "/usr/lib/llvm-18/lib/libclang.so.1",
        "temporalio/ext/sdk-core",
        "/sdk/temporalio/Cargo.lock",
        "cd /sdk/temporalio && cargo fetch --locked"
      ),
      hash_including(
        rm: true,
        forcerm: true,
        memory: 4.gigabytes,
        memswap: 4.gigabytes,
        cpuperiod: 100_000,
        cpuquota: 200_000,
        ulimits: [ { Name: "nproc", Soft: 256, Hard: 256 } ]
      ),
      deadline: be_between(1, described_class::BUILD_DEADLINE_SECONDS)
    )
  end

  def expect_offline_check
    expect(backend).to have_received(:create_container).with(hash_including("NetworkDisabled" => true), deadline: 900)
    expect(backend).to have_received(:exec_in_container).with(
      container,
      [ "sh", "-lc", "cd /sdk/temporalio && cargo check --locked --offline --package temporalio-sdk-core" ],
      hash_including(wait: be_between(1, described_class::BUILD_DEADLINE_SECONDS))
    )
  end

  def expect_pinned_command_to_execute(command)
    Dir.mktmpdir do |directory|
      workspace = File.join(directory, "sdk", "temporalio")
      FileUtils.mkdir_p(File.join(workspace, "ext", "sdk-core"))
      File.write(File.join(workspace, "Cargo.toml"), "[workspace]\n")
      File.write(File.join(workspace, "Cargo.lock"), "version = 4\n")
      cargo = File.join(directory, "cargo")
      File.write(cargo, <<~SH)
        #!/bin/sh
        test "$PWD" = "$EXPECTED_WORKSPACE" &&
          test -f Cargo.toml &&
          test -f Cargo.lock &&
          test -d ext/sdk-core &&
          test "$*" = "check --locked --offline --package temporalio-sdk-core"
      SH
      FileUtils.chmod("+x", cargo)

      executable_command = command.map { |argument| argument.gsub("/sdk", File.join(directory, "sdk")) }
      expect(system({ "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "EXPECTED_WORKSPACE" => workspace }, *executable_command)).to be(true)
    end
  end
end
