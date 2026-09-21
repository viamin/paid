# frozen_string_literal: true

module AppleVerification
  # Derives a best-effort starting `.paid/apple-verification.yml` shape from a
  # repository file listing. The result is a plain Hash for a user to review
  # and commit; it is never parsed as approved configuration on its own.
  # @spec APPLE-WORKER-012
  class InferConfiguration
    SCHEME_PATTERN = %r{\A(.+?\.(?:xcodeproj|xcworkspace))/xcshareddata/xcschemes/(.+)\.xcscheme\z}
    TEST_PLAN_PATTERN = /\.xctestplan\z/
    PACKAGE_MANIFEST = "Package.swift"
    UNSUPPORTED_BOOTSTRAP_MARKERS = {
      "Podfile" => "cocoapods",
      "Cartfile" => "carthage",
      "WORKSPACE" => "bazel",
      "Project.swift" => "tuist"
    }.freeze

    class << self
      def call(paths:)
        new(paths:).call
      end
    end

    def initialize(paths:)
      @paths = Array(paths)
    end

    def call
      raise ConfigurationParser::ConfigurationError, unsupported_bootstrap_message if unsupported_bootstrap? && xcode_targets.empty?

      profiles = xcode_targets.each_with_object({}) do |target, memo|
        name = profile_name(target)
        name = "#{name}-#{File.dirname(target[:target_path]).parameterize}" while memo.key?(name)
        memo[name] = profile_attributes(target)
      end
      { "version" => ConfigurationParser::SUPPORTED_VERSION, "profiles" => profiles }
    end

    private

    attr_reader :paths

    def xcode_targets
      @xcode_targets ||= scheme_matches.map do |target_path, scheme_name|
        { target_path:, scheme_name: }
      end
    end

    def scheme_matches
      paths.filter_map { |path| path[SCHEME_PATTERN] && [ Regexp.last_match(1), Regexp.last_match(2) ] }.uniq
    end

    def profile_name(target)
      target[:scheme_name].parameterize
    end

    def profile_attributes(target)
      attributes = {
        "platform" => "ios",
        "worker" => {},
        "xcode" => xcode_section(target),
        "tests" => { "required" => has_tests?(target) },
        "captures" => [ default_capture ]
      }
      attributes["bootstrap"] = "spm" if paths.include?(PACKAGE_MANIFEST)
      attributes
    end

    def xcode_section(target)
      key = target[:target_path].end_with?(".xcworkspace") ? "workspace" : "project"
      section = { key => target[:target_path], "scheme" => target[:scheme_name] }
      test_plan = test_plan_for(target)
      section["test_plan"] = test_plan if test_plan

      section
    end

    def test_plan_for(target)
      target_dir = File.dirname(target[:target_path])
      paths.find { |path| path.match?(TEST_PLAN_PATTERN) && File.dirname(path) == target_dir }
    end

    def has_tests?(target)
      prefix = File.dirname(target[:target_path])
      scope = prefix == "." ? "" : "#{prefix}/"
      paths.any? { |path| path.start_with?(scope) && path.match?(/Tests?\//i) }
    end

    def default_capture
      {
        "id" => "initial-screen",
        "required" => true,
        "flow" => [ { "launch_app" => {} }, { "capture" => { "name" => "initial-screen" } } ]
      }
    end

    def unsupported_bootstrap?
      UNSUPPORTED_BOOTSTRAP_MARKERS.keys.any? { |marker| paths.include?(marker) }
    end

    def unsupported_bootstrap_message
      systems = UNSUPPORTED_BOOTSTRAP_MARKERS.select { |marker, _system| paths.include?(marker) }.values.uniq
      "repository requires unsupported bootstrap system(s): #{systems.join(', ')}; commit a generated .xcodeproj or .xcworkspace instead"
    end
  end
end
