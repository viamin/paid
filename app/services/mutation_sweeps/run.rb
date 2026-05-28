# frozen_string_literal: true

module MutationSweeps
  class Run
    include Containers::QualityHooks

    SWEEP_TIMEOUT = 90.minutes

    def self.call(...)
      new(...).call
    end

    def initialize(project:, sweep_date: Date.current)
      @project = project
      @sweep_date = sweep_date.to_date
    end

    def call
      return unless command

      agent_run = create_agent_run!
      metric_recorded = false

      worktree_service.with_temporary_worktree(project.default_branch) do |worktree_path|
        agent_run.update_columns(worktree_path: worktree_path)

        Containers::Provision.with_container(agent_run:, worktree_path:) do |container|
          container.execute(command, timeout: SWEEP_TIMEOUT, stream: true)
        end

        metric = record_metric!(agent_run:, worktree_path:)
        metric_recorded = true
        finalize_agent_run!(agent_run, status: "completed")
        metric
      end
    rescue StandardError => e
      record_failed_metric!(agent_run:, error: e) if agent_run && !metric_recorded
      finalize_agent_run!(agent_run, status: "failed", error_message: e.message) if agent_run
      raise
    end

    private

    attr_reader :project, :sweep_date

    def command
      @command ||= resolve_scheduled_mutation_command(project, project.effective_owner, detect_language(project))
    end

    def worktree_service
      @worktree_service ||= WorktreeService.new(project)
    end

    def create_agent_run!
      AgentRun.create!(
        project: project,
        agent_type: "api",
        status: "running",
        goal: "create_pr",
        focus: "general",
        trigger_type: "automatic",
        custom_prompt: "Scheduled mutation sweep against #{project.default_branch}",
        started_at: Time.current
      )
    end

    def record_metric!(agent_run:, worktree_path:)
      results = MutantResultsReader.read(worktree_path)
      raise "Scheduled mutation sweep produced no mutant results" unless results

      total_mutations = results.fetch(:total_mutations)
      raise "Scheduled mutation sweep reported zero total mutations" if total_mutations.zero?

      killed_mutations = results.fetch(:killed_mutations)
      kill_rate = (killed_mutations.to_f / total_mutations).round(4)

      metric = QualityMetric.create!(
        agent_run: agent_run,
        metric_type: "automated",
        feedback_source: "system",
        source: QualityMetric::SCHEDULED_MUTATION_SWEEP_SOURCE,
        mutation_kill_rate: kill_rate,
        scores: { "mutation_kill_rate" => kill_rate },
        metadata: {
          "command" => command,
          "sweep_date" => sweep_date.iso8601,
          "total_mutations" => total_mutations,
          "killed_mutations" => killed_mutations,
          "source_path" => results[:source_path]
        }
      )

      QualityMetrics::EvaluateGate.call(quality_metric: metric)
      QualityAlerts::CheckGate.call(project: project) if project.quality_gates_enabled?
      metric
    end

    def record_failed_metric!(agent_run:, error:)
      QualityMetric.find_or_create_by!(agent_run:, metric_type: "automated") do |metric|
        metric.feedback_source = "system"
        metric.source = QualityMetric::SCHEDULED_MUTATION_SWEEP_SOURCE
        metric.metadata = {
          "command" => command,
          "sweep_date" => sweep_date.iso8601,
          "failed" => true,
          "error_class" => error.class.name,
          "error_message" => error.message
        }
      end
    end

    def finalize_agent_run!(agent_run, status:, error_message: nil)
      completed_at = Time.current
      duration_seconds = if agent_run.started_at
        (completed_at - agent_run.started_at).round
      end

      agent_run.update_columns(
        status: status,
        completed_at: completed_at,
        duration_seconds: duration_seconds,
        error_message: error_message
      )
    end
  end
end
