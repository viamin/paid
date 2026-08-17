# frozen_string_literal: true

# Shared context passed to every section provider during a single prompt
# assembly. Carries the issue/project/run inputs plus pre-fetched data
# (like issue comments) so providers that need the same GitHub data don't
# each make a redundant API call.
#
# @!attribute issue
#   @return [Issue, nil]
# @!attribute project
#   @return [Project]
# @!attribute github_client
#   @return [GithubClient, nil]
# @!attribute agent_run
#   @return [AgentRun, nil]
# @!attribute issue_comments
#   @return [Array] pre-fetched trusted/raw issue comments (may be empty)
PromptAssembly::Context = Data.define(:issue, :project, :github_client, :agent_run, :issue_comments) do
  def initialize(issue:, project:, github_client: nil, agent_run: nil, issue_comments: [])
    super
  end
end
