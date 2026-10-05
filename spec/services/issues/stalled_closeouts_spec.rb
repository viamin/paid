# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseouts do # @spec PARTIAL-CLOSEOUT-002
  let(:account) { create(:account) }
  let(:project) do
    create(
      :project,
      account: account,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:issue) do
    create(:issue, project: project, github_state: "open", paid_state: "in_progress")
  end

  def merged_pr_row(number:, html_url: nil, **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      github_html_url: html_url,
      **attrs
    )
  end

  def completed_create_pr_run(number:, url:)
    create(
      :agent_run,
      :completed,
      project: project,
      issue: issue,
      goal: "create_pr",
      pull_request_number: number,
      pull_request_url: url
    )
  end

  describe ".closeout_evidence_sql" do
    it "matches a parent-linked merged PR via the parent_issue_id prefilter" do
      create(
        :issue,
        :pull_request,
        project: project,
        github_number: 12,
        github_state: "closed",
        pr_review_phase: "merged",
        parent_issue_id: issue.id
      )

      candidate_ids = described_class.candidates_for(project).pluck(:id)

      expect(candidate_ids).to include(issue.id)
    end

    it "matches an agent_run to its own merged PR via URL correlation (not the colliding upstream PR)" do
      # Two PR rows share number 33 in the same project: the local fork PR
      # that the run produced (now merged) and an upstream-synced PR (also
      # merged). The run's URL must pick the fork PR — without the URL
      # correlation the join would surface the upstream PR instead.
      merged_pr_row(number: 33, html_url: "https://github.com/acme/alpha/pull/33")
      completed_create_pr_run(number: 33, url: "https://github.com/acme/alpha/pull/33")
      merged_pr_row(number: 33,
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        html_url: "https://github.com/upstream/repo/pull/33")

      candidate_ids = described_class.candidates_for(project).pluck(:id)

      expect(candidate_ids).to include(issue.id)
    end

    it "matches an agent_run via the null-URL fallback when the PR row has no github_html_url yet" do
      merged_pr_row(number: 44)
      completed_create_pr_run(number: 44, url: "https://github.com/acme/alpha/pull/44")

      candidate_ids = described_class.candidates_for(project).pluck(:id)

      expect(candidate_ids).to include(issue.id)
    end

    it "does not match an agent_run against an upstream-synced PR whose URL is different (#4130 review)" do
      # The exact hazard called out in #4130's review: an agent_run on the
      # project's own fork matches only that fork's PR (via the URL fallback);
      # a number-colliding merged upstream PR must not be treated as terminal
      # evidence for the source issue.
      merged_pr_row(number: 42,
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        html_url: "https://github.com/upstream/repo/pull/42")
      completed_create_pr_run(number: 42, url: "https://github.com/acme/alpha/pull/42")

      candidate_ids = described_class.candidates_for(project).pluck(:id)

      expect(candidate_ids).not_to include(issue.id)
    end

    it "matches an agent_run against a merged upstream PR when the run produced that upstream URL" do
      # Symmetric to the previous test: a run whose pull_request_url targets
      # the upstream repo matches the upstream-synced PR row, so legitimate
      # upstream PRs are not under-counted.
      merged_pr_row(number: 45,
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        html_url: "https://github.com/upstream/repo/pull/45")
      completed_create_pr_run(number: 45, url: "https://github.com/upstream/repo/pull/45")

      candidate_ids = described_class.candidates_for(project).pluck(:id)

      expect(candidate_ids).to include(issue.id)
    end
  end
end
