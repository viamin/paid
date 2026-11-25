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
    CLEANUP_DEADLINE_SECONDS = 30

    class IncompatibleEnvironmentError < StandardError; end
    class DeadlineExceeded < StandardError; end

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
      @deadline_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUILD_DEADLINE_SECONDS
      preflight = Preflight.call(facts: @probe.call(backend: @backend, image: @image))
      raise IncompatibleEnvironmentError, preflight.fetch(:remediation_hint) unless preflight[:verdict] == :compatible

      ensure_build_deadline!
      build_image
      run_offline_check(preflight)
    ensure
      cleanup
    end

    private

    def build_image
      @built_image = true
      @backend.build_image(dockerfile, build_options, deadline: remaining_deadline)
    end

    def run_offline_check(preflight)
      @container = @backend.create_container(container_config, deadline: remaining_deadline)
      ensure_build_deadline!
      @backend.start_container(@container, deadline: remaining_deadline)
      ensure_build_deadline!
      stdout, stderr, status = @backend.exec_in_container(@container, check_command,
        deadline: remaining_deadline, user: "root", wait: remaining_deadline)
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
      [ "sh", "-lc", "cd /sdk/temporalio && cargo check --locked --offline --package temporalio-sdk-core" ]
    end

    def dockerfile
      recipe = Pins.for_architecture("arm64")
      libclang = recipe.fetch(:libclang)
      source = recipe.fetch(:source)
      <<~DOCKERFILE
        FROM #{@image}
        RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git pkg-config unzip \
          #{libclang.fetch(:packages).map { |package| "#{package}=#{libclang.fetch(:package_version)}" }.join(" ")} \
          && test "$(sha256sum #{libclang.fetch(:library_path)} | awk '{print $1}')" = "#{libclang.fetch(:library_sha256)}" \
          && rm -rf /var/lib/apt/lists/*
        RUN curl --fail --location --silent --show-error --output /tmp/protoc.zip https://github.com/protocolbuffers/protobuf/releases/download/v#{recipe.dig(:protoc, :version)}/#{recipe.dig(:protoc, :asset)} \
          && echo "#{recipe.dig(:protoc, :sha256)}  /tmp/protoc.zip" | sha256sum --check \
          && unzip -q /tmp/protoc.zip -d /usr/local \
          && rm /tmp/protoc.zip
        RUN git clone --no-checkout https://github.com/#{source.dig(:ruby_sdk, :repository)}.git /sdk \
          && git -C /sdk checkout --detach #{source.dig(:ruby_sdk, :commit)} \
          && git -C /sdk submodule update --init #{source.dig(:core, :path)} \
          && git -C /sdk/#{source.dig(:core, :path)} checkout --detach #{source.dig(:core, :commit)} \
          && test "$(sha256sum /sdk/temporalio/Cargo.lock | awk '{print $1}')" = "#{source.dig(:cargo_lock_sha256)}" \
          && cd /sdk/temporalio && cargo fetch --locked
      DOCKERFILE
    end

    def build_options
      {
        t: @image_tag,
        rm: true,
        forcerm: true,
        memory: CONTAINER_MEMORY_BYTES,
        memswap: CONTAINER_MEMORY_BYTES,
        cpuperiod: 100_000,
        cpuquota: CONTAINER_NANO_CPUS / 10_000,
        ulimits: [ { Name: "nproc", Soft: CONTAINER_PID_LIMIT, Hard: CONTAINER_PID_LIMIT } ]
      }
    end

    def ensure_build_deadline!
      raise DeadlineExceeded, "pinned Rust SDK Core build deadline exceeded" unless remaining_time.positive?
    end

    def remaining_deadline
      remaining = remaining_time
      raise DeadlineExceeded, "pinned Rust SDK Core build deadline exceeded" unless remaining.positive?

      remaining.ceil
    end

    def remaining_time
      @deadline_at - Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

      @backend.delete_container(@container, deadline: CLEANUP_DEADLINE_SECONDS, force: true)
      @container = nil
    end

    def remove_image
      return unless @built_image

      @backend.delete_image(@image_tag, deadline: CLEANUP_DEADLINE_SECONDS, force: true)
      @built_image = false
    end
  end
end
