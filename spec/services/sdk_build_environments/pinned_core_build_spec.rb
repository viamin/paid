# frozen_string_literal: true

require "rails_helper"

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
  it "builds the fixed source recipe and checks it in a network-disabled container" do
    allow(backend).to receive_messages(
      build_image: nil,
      create_container: container,
      start_container: nil,
      exec_in_container: [ "checked", "", 0 ],
      delete_container: nil,
      delete_image: nil
    )

    receipt = described_class.call(backend:, probe:)

    expect(backend).to have_received(:build_image).with(
      a_string_including("protoc-34.0-linux-aarch_64.zip", "sha256sum --check", "cargo fetch --locked"),
      hash_including(rm: true)
    )
    expect(backend).to have_received(:create_container).with(hash_including("NetworkDisabled" => true), deadline: 900)
    expect(backend).to have_received(:exec_in_container).with(
      container,
      [ "sh", "-lc", "cd /sdk/ext/sdk-core && cargo check --locked --offline --package temporalio-sdk-core" ],
      hash_including(wait: 900)
    )
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
    allow(backend).to receive_messages(
      build_image: nil,
      create_container: container,
      start_container: nil,
      exec_in_container: [ "checked", "", 0 ],
      delete_container: nil,
      delete_image: nil
    )
    allow(backend).to receive(:delete_container).and_raise(Docker::Error::DockerError, "container gone")

    expect { described_class.call(backend:, probe:) }.to raise_error(Docker::Error::DockerError, "container gone")
    expect(backend).to have_received(:delete_image)
  end
end
