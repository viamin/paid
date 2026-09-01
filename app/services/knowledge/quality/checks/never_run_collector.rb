# frozen_string_literal: true

require_relative "base"

module Knowledge
  module Quality
    # Surfaces collectors that have never produced a CollectorRun on the
    # project as a knowledge-quality finding. Severity: warning (operators
    # may intentionally opt out of a collector, or have not yet run one).
    class Checks::NeverRunCollector < Checks::Base
      code "never_run_collector"
      severity "warning"

      def findings
        observed = observed_collector_types
        registered = Knowledge::CollectorRunner.registry.keys.map(&:to_s)

        registered.filter_map do |type|
          next if observed.include?(type)

          build_finding(
            target_type: "Collector",
            target_id: type,
            detail: "collector type is registered but has no run on this project"
          )
        end
      end

      private

      def observed_collector_types
        CollectorRun
          .joins(:project_version)
          .where(project_versions: { project_id: project.id })
          .distinct
          .pluck(:collector_type)
          .to_set
      end
    end
  end
end
