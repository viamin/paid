# frozen_string_literal: true

module HealthChecks
  module Notifications
    # Generic ::Notifications::Rule subclass that binds any HealthChecks::Check
    # class into the existing auto-resolving notification pipeline (RDR-049).
    #
    #   rule = HealthChecks::Notifications::RuleAdapter.for(AutoMergeWithoutOwner)
    #   rule.call(scope: account)  # publishes + auto-resolves
    #
    # One finding → one notification per (project, code). Source-keyed dedup
    # means a re-sweep updates rather than stacks.
    class RuleAdapter < ::Notifications::Rule
      class << self
        # Returns an anonymous rule subclass bound to +check_class+.
        def for(check_class)
          Class.new(self) do
            define_singleton_method(:check_class) { check_class }
          end
        end
      end

      private

      def source
        "health_check_#{check_class.code}"
      end

      # Returns projects in the account where the check fires.
      def detect(scope)
        Project.where(account: scope).includes(:account).select { |project| first_finding_for(project) }
      end

      # Returns all projects in the account so auto-resolve can clear
      # notifications for projects that are now healthy.
      def resolve_candidates(scope)
        Project.where(account: scope)
      end

      # Builds notification attrs from the first finding for +subject+ (a Project).
      def build(subject)
        finding = first_finding_for(subject) || raise("no finding for project #{subject.id} with #{check_class}")
        {
          severity: finding.severity,
          title: finding.title,
          description: finding.description,
          action_url: project_health_check_path(subject),
          nav_section: "projects",
          metadata: finding.metadata
        }
      end

      def check_class
        self.class.check_class
      end

      # Returns the first Finding for the given project, dispatching to the
      # correct scope-specific lookup. Returns nil when the project is healthy
      # for this check.
      def first_finding_for(project)
        case check_class.scope
        when :project
          run_check_safely(project)
        when :runner
          find_runner_finding(project)
        when :user
          owner = project.effective_owner
          run_check_safely(owner) if owner
        end
      end

      def find_runner_finding(project)
        owner = project.effective_owner
        return unless owner

        owner.runners.kept_only.for_agent_runs.each do |runner|
          finding = run_check_safely(runner)
          return finding if finding
        end
        nil
      end

      # Runs the check and returns the first finding, or nil on failure.
      def run_check_safely(subject)
        check_class.call(subject).first
      rescue => e
        Rails.logger.error(
          message: "health_checks.notifications.check_error",
          check: check_class.name || check_class.to_s,
          subject_id: subject.try(:id),
          error: e.class.name,
          error_message: e.message
        )
        nil
      end
    end
  end
end
