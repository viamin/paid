# frozen_string_literal: true

module Projects
  # View helpers for the health-check UI. Declared as a helper module (rather
  # than controller `helper_method`s) so the methods resolve in BOTH rendering
  # contexts: the normal request cycle through HealthCheckController and the
  # out-of-request broadcast from ProjectHealthCheckJob, which renders the
  # partial via ApplicationController.render and therefore does not see
  # controller-specific helper_methods.
  module HealthCheckHelper
    SEVERITY_CIRCLE = {
      error: "bg-red-100",
      warning: "bg-amber-100",
      info: "bg-blue-100"
    }.freeze
    SEVERITY_ICON = {
      error: "text-red-600",
      warning: "text-amber-600",
      info: "text-blue-600"
    }.freeze
    SUMMARY_BADGE = {
      healthy: "bg-green-50 text-green-700 ring-green-200",
      warning: "bg-amber-50 text-amber-800 ring-amber-200",
      error: "bg-red-50 text-red-700 ring-red-200"
    }.freeze
    SCOPE_LABELS = {
      project: "Project",
      runner: "Runners",
      user: "User"
    }.freeze

    def severity_circle_class(severity)
      SEVERITY_CIRCLE.fetch(severity.to_sym, "bg-gray-100")
    end

    def severity_icon_class(severity)
      SEVERITY_ICON.fetch(severity.to_sym, "text-gray-600")
    end

    def summary_badge_class(result)
      return SUMMARY_BADGE[:healthy] if result.nil?
      # healthy? is true for warning-only runs (it only excludes errors), so
      # check warnings before the healthy fallthrough to avoid a green badge
      # that contradicts the amber findings below it.
      return SUMMARY_BADGE[:error] unless result.healthy?
      return SUMMARY_BADGE[:warning] if result.warnings?

      SUMMARY_BADGE[:healthy]
    end

    def scope_label(scope)
      SCOPE_LABELS.fetch(scope.to_sym, scope.to_s.humanize)
    end
  end
end
