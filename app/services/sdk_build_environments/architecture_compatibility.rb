# frozen_string_literal: true

module SdkBuildEnvironments
  # Pure classification of runner/architecture/loader compatibility for
  # isolated Rust/SDK build environments. An ELF binary names its dynamic
  # loader in its program header, so a loader error identifies the
  # *binary's* architecture, not the runner's. The #5358 failure reported
  # an x86-64 loader path; a separately observed runner profile is required
  # before that loader can establish an architecture mismatch.
  #
  # @spec RUST-SDK-BUILD-001
  # @spec RUST-SDK-BUILD-002
  # @spec RUST-SDK-BUILD-003
  # @spec RUST-SDK-BUILD-004
  class ArchitectureCompatibility
    ARCHITECTURE_ALIASES = {
      "x86_64" => "amd64",
      "x64" => "amd64",
      "amd64" => "amd64",
      "aarch64" => "arm64",
      "arm64" => "arm64",
      "armv7l" => "arm",
      "armhf" => "arm",
      "arm" => "arm",
      "i386" => "386",
      "i686" => "386",
      "386" => "386"
    }.freeze

    # Ordered: the first pattern whose subject matches a path wins, so the
    # generic 32-bit x86 loader never claims a path that already names
    # x86-64, aarch64, or armhf explicitly.
    INTERPRETER_PATTERNS = [
      [ /x86-64|x86_64/, "amd64" ],
      [ /aarch64/, "arm64" ],
      [ /armhf|arm-linux-gnueabihf/, "arm" ],
      [ /i386-linux-gnu|ld-linux\.so\.2\z/, "386" ]
    ].freeze

    LOADER_FAILURE_PATTERN = /Dynamic loader not found: (\S+)/.freeze

    class << self
      # @param value [String, nil] any architecture spelling
      # @return [String, nil] the OCI architecture name, or nil when unknown
      def normalize(value)
        ARCHITECTURE_ALIASES.fetch(value.to_s.strip.downcase, nil)
      end

      # @param path [String, nil] an ELF PT_INTERP path
      # @return [String, nil] the architecture that path implies, or nil
      def interpreter_architecture(path)
        subject = path.to_s
        return nil if subject.empty?

        INTERPRETER_PATTERNS.each do |pattern, architecture|
          return architecture if subject.match?(pattern)
        end
        nil
      end

      # Classifies a toolchain observation against the runner's process
      # architecture. An explicit +binary_architecture+ wins over the
      # architecture implied by +interpreter_path+.
      #
      # @return [Hash] +status+ (:compatible, :architecture_mismatch, or
      #   :unknown), normalized +process_architecture+ and
      #   +binary_architecture+, and a human-readable +detail+.
      def classify_toolchain(process_architecture:, binary_architecture: nil, interpreter_path: nil)
        process = normalize(process_architecture)
        binary = binary_architecture.present? ? normalize(binary_architecture) : interpreter_architecture(interpreter_path)
        return unknown_classification(process) if process.nil? || binary.nil?

        if binary == process
          { status: :compatible, process_architecture: process, binary_architecture: binary,
            detail: "toolchain binary architecture #{binary} matches runner architecture #{process}" }
        else
          { status: :architecture_mismatch, process_architecture: process, binary_architecture: binary,
            detail: "toolchain binary is #{binary} but the runner process architecture is #{process}" }
        end
      end

      # Recognizes the dynamic-loader failure signature in container
      # output and attributes it to the loader path's implied architecture
      # rather than to the runner.
      #
      # @return [Hash, nil] classification with +kind+, +loader_path+,
      #   +loader_architecture+, +process_architecture+, and +detail+; nil
      #   when the output carries no loader failure.
      def classify_loader_failure(output, process_architecture: nil)
        match = output.to_s.match(LOADER_FAILURE_PATTERN)
        return nil unless match

        loader_path = match[1]
        loader_architecture = interpreter_architecture(loader_path)
        process = normalize(process_architecture)
        { kind: loader_failure_kind(loader_architecture, process),
          loader_path: loader_path,
          loader_architecture: loader_architecture,
          process_architecture: process,
          detail: "dynamic loader #{loader_path} implies #{loader_architecture || 'an unknown architecture'}" \
                  " while the runner process architecture is #{process || 'unknown'}" }
      end

      private

      def unknown_classification(process)
        { status: :unknown, process_architecture: process, binary_architecture: nil,
          detail: "toolchain binary architecture could not be resolved" }
      end

      def loader_failure_kind(loader_architecture, process)
        return "foreign_architecture_binary" if loader_architecture && process && loader_architecture != process
        return "unknown_process_architecture" if loader_architecture && process.nil?
        return "missing_compatible_loader" if loader_architecture

        "unknown_loader_architecture"
      end
    end
  end
end
