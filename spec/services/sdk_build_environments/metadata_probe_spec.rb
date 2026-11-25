# frozen_string_literal: true

require "rails_helper"
require "base64"

RSpec.describe SdkBuildEnvironments::MetadataProbe, :no_db do
  let(:container) { instance_double(Docker::Container) }
  let(:probe_calls) { {} }

  def elf64_with_interpreter(interpreter)
    header = [
      "\x7fELF".b, [ 2, 1, 1, 0 ].pack("C4"), "\x00" * 8,
      [ 2, 183, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0 ].pack("vvVQ<Q<Q<Vvvvvvv")
    ].join.b
    program_header = [ 3, 4, 120, 120, 120, interpreter.bytesize + 1, interpreter.bytesize + 1, 1 ]
      .pack("VVQ<Q<Q<Q<Q<Q<")
    (header + program_header + interpreter.b + "\x00".b)
  end

  def script_output(uname:, tools:)
    lines = [ uname ]
    tools.each do |command, path, header_bytes|
      lines << "tool|#{command}|#{path}"
      next if header_bytes.nil?

      lines << "hdr|#{command}|#{Base64.strict_encode64(header_bytes)}"
    end
    lines.join("\n") + "\n"
  end

  def backend_with(exec_stdout:, exec_failure: nil)
    backend = instance_double(Containers::Backends::LocalDocker, identifier: "local")
    image = instance_double(Docker::Image)
    allow(backend).to receive_messages(
      system_info: { "Architecture" => "aarch64" }
    )
    allow(backend).to receive(:get_image).with("rust:1.95.0-bookworm").and_return(image)
    allow(image).to receive(:info).and_return({
      "Id" => "sha256:7cf1e580ef5539f03b58560753e8ab84c8c360960d99dff714004aa98f203977",
      "Architecture" => "arm64",
      "Os" => "linux",
      "RepoDigests" => [ "rust@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1" ]
    })
    allow(backend).to receive(:create_container) do |config, deadline:|
      probe_calls[:created_config] = config
      probe_calls[:create_deadline] = deadline
      container
    end
    allow(backend).to receive(:start_container).with(container, deadline: kind_of(Numeric))
    if exec_failure
      allow(backend).to receive(:exec_in_container).and_raise(exec_failure)
    else
      allow(backend).to receive(:exec_in_container) do |received_container, command, **|
        probe_calls[:exec_command] = command
        [ exec_stdout, "", 0 ]
      end
    end
    allow(backend).to receive(:delete_container)
    backend
  end

  describe ".call" do
    it "collects engine, image, process, and toolchain facts" do
      stdout = script_output(uname: "aarch64", tools: [
        [ "cargo", "/usr/local/cargo/bin/cargo", elf64_with_interpreter("/lib/ld-linux-aarch64.so.1") ],
        [ "rustc", "/usr/local/rustup/toolchains/bin/rustc", elf64_with_interpreter("/lib/ld-linux-aarch64.so.1") ]
      ])
      backend = backend_with(exec_stdout: stdout)

      facts = described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      expect(facts[:backend_identifier]).to eq("local")
      expect(facts[:engine_architecture]).to eq("aarch64")
      expect(facts[:image]).to include(
        id: "sha256:7cf1e580ef5539f03b58560753e8ab84c8c360960d99dff714004aa98f203977",
        platform: "arm64",
        digest: "sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1"
      )
      expect(facts[:process_architecture]).to eq("aarch64")
      cargo = facts[:toolchains].find { |toolchain| toolchain[:command] == "cargo" }
      expect(cargo[:path]).to eq("/usr/local/cargo/bin/cargo")
      expect(cargo[:interpreter_path]).to eq("/lib/ld-linux-aarch64.so.1")
      expect(cargo[:binary_architecture]).to eq("arm64")
    end

    it "records an absent toolchain without a path or interpreter" do
      stdout = script_output(uname: "aarch64", tools: [
        [ "cargo", "", nil ],
        [ "rustc", "/usr/local/rustup/toolchains/bin/rustc", elf64_with_interpreter("/lib/ld-linux-aarch64.so.1") ]
      ])
      backend = backend_with(exec_stdout: stdout)

      facts = described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      cargo = facts[:toolchains].find { |toolchain| toolchain[:command] == "cargo" }
      expect(cargo[:path]).to be_nil
      expect(cargo[:interpreter_path]).to be_nil
    end

    it "records a non-ELF toolchain header as an unverifiable interpreter" do
      stdout = script_output(uname: "aarch64", tools: [
        [ "cargo", "/usr/local/cargo/bin/cargo", "#!/bin/sh\n".b ]
      ])
      backend = backend_with(exec_stdout: stdout)

      facts = described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      expect(facts[:toolchains].first[:interpreter_path]).to be_nil
    end

    it "hardens the disposable metadata container" do
      backend = backend_with(exec_stdout: script_output(uname: "aarch64", tools: []))

      described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      expect(probe_calls[:created_config]).to include(
        "Image" => "rust:1.95.0-bookworm",
        "NetworkDisabled" => true
      )
      host_config = probe_calls[:created_config].fetch("HostConfig")
      expect(host_config).to include("ReadonlyRootfs" => true, "CapDrop" => [ "ALL" ])
      expect(host_config).to include(
        "Memory" => described_class::CONTAINER_MEMORY_BYTES,
        "NanoCpus" => described_class::CONTAINER_NANO_CPUS,
        "PidsLimit" => described_class::CONTAINER_PID_LIMIT
      )
      expect(host_config).not_to have_key("Resources")
      expect(probe_calls[:create_deadline]).to eq(described_class::PROBE_DEADLINE_SECONDS)
    end

    it "removes the disposable container even when the probe exec fails" do
      backend = backend_with(exec_stdout: "", exec_failure: Docker::Error::DockerError.new("probe failed"))

      facts = described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      expect(backend).to have_received(:delete_container).with(container, deadline: kind_of(Numeric), force: true)
      expect(facts[:process_architecture]).to be_nil
      expect(facts[:probe_error]).to include("probe failed")
    end

    it "removes the disposable container after a successful probe" do
      backend = backend_with(exec_stdout: script_output(uname: "aarch64", tools: []))

      described_class.call(backend: backend, image: "rust:1.95.0-bookworm")

      expect(backend).to have_received(:delete_container).with(container, deadline: kind_of(Numeric), force: true)
      expect(probe_calls[:exec_command]).to include("sh", "-c")
    end
  end
end
