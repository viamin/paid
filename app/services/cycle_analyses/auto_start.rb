# frozen_string_literal: true

module CycleAnalyses
  # Detection-side companion to CycleAnalyses::Start: when every project
  # represented by a newly detected cycle occurrence delegates the bounded
  # repair action under the effective project policy, schedule exactly one
  # automatic analysis run attributed to one actor holding run and
  # issue-mutation authority for every represented project.
  #
  # Consent is never inferred across projects: one project's delegation does
  # not authorize a cross-project cycle, and the rollout guard's legacy
  # policy path permits nothing here. Retry and cost bounds live in
  # CycleAnalyses::Start, so a cycle that cannot be repaired without a human
  # decision is never re-analyzed while its occurrence is unchanged.
  # @spec AUTO-PICK-QUEUE-025
  class AutoStart
    def self.call(...) = new(...).call

    def initialize(cycles:)
      @cycles = Array(cycles)
    end

    def call
      cycles.filter_map { |cycle| start(cycle) }
    end

    private

    attr_reader :cycles

    def start(cycle)
      projects = ordered_projects(cycle)
      return skipped(cycle, :policy_not_delegated) unless projects.all? { |project| delegates_repair?(project) }

      actor = actor_for(cycle, projects)
      return skipped(cycle, :no_authorized_actor) unless actor

      result = Start.call(cycle:, actor:, trigger: :automatic)
      log(cycle, :info, outcome: result.status, agent_run_id: result.agent_run&.id, actor_id: actor.id)
      result
    end

    # The effective policy decision for the delegated repair action on its
    # delivery phase. A permitted legacy decision is not delegation: the
    # automatic start exists only where the current policy actually delegates.
    def delegates_repair?(project)
      decision = Automation::EffectivePolicy.call(project:,
        phase: Automation::DelegatedActionAdmission::ACTION_PHASES.fetch("repair"),
        delegated_action: "repair", trigger: :automatic)
      decision.permitted? && decision.source != :legacy_policy
    end

    # One identified actor for the whole cycle. Candidates are the users who
    # expressed each project's delegation and the project owners, in
    # deterministic order; the first holding run and issue-mutation authority
    # for every represented project starts the run.
    def actor_for(cycle, projects)
      primary = cycle.project
      ordered = [ primary, *projects.reject { |project| project.id == primary.id } ]
      ordered.flat_map { |project| [ project.delegation_posture&.selected_by, project.created_by ] }
        .compact.uniq.find { |user| authorized?(user, projects) }
    end

    def authorized?(user, projects)
      projects.all? do |project|
        policy = ProjectPolicy.new(user, project)
        policy.run_agent? && policy.manage_issues?
      end
    end

    def ordered_projects(cycle)
      cycle.issues.map(&:project).uniq(&:id)
    end

    def skipped(cycle, outcome)
      log(cycle, :debug, outcome: outcome)
      nil
    end

    def log(cycle, level, **fields)
      Rails.logger.public_send(level,
        message: "cycle_analyses.auto_start",
        component: "cycle_analyses",
        occurrence: cycle.occurrence,
        fingerprint: cycle.fingerprint,
        project_ids: cycle.project_ids,
        **fields)
    end
  end
end
