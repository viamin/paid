# frozen_string_literal: true

module Dashboard
  class QueuePreview
    Entry = Struct.new(:position, :run, keyword_init: true)
    CACHE_TTL = 10.seconds

    MAX_SCAN = 200

    def self.call(...)
      new(...).call
    end

    def initialize(user:, limit: 20)
      @user = user
      @limit = limit
    end

    def call
      return [] if visible_project_ids.empty?

      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_entries }
    end

    private

    attr_reader :user, :limit

    def build_entries
      snapshot = fetch_snapshot
      visible_runs = snapshot.select { |run| visible_project_ids.include?(run.project_id) }
      preload_associations(visible_runs)

      visible_runs.first(limit).each_with_index.map do |run, index|
        Entry.new(position: index + 1, run:)
      end
    end

    def visible_project_ids
      @visible_project_ids ||= begin
        scope = Project.where(account_id: user.account_id, created_by_id: user.id)
        if AgentRun.orphaned_project_owner?(user)
          scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil))
        end

        scope.ids
      end
    end

    def fetch_snapshot
      AgentRun.schedulable_queued_with_priority
              .reorder(*AgentRun::QUEUE_ORDER)
              .limit(MAX_SCAN)
              .to_a
    end

    def preload_associations(runs)
      ActiveRecord::Associations::Preloader.new(
        records: runs,
        associations: [ { issue: :project }, :project ]
      ).call
      AgentRun.preload_source_pull_requests(runs)
      AgentRun.preload_created_issue_records(runs)
    end

    def cache_key
      "dashboard/queue_preview/#{user.account_id}/#{user.id}/#{Dashboard::CacheVersion.current(user.account, scope: Dashboard::CacheVersion::LISTS_SCOPE)}"
    end
  end
end
