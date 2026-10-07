# frozen_string_literal: true

module Features
  # Decides whether the paid Rails feature-flag rollout-guard pattern
  # (`FeatureFlags::DEFINITIONS` + `FeatureFlags.enabled?`) is meaningful for a
  # project's codebase.
  #
  # The pattern assumes a Ruby codebase: `FeatureFlags` is a Ruby class
  # constant consulted through a Ruby class method. Requiring those artifacts
  # from a non-Ruby repository (GDScript, Python, Rust, ...) would force
  # porting paid's flag system into a foreign codebase (#4172), so the RDR
  # output contract and the agent prompts demand it only where Ruby is among
  # the project's detected languages. Projects with no detected language are
  # treated as non-Ruby — the safe default that cannot block a run on
  # artifacts the repository cannot produce.
  # @spec RDR-ROLLOUT-GUARD-003
  # @spec RDR-ROLLOUT-GUARD-004
  module FlagGuardPattern
    RUBY = "ruby"

    class << self
      def applicable?(project)
        return false unless project.respond_to?(:detected_languages)

        languages = Array(project.detected_languages).map { |language| language.to_s.strip.downcase }
        languages.include?(RUBY)
      end
    end
  end
end
