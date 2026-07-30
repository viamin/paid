# frozen_string_literal: true

module Dashboard
  class QueuePreview
    Entry = Struct.new(:position, :run, keyword_init: true)
    CACHE_TTL = 10.seconds

    # Sample more queued rows than we display so the fair-share replay can see
    # additional projects before the preview limit truncates the result.
    MAX_SCAN = 500

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

      interleave_by_dispatch_order(visible_runs).each_with_index.map do |run, index|
        Entry.new(position: index + 1, run:)
      end
    end

    # Renders the queue in the round-robin dispatch order the scheduler aims
    # for, instead of the static project_active_count snapshot. QUEUE_ORDER
    # clusters every run from an idle project at the top (they share the same
    # current active-count tier), so a backlog-heavy project looks like it
    # will monopolize every agent slot. In reality the scheduler claims one
    # run, increments that project's active count, then moves to whichever
    # project now has the fewest in-flight runs. Replaying that here
    # interleaves projects so a single project's backlog can't visually
    # starve the rest.
    #
    # This is an approximation of dispatch order, not an exact prediction:
    # in-flight counts only increase as runs are "dispatched" (run completion
    # would decrement them), so the result reflects steady-state fair-share
    # ordering rather than wall-clock timing. Per-project run order (priority,
    # then FIFO) is preserved because the snapshot is already sorted by
    # QUEUE_ORDER, so grouping by project keeps each project's runs in their
    # correct sequence. The user_active_count tier is constant across a
    # user's visible projects (orphaned projects resolve to the same fallback
    # owner), so it is intentionally omitted from the tiebreak.
    def interleave_by_dispatch_order(visible_runs)
      active_counts = AgentRun
        .capacity_inflight
        .where(project_id: visible_project_ids)
        .group(:project_id)
        .count

      queues = visible_runs.group_by(&:project_id).transform_values { |runs| runs.dup }
      active = active_counts.transform_values(&:to_i)

      interleaved = []
      while interleaved.size < limit
        candidates = queues.reject { |_, queued| queued.empty? }
        break if candidates.empty?

        project_id = candidates.min_by { |pid, queued| [ active[pid].to_i, queued.first.queue_order_rank ] }.first
        run = queues[project_id].shift
        active[project_id] = active[project_id].to_i + 1
        interleaved << run
      end
      interleaved
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
