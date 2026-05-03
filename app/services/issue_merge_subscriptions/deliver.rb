# frozen_string_literal: true

module IssueMergeSubscriptions
  class Deliver
    EVENT_CONFIG = {
      merged: {
        item_name: "PR",
        verb: "merged"
      },
      completed: {
        item_name: "Issue",
        verb: "completed"
      }
    }.freeze
    SOURCE = "issue_merge_subscription"

    def self.call(...)
      new(...).call
    end

    def initialize(issue:, event:)
      @issue = issue
      @event = event.to_sym
    end

    def call
      IssueMergeSubscription.transaction do
        subscriptions = issue.issue_merge_subscriptions.on_merge.includes(:user).lock.to_a
        return 0 if subscriptions.empty?

        subscriptions.each do |subscription|
          Notifications::Publish.call(
            account: issue.project.account,
            user: subscription.user,
            source: SOURCE,
            subject: issue,
            severity: :info,
            title: notification_title,
            action_url: issue.github_url,
            nav_section: "projects",
            metadata: notification_metadata
          )
        end

        IssueMergeSubscription.where(id: subscriptions.map(&:id)).delete_all
        subscriptions.size
      end
    end

    private

    attr_reader :issue, :event

    def notification_title
      config = EVENT_CONFIG.fetch(event)
      "#{config[:item_name]} ##{issue.github_number} was #{config[:verb]}: #{issue.title}"
    end

    def notification_metadata
      {
        "event" => event.to_s,
        "github_number" => issue.github_number,
        "issue_id" => issue.id,
        "project_id" => issue.project_id
      }
    end
  end
end
