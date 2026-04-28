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
        .includes(:agent_run_logs, :knowledge_usage_stats, :quality_metrics, :issue)
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

      responded = user_responded?(run)

      {
        agent_run_id: run.id,
        issue_title: run.issue&.title,
        questions_asked: questions,
        knowledge_available: knowledge_available,
        sufficient_context: !questions.any?,
        user_responded: responded,
        user_reply_text: responded ? fetch_user_reply_text(run) : nil,
        run_outcome: run_outcome(run)
      }
    end

    def extract_questions(content)
      return [] unless content.include?("## Clarifying questions")

      section = content.split("## Clarifying questions").last.to_s
      section = section.split(/^## /).first.to_s
      section.scan(/^\d+\.\s+(.+)$/).flatten.map(&:strip)
    end

    def user_responded?(run)
      metric = run.quality_metrics.find { |m| m.feedback_source == "enhance_issue_feedback" }
      return false unless metric&.scores

      metric.scores["author_replied"].to_f > 0
    end

    def fetch_user_reply_text(run)
      return nil unless run.issue && run.project.github_token&.client

      client = run.project.github_token.client
      comments = client.issue_comments(run.project.full_name, run.issue.github_number)
      enhancement = comments.find { |c| c[:body].to_s.include?(COMMENT_MARKER) }
      return nil unless enhancement

      author = run.issue.github_creator_login
      enhanced_at = enhancement[:created_at]
      return nil unless author.present? && enhanced_at

      replies = comments.select do |c|
        commented_at = c[:created_at]&.to_time
        next false unless commented_at && commented_at > enhanced_at.to_time

        (c.dig(:user, :login) || c.dig("user", "login")) == author
      end

      replies.map { |c| c[:body].to_s.truncate(500) }.join("\n---\n").presence
    rescue GithubClient::Error, Octokit::Error, Faraday::Error => e
      logger.warn(
        message: "knowledge_evolution.reply_fetch_failed",
        agent_run_id: run.id,
        error: e.message
      )
      nil
    end

    def run_outcome(run)
      if run.pull_request_url.present?
        "pr_created"
      elsif run.result_commit_sha.present?
        "commit_created"
      else
        "enhancement_only"
      end
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
