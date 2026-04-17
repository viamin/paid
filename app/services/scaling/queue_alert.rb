# frozen_string_literal: true

module Scaling
  class QueueAlert
    def self.call(...)
      new(...).call
    end

    def initialize(account:, alerts:)
      @account = account
      @alerts = alerts
    end

    def call
      alerts.each { |alert| publish_notification(alert) }
      resolve_cleared_queues
    end

    private

    attr_reader :account, :alerts

    def publish_notification(alert)
      severity = alert.severity == :critical ? :error : :warning
      Notifications::Publish.call(
        account: account,
        source: "queue_monitor",
        subject: account,
        severity: severity,
        title: "Queue depth #{alert.severity}: #{alert.queue_name}",
        description: "#{alert.queue_name} (#{alert.queue_type}) has #{alert.depth} pending items (threshold: #{alert.threshold})",
        metadata: {
          queue_name: alert.queue_name,
          queue_type: alert.queue_type,
          depth: alert.depth,
          threshold: alert.threshold
        },
        action_url: "/dashboard",
        nav_section: "dashboard"
      )
    end

    def resolve_cleared_queues
      alerted_queue_names = alerts.map(&:queue_name)

      scope = Notification.where(
        account: account,
        source: "queue_monitor"
      ).active

      if alerted_queue_names.any?
        scope = scope.where.not("metadata->>'queue_name' IN (?)", alerted_queue_names)
      end

      scope.update_all(resolved_at: Time.current)
    end
  end
end
