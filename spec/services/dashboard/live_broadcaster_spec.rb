# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::LiveBroadcaster do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  describe ".call" do
    let(:account) { create(:account) }
    let!(:user) { create(:user, account: account) }
    let(:project) { create(:project, account: account, created_by: user) }
    let(:owner) { project.effective_owner }
    let(:agent_run) { create(:agent_run, project: project, status: "running", started_at: 2.minutes.ago) }
    let(:broadcast_updates) { [] }
    let(:broadcast_replacements) { [] }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) do |*args|
        broadcast_updates << args
      end
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to) do |*args|
        broadcast_replacements << args
      end
      allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)
      allow(Dashboard::CacheVersion).to receive(:bump).and_call_original
    end

    it "broadcasts live stats, active runs, and queue preview" do
      queued_run = create(:agent_run, :queued, project: project, created_at: 1.minute.ago)

      described_class.call(account: account, agent_run: agent_run)

      expect_live_dashboard_sections_to_broadcast
      expect(broadcasted_queue_preview).to contain_exactly(
        have_attributes(run: have_attributes(id: queued_run.id))
      )
    end

    it "does not use wildcard cache invalidation" do
      allow(Rails.cache).to receive(:delete_matched).and_call_original

      described_class.call(account: account, agent_run: agent_run)

      expect(Rails.cache).not_to have_received(:delete_matched).with("dashboard/queue_preview/#{account.id}/*")
      expect(Rails.cache).not_to have_received(:delete_matched).with("dashboard/recent_activity/#{account.id}/*")
    end

    it "does not invalidate stats caches during live updates" do
      described_class.call(account: account, agent_run: agent_run)

      expect(Dashboard::CacheVersion).not_to have_received(:bump).with(
        account,
        scope: Dashboard::CacheVersion::STATS_SCOPE
      )
    end

    it "preloads final runner records for active-run fallback rows" do
      initial_provider = create(:runner, user: owner, runner_key: "codex")
      fallback_provider = create(:runner, user: owner, runner_key: "cursor")
      active_run = create(:agent_run,
        project: project,
        status: "running",
        started_at: 1.minute.ago,
        runner: initial_provider,
        final_runner: fallback_provider.routing_key)

      described_class.call(account: account, agent_run: active_run)

      expect(broadcasted_active_runs).to include(
        have_attributes(
          id: active_run.id,
          preloaded_final_runner_record: fallback_provider,
          preloaded_final_runner_record_loaded: true
        )
      )
    end

    it "preloads source pull requests for active-run priority badges" do
      issue = create(:issue, :pull_request, project: project, github_number: 88, labels: [ "P1" ])
      active_run = create(:agent_run,
        project: project,
        status: "running",
        started_at: 1.minute.ago,
        source_pull_request_number: issue.github_number)

      described_class.call(account: account, agent_run: active_run)

      expect(broadcasted_active_runs).to include(
        have_attributes(
          id: active_run.id,
          source_pull_request_record: issue
        )
      )
    end

    it "broadcasts activity stream when a run finishes" do
      agent_run.update!(status: "completed", completed_at: Time.current, duration_seconds: 30)

      # Reload to simulate production: LiveDashboardBroadcastJob reloads the
      # record from the database, so previous_changes will be empty.
      described_class.call(account: account, agent_run: agent_run.reload)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "activity-stream", partial: "dashboard/activity_stream")
      )
    end

    it "broadcasts an alert for failures" do
      agent_run.update!(status: "failed", completed_at: Time.current, error_message: "Boom")

      # Reload to simulate production: LiveDashboardBroadcastJob reloads the
      # record from the database, so previous_changes will be empty.
      described_class.call(account: account, agent_run: agent_run.reload)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to).with(
        [ account, :live_dashboard ],
        hash_including(target: "dashboard-alerts", partial: "dashboard/alert")
      )
    end

    it "broadcasts a warning alert for paused guardrail violations" do
      agent_run.update!(
        status: "paused",
        paused_at: Time.current,
        guardrail_violation_type: "time_limit"
      )

      described_class.call(account: account, agent_run: agent_run.reload)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to).with(
        [ account, :live_dashboard ],
        hash_including(
          target: "dashboard-alerts",
          partial: "dashboard/alert",
          locals: hash_including(
            alert_type: "warning",
            alert_bg_class: "bg-yellow-50",
            alert_text_class: "text-yellow-800",
            message: a_string_including("paused", "time limit", "resume or terminate")
          )
        )
      )
    end

    it "falls back to guardrail context when the violation type column is blank" do
      agent_run.update!(
        status: "paused",
        paused_at: Time.current,
        guardrail_violation_type: nil,
        guardrail_context: { "violation_type" => "cost_limit" }
      )

      described_class.call(account: account, agent_run: agent_run.reload)

      expect(Turbo::StreamsChannel).to have_received(:broadcast_prepend_to).with(
        [ account, :live_dashboard ],
        hash_including(
          locals: hash_including(
            message: a_string_including("cost limit")
          )
        )
      )
    end
  end

  def broadcasted_active_runs
    _stream, options = broadcast_updates.find { |_target, locals| locals[:target] == "active-runs" }
    options.dig(:locals, :active_runs)
  end

  def broadcasted_queue_preview
    _stream, options = broadcast_replacements.find { |args| args.last[:target] == "queue-preview" }
    options.dig(:locals, :queue_preview)
  end

  def expect_live_dashboard_sections_to_broadcast
    expect(Dashboard::CacheVersion).to have_received(:bump).with(
      account,
      scope: Dashboard::CacheVersion::LISTS_SCOPE
    )
    expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
      [ account, :live_dashboard ],
      hash_including(target: "live-stats", partial: "dashboard/live_stats")
    )
    expect(Turbo::StreamsChannel).to have_received(:broadcast_update_to).with(
      [ account, :live_dashboard ],
      hash_including(target: "active-runs", partial: "dashboard/active_runs")
    )
    expect(Turbo::StreamsChannel).to have_received(:broadcast_replace_to).with(
      [ account, user, :live_dashboard ],
      hash_including(target: "queue-preview", partial: "dashboard/queue_preview")
    )
  end
end
