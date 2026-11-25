# frozen_string_literal: true

require "securerandom"

module SdkBuildEnvironments
  # Runs the one version-bound Core compilation that establishes whether the
  # frozen #5358 recipe is usable. This is intentionally not a general build
  # runner: all source identities, commands, and resource bounds are fixed in
  # this class. The control plane owns Docker access; callers receive only a
  # bounded receipt and never a daemon capability.
  #
  # @spec RUST-SDK-BUILD-013
  class PinnedCoreBuild
    BUILD_DEADLINE_SECONDS = 900
    CONTAINER_MEMORY_BYTES = 4.gigabytes
    CONTAINER_NANO_CPUS = 2_000_000_000
    CONTAINER_PID_LIMIT = 256
    OUTPUT_LIMIT_BYTES = 100 * 1024

    class IncompatibleEnvironmentError < StandardError; end

    class << self
      def call(backend:, image: Pins.default_image_reference, probe: MetadataProbe)
        new(backend:, image:, probe:).call
      end
    end

    def initialize(backend:, image:, probe:)
      @backend = backend
      @image = image
      @probe = probe
      @image_tag = "paid-sdk-core-build-#{SecureRandom.hex(12)}"
    end

    def call
      preflight = Preflight.call(facts: @probe.call(backend: @backend, image: @image))
      raise IncompatibleEnvironmentError, preflight.fetch(:remediation_hint) unless preflight[:verdict] == :compatible

      build_image
      run_offline_check(preflight)
    ensure
      cleanup
    end

    private

    def build_image
      @backend.build_image(dockerfile, t: @image_tag, rm: true)
      @built_image = true
    end

    def run_offline_check(preflight)
      @container = @backend.create_container(container_config, deadline: BUILD_DEADLINE_SECONDS)
      @backend.start_container(@container, deadline: BUILD_DEADLINE_SECONDS)
      stdout, stderr, status = @backend.exec_in_container(@container, check_command,
        deadline: BUILD_DEADLINE_SECONDS, user: "root", wait: BUILD_DEADLINE_SECONDS)
      {
        backend: @backend.identifier,
        preflight: preflight,
        command: check_command,
        exit_status: status.to_i,
        stdout: bounded_output(stdout),
        stderr: bounded_output(stderr),
        isolation: { network_disabled: true, cap_drop: [ "ALL" ], readonly_rootfs: false },
        cleanup: { container_removed: false, image_removed: false }
      }.tap { |receipt| @receipt = receipt }
    end

    def container_config
      {
        "Image" => @image_tag,
        "Cmd" => [ "sh", "-c", "sleep #{BUILD_DEADLINE_SECONDS}" ],
        "NetworkDisabled" => true,
        "Labels" => { "dev.paid.sdk-core-build" => "true" },
        "HostConfig" => {
          "CapDrop" => [ "ALL" ],
          "Memory" => CONTAINER_MEMORY_BYTES,
          "NanoCpus" => CONTAINER_NANO_CPUS,
          "PidsLimit" => CONTAINER_PID_LIMIT
        }
      }
    end

    def check_command
      [ "sh", "-lc", "cd /sdk/ext/sdk-core && cargo check --locked --offline --package temporalio-sdk-core" ]
    end

    def dockerfile
      recipe = Pins.for_architecture("arm64")
      <<~DOCKERFILE
        FROM #{@image}
        RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git libclang-18-dev pkg-config unzip && rm -rf /var/lib/apt/lists/*
        RUN curl --fail --location --silent --show-error --output /tmp/protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v#{recipe.dig(:protoc, :version)}/#{recipe.dig(:protoc, :asset)} \
          && echo "#{recipe.dig(:protoc, :sha256)}  /tmp/protoc.zip" | sha256sum --check \
          && unzip -q /tmp/protoc.zip -d /usr/local \
          && rm /tmp/protoc.zip
        RUN git clone --no-checkout https://github.com/#{recipe.dig(:source, :ruby_sdk, :repository)}.git /sdk \
          && git -C /sdk checkout --detach #{recipe.dig(:source, :ruby_sdk, :commit)} \
          && git -C /sdk submodule update --init ext/sdk-core \
          && git -C /sdk/ext/sdk-core checkout --detach #{recipe.dig(:source, :core, :commit)} \
          && test "$(sha256sum /sdk/ext/sdk-core/Cargo.lock | awk '{print $1}')" = "#{recipe.dig(:source, :cargo_lock_sha256)}" \
          && cd /sdk/ext/sdk-core && cargo fetch --locked
      DOCKERFILE
    end

    def bounded_output(value)
      text = Array(value).join.to_s.scrub
      return text if text.bytesize <= OUTPUT_LIMIT_BYTES

      "#{text.byteslice(0, OUTPUT_LIMIT_BYTES).scrub}\n[output truncated]"
    end

    def cleanup
      remove_container
    ensure
      remove_image
      record_cleanup
    end

    def record_cleanup
      return unless @receipt

      @receipt[:cleanup] = { container_removed: @container.nil?, image_removed: !@built_image }
    end

    def remove_container
      return unless @container

      @backend.delete_container(@container, deadline: BUILD_DEADLINE_SECONDS, force: true)
      @container = nil
    end

    def remove_image
      return unless @built_image

      @backend.delete_image(@image_tag, force: true)
      @built_image = false
    end
  end
end
