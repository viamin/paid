# frozen_string_literal: true

module Activities
  # Fetches issue details and knowledge base context for planning.
  # Gathers codebase knowledge via semantic search to inform feature decomposition.
  class FetchPlanningContextActivity < BaseActivity
    activity_name "FetchPlanningContext"

    MAX_CONTEXT_RESULTS = 10

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]

      project = Project.find(project_id)
      issue = project.issues.find(issue_id)

      context = build_context(project, issue)

      logger.info(
        message: "planning.context_fetched",
        project_id: project_id,
        issue_id: issue_id,
        knowledge_results: context[:knowledge_results_count]
      )

      { context: context }
    end

    private

    def build_context(project, issue)
      knowledge = fetch_knowledge(project, issue)

      {
        issue_title: issue.title,
        issue_body: issue.body.to_s.truncate(10_000),
        issue_labels: issue.labels,
        project_name: project.name,
        knowledge_snippets: knowledge,
        knowledge_results_count: knowledge.size
      }
    end

    def fetch_knowledge(project, issue)
      query = "#{issue.title} #{issue.body.to_s.truncate(500)}"
      result = Knowledge::Search.call(
        project: project,
        query: query,
        mode: "semantic",
        limit: MAX_CONTEXT_RESULTS
      )
      result[:results].map { |r| { title: r[:title], content: r[:content].to_s.truncate(2000) } }
    rescue => e
      logger.warn(
        message: "planning.knowledge_fetch_failed",
        project_id: project.id,
        issue_id: issue.id,
        error_class: e.class.name,
        error: e.message
      )
      []
    end
  end
end
