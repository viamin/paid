# frozen_string_literal: true

module Activities
  # Samples recent completed enhance_issue runs for a project and builds
  # a dataset of questions asked, knowledge available, and user responses
  # for the knowledge evolution analysis.
  class SampleEnhanceRunsActivity < BaseActivity
    activity_name "SampleEnhanceRuns"

    COMMENT_MARKER = "<!-- paid:enhance-issue -->"
    MAX_RUNS = 50

    def execute(input)
      project_id = input[:project_id]
      lookback_days = input.fetch(:lookback_days, 14)

      project = Project.find(project_id)
      runs = fetch_enhance_runs(project, lookback_days)

      sampled_runs = runs.first(MAX_RUNS).filter_map { |run| build_run_data(run) }
      artifact_usage = build_artifact_usage(project, lookback_days)

      {
        project_id: project_id,
        runs: sampled_runs,
        artifact_usage: artifact_usage
      }
    end

    private

    def fetch_enhance_runs(project, lookback_days)
      AgentRun
        .where(project: project, goal: "enhance_issue", status: "completed")
        .where(completed_at: lookback_days.days.ago..)
        .includes(:agent_run_logs, :knowledge_usage_stats, :issue)
        .order(completed_at: :desc)
    end

    def build_run_data(run)
      logs = run.agent_run_logs.select { |l| l.log_type == "stdout" }
      enhancement_log = logs.find { |l| l.content.to_s.include?(COMMENT_MARKER) }
      return nil unless enhancement_log

      questions = extract_questions(enhancement_log.content)
      knowledge_available = run.knowledge_usage_stats.each_with_object({}) do |stat, hash|
        hash[stat.artifact_type] = (hash[stat.artifact_type] || 0) + stat.artifact_count
      end

      {
        agent_run_id: run.id,
        issue_title: run.issue&.title,
        questions_asked: questions,
        knowledge_available: knowledge_available,
        sufficient_context: !questions.any?
      }
    end

    def extract_questions(content)
      return [] unless content.include?("## Clarifying questions")

      section = content.split("## Clarifying questions").last.to_s
      section = section.split(/^## /).first.to_s
      section.scan(/^\d+\.\s+(.+)$/).flatten.map(&:strip)
    end

    def build_artifact_usage(project, lookback_days)
      stats = Knowledge::UsageStats.new(project: project, since: lookback_days.days.ago)
      effectiveness = stats.effectiveness_by_artifact_type

      effectiveness.transform_values do |data|
        {
          total_runs: data[:total_runs],
          success_rate: data[:success_rate]
        }
      end
    end
  end
end
