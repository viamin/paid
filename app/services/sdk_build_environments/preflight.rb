# frozen_string_literal: true

module SdkBuildEnvironments
  # Turns collected environment facts into the sanitized preflight receipt:
  # environment identity, toolchain loader mappings, and a check-based
  # verdict. An unsupported pairing fails loudly here — with a named
  # verdict and remediation hint — instead of surfacing as a loader error
  # inside a build log after provisioning.
  #
  # @spec RUST-SDK-BUILD-008
  # @spec RUST-SDK-BUILD-009
  # @spec RUST-SDK-BUILD-010
  class Preflight
    Check = Struct.new(:name, :healthy, :details, :verdict, :remediation_hint, keyword_init: true) do
      def healthy?
        healthy == true
      end

      def to_h
        { name: name, healthy: healthy?, details: details }
      end
    end

    class << self
      def call(facts:)
        new(facts:).call
      end
    end

    attr_reader :facts

    def initialize(facts:)
      @facts = facts
    end

    def call
      checks = [ engine_check, image_check, *toolchain_checks ]
      failing = checks.find { |check| !check.healthy? }
      receipt(checks, failing)
    end

    private

    def receipt(checks, failing)
      {
        backend: facts[:backend_identifier],
        engine_architecture: normalized_engine_architecture,
        image: facts[:image].to_h,
        process_architecture: ArchitectureCompatibility.normalize(facts[:process_architecture]),
        toolchains: toolchain_receipts,
        checks: checks.map(&:to_h),
        verdict: failing ? failing.verdict : :compatible,
        remediation_hint: failing&.remediation_hint,
        probe_error: facts[:probe_error],
        generated_at: Time.current
      }
    end

    def engine_check
      healthy = normalized_engine_architecture.present?
      Check.new(
        name: "engine_architecture",
        healthy: healthy,
        details: { engine_architecture: facts[:engine_architecture] },
        verdict: :unverifiable,
        remediation_hint: healthy ? nil : "Record the backend engine architecture before classifying the environment."
      )
    end

    def image_check
      platform = facts[:image].to_h[:platform].presence
      image_architecture = ArchitectureCompatibility.normalize(platform)
      engine = normalized_engine_architecture
      verdict, hint = image_verdict(platform, image_architecture, engine)
      Check.new(
        name: "image_architecture",
        healthy: verdict.nil?,
        details: { platform: platform, image_architecture: image_architecture, engine_architecture: engine },
        verdict: verdict,
        remediation_hint: hint
      )
    end

    def image_verdict(platform, image_architecture, engine)
      return [ :unverifiable_image_architecture,
        "The image reports no platform; select a digest-pinned image with a recorded architecture." ] if platform.blank?
      return [ :unverifiable_image_architecture,
        "The image platform #{platform.inspect} has no known architecture mapping." ] if image_architecture.nil?
      return [ :unverifiable,
        "The engine architecture is unknown, so the image architecture cannot be compared." ] if engine.nil?
      return [ :image_architecture_mismatch,
        "Select the #{engine} toolchain image; #{facts[:image].to_h[:reference]} is #{image_architecture}." ] if image_architecture != engine

      nil
    end

    def toolchain_checks
      toolchains.flat_map do |toolchain|
        command = toolchain[:command]
        [ presence_check(command, toolchain), loader_check(command, toolchain) ]
      end
    end

    def presence_check(command, toolchain)
      present = toolchain[:path].present?
      Check.new(
        name: "toolchain_presence:#{command}",
        healthy: present,
        details: { command: command, path: toolchain[:path] },
        verdict: :toolchain_absent,
        remediation_hint: present ? nil :
          "#{command} is absent from the environment's default PATH; use a digest-pinned toolchain image that provides it."
      )
    end

    def loader_check(command, toolchain)
      classification = ArchitectureCompatibility.classify_toolchain(
        process_architecture: facts[:process_architecture],
        binary_architecture: toolchain[:binary_architecture],
        interpreter_path: toolchain[:interpreter_path]
      )
      verdict = { compatible: nil, architecture_mismatch: :loader_architecture_mismatch,
                  unknown: :unverifiable }.fetch(classification[:status])
      Check.new(
        name: "toolchain_loader:#{command}",
        healthy: verdict.nil?,
        details: { command: command, interpreter_path: toolchain[:interpreter_path] }.merge(classification),
        verdict: verdict,
        remediation_hint: loader_hint(command, verdict, classification)
      )
    end

    def loader_hint(command, verdict, classification)
      case verdict
      when :loader_architecture_mismatch
        "#{classification[:detail]}; select the #{classification[:process_architecture]} toolchain artifact."
      when :unverifiable
        "The #{command} loader mapping could not be read from its ELF header; re-run preflight against the digest-pinned toolchain image."
      end
    end

    def toolchain_receipts
      toolchains.map do |toolchain|
        toolchain.merge(architecture: toolchain[:binary_architecture]).slice(:command, :path, :interpreter_path, :architecture)
      end
    end

    def toolchains
      Array(facts[:toolchains])
    end

    def normalized_engine_architecture
      ArchitectureCompatibility.normalize(facts[:engine_architecture])
    end
  end
end
