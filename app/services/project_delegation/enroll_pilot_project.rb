# frozen_string_literal: true

module ProjectDelegation
  # Opts a project into the RDR-080 `bounded_delivery` pilot. Enrollment is
  # explicit, capped at five concurrently active projects, gated behind both
  # rollout guards, and captures the project's own conservative baseline in
  # the same transaction so every later comparison has a pre-pilot control
  # window.
  #
  # @spec PROJECT-DELEGATION-007
  class EnrollPilotProject
    MAX_PILOT_PROJECTS = 5
    BASELINE_WINDOW_DAYS = 30

    Result = Data.define(:success, :enrollment, :error) do
      def success? = success
    end

    def self.call(project:, actor:)
      new(project:, actor:).call
    end

    def initialize(project:, actor:)
      @project = project
      @actor = actor
    end

    def call
      return failure("broadening is disabled while the automation_phases guard is off") unless Automation::RolloutGuard.enabled?(project)
      return failure("broadening is disabled while the project_delegation guard is off") unless FeatureFlags.enabled?(:project_delegation, project:)
      return failure("project is already enrolled in the delegation pilot") if project.delegation_pilot_enrollments.exists?
      return failure("the delegation pilot is limited to #{MAX_PILOT_PROJECTS} active projects") if capacity_reached?

      enrollment = enroll
      Result.new(success: true, enrollment: enrollment, error: nil)
    end

    private

    attr_reader :project, :actor

    def capacity_reached?
      DelegationPilotEnrollment.active.count >= MAX_PILOT_PROJECTS
    end

    def enroll
      DelegationPilotEnrollment.transaction do
        enrollment = DelegationPilotEnrollment.create!(
          account: project.account,
          project: project,
          posture: "bounded_delivery",
          status: "active",
          enrolled_by: actor,
          enrolled_at: Time.current
        )
        RecordPilotMetrics.call(
          enrollment:,
          posture: "conservative_baseline",
          window_started_at: BASELINE_WINDOW_DAYS.days.before(enrollment.enrolled_at),
          window_ended_at: enrollment.enrolled_at
        )
        Audit::RecordEvent.call(
          action: "delegation_pilot.enrolled",
          actor: actor,
          subject: enrollment,
          metadata: { "posture" => enrollment.posture, "baseline_window_days" => BASELINE_WINDOW_DAYS }
        )
        enrollment
      end
    end

    def failure(message)
      Result.new(success: false, enrollment: nil, error: message)
    end
  end
end
