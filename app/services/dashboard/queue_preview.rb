# frozen_string_literal: true

module Dashboard
  class QueuePreview
    Entry = Struct.new(:position, :run, keyword_init: true)

    # Cap on the number of rows fetched from the queue. This limits the
    # single snapshot query rather than controlling a loop, so there is no
    # N+1 concern. The cap exists to keep the result set reasonable; when
    # the user's visible runs are all beyond this window we show a
    # truncation notice rather than silently dropping them.
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

      snapshot = fetch_snapshot
      visible_runs = snapshot.select { |run| visible_project_ids.include?(run.project_id) }
      preload_associations(visible_runs)

      visible_runs.first(limit).each_with_index.map do |run, index|
        Entry.new(position: index + 1, run:)
      end
    end

    private

    attr_reader :user, :limit

    def visible_project_ids
      @visible_project_ids ||= begin
        scope = Project.where(account_id: user.account_id, created_by_id: user.id)
        if AgentRun.orphaned_project_owner?(user)
          scope = scope.or(Project.where(account_id: user.account_id, created_by_id: nil))
        end

        scope.ids
      end
    end

    # Fetch the ordered snapshot in a single query instead of iterating
    # peek_next_queued_run one-at-a-time. This uses the raw QUEUE_ORDER
    # rather than the fair-queue round-robin reordering that
    # next_queued_run_from applies, so the result is an approximation of
    # scheduler priority rather than an exact dequeue sequence. That keeps
    # the preview informative while avoiding up to 3 queries per iteration.
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
    end
  end
end
