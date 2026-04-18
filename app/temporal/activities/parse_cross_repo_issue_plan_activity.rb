# frozen_string_literal: true

module Activities
  # Parses the agent's output to detect a cross-repo issue plan.
  #
  # When a create-issue agent determines that work should be split across
  # repositories, it emits structured markers in its output:
  #
  #   <!-- upstream: owner/repo -->
  #   <!-- upstream-title: Title for upstream issue -->
  #
  # The upstream body is extracted from a fenced section:
  #
  #   <!-- upstream-body-start -->
  #   ...markdown content for the upstream issue...
  #   <!-- upstream-body-end -->
  #
  # The downstream issue (in the current project's repo) uses the remaining
  # agent output as its body, with a dependency declaration auto-injected.
  class ParseCrossRepoIssuePlanActivity < BaseActivity
    activity_name "ParseCrossRepoIssuePlan"

    UPSTREAM_REPO_PATTERN = /<!--\s*upstream:\s*(\S+\/\S+)\s*-->/.freeze
    UPSTREAM_TITLE_PATTERN = /<!--\s*upstream-title:\s*(.+?)\s*-->/.freeze
    UPSTREAM_BODY_PATTERN = /<!--\s*upstream-body-start\s*-->\n?(.*?)\n?<!--\s*upstream-body-end\s*-->/m.freeze

    def execute(input)
      agent_run_id = input[:agent_run_id]
      agent_run = AgentRun.find(agent_run_id)

      summary = agent_run.agent_summary_with_stderr_fallback
      plan = parse_plan(summary)

      if plan
        agent_run.log!("system", "Detected cross-repo issue plan targeting #{plan[:target_repo]}")

        logger.info(
          message: "agent_execution.cross_repo_plan_detected",
          agent_run_id: agent_run_id,
          target_repo: plan[:target_repo]
        )
      end

      { agent_run_id: agent_run_id, plan: plan }
    end

    private

    def parse_plan(summary)
      return nil if summary.blank?

      target_repo = summary[UPSTREAM_REPO_PATTERN, 1]
      return nil unless target_repo

      upstream_title = summary[UPSTREAM_TITLE_PATTERN, 1]&.strip
      upstream_body = summary[UPSTREAM_BODY_PATTERN, 1]&.strip

      return nil if upstream_title.blank? || upstream_body.blank?

      downstream_body = summary
        .gsub(UPSTREAM_REPO_PATTERN, "")
        .gsub(UPSTREAM_TITLE_PATTERN, "")
        .gsub(UPSTREAM_BODY_PATTERN, "")
        .strip

      {
        target_repo: target_repo,
        upstream_title: upstream_title,
        upstream_body: upstream_body,
        downstream_body: downstream_body.presence
      }
    end
  end
end
