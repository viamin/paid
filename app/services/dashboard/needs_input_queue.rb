# frozen_string_literal: true

module Dashboard
  # Renders the existing /dashboard/needs_input page. Behavior is unchanged
  # from the pre-inbox-foundation version: issues only (`is_pull_request:
  # false`), oldest-first within `(owner, repo, github_number, id)` ordering,
  # and a questionless-filter. The implementation delegates to Inbox::Queue
  # for the queue body and applies the issues-only filter on top.
  #
  # Inbox::Queue is the typed, broader abstraction (issues + PRs, structured
  # entries). Keeping this delegator lets /dashboard/needs_input continue
  # rendering unchanged while the inbox page lands separately.
  class NeedsInputQueue
    Entry = Struct.new(:project, :issue, :questions, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def self.next_issue(...)
      new(...).next_issue
    end

    def initialize(user:, project: nil, after_issue: nil)
      @user = user
      @project = project
      @after_issue = after_issue
    end

    # @spec INBOX-FOUNDATION-007
    def call
      inbox_entries.filter_map do |inbox_entry|
        next unless inbox_entry.issue.is_pull_request == false

        Entry.new(
          project: inbox_entry.project,
          issue: inbox_entry.issue,
          questions: inbox_entry.questions
        )
      end
    end

    def next_issue
      queue = call.map(&:issue)
      return queue.first if after_issue.blank?

      current_index = queue.index { |issue| issue.id == after_issue.id }
      return if current_index.nil?

      queue[(current_index + 1)..]&.first
    end

    private

    attr_reader :after_issue, :project, :user

    # @spec INBOX-FOUNDATION-007
    def inbox_entries
      Inbox::Queue.call(user: user, project: project)
    end
  end
end
