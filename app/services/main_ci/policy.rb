# frozen_string_literal: true

module MainCi
  # Explicit owner policy; source-controlled candidate content cannot enable it.
  # @spec MAIN-CI-003 MAIN-CI-007
  class Policy
    attr_reader :settings

    def initialize(project)
      @settings = project.respond_to?(:review_settings) && project.review_settings.is_a?(Hash) ? project.review_settings.fetch("main_ci_recovery", {}) : {}
    end

    def enabled? = settings.is_a?(Hash) && settings["enabled"] == true
    def workflows = settings.is_a?(Hash) ? Array(settings["required_workflows"]) : []
    def executor_revision = settings.is_a?(Hash) ? settings["executor_revision"] : nil

    def valid?
      return false unless settings.is_a?(Hash)
      return true unless enabled?

      workflows.any? && workflows.size <= 20 && workflows.uniq == workflows &&
        workflows.all? { |path| path.is_a?(String) && path.match?(%r{\A\.github/workflows/[a-zA-Z0-9_-]+\.ya?ml\z}) } &&
        executor_revision.is_a?(String) && executor_revision.match?(/\A[0-9a-f]{40}\z/)
    end

    def executor_available?
      valid? && executor_revision.present? && executor_revision == ENV["PAID_EXECUTOR_REVISION"]
    end
  end
end
