# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunResourceProfiles::RefreshForRun do
  describe ".call" do
    let(:project) { create(:project) }
    let(:completed_at) { Time.current.change(usec: 0) }
    let(:specific_lookup_key) do
      AgentRunResourceProfile.lookup_key_for(
        profile_level: "specific",
        account_id: project.account_id,
        project_id: project.id,
        runner_key: "claude",
        goal: "create_pr"
      )
    end

    def create_sample_run(memory_bytes:, completed_at:, status: "completed", oom: false)
      run = create(:agent_run,
        project: project,
        goal: "create_pr",
        agent_type: "claude_code",
        final_runner: "claude",
        status: status,
        started_at: completed_at - 10.minutes,
        completed_at: completed_at,
        peak_memory_bytes: memory_bytes)

      create(:container_metric,
        agent_run: run,
        memory_bytes: memory_bytes,
        memory_limit_bytes: oom ? memory_bytes : (memory_bytes + 256.megabytes))

      if oom
        run.update_columns(
          error_message: "Command failed (container OOM-killed; memory limit #{(memory_bytes / 1024.0**3).round(1)} GB)"
        )
      end

      run
    end

    def specific_profile
      AgentRunResourceProfile.find_by!(lookup_key: specific_lookup_key)
    end

    it "creates rollups for each fallback scope from terminal run samples" do
      create_sample_run(memory_bytes: 1.gigabyte, completed_at: completed_at - 2.days)
      create_sample_run(memory_bytes: 2.gigabytes, completed_at: completed_at - 1.day, status: "failed", oom: true)
      latest_run = create_sample_run(memory_bytes: 3.gigabytes, completed_at: completed_at)

      expect {
        described_class.call(agent_run: latest_run)
      }.to change(AgentRunResourceProfile, :count).by(5)

      expect(specific_profile).to have_attributes(
        sample_count: 3,
        oom_count: 1,
        last_oom_at: completed_at - 1.day,
        p50_memory_bytes: 2.gigabytes,
        max_memory_bytes: 3.gigabytes
      )
      expect(specific_profile.p95_memory_bytes).to be > specific_profile.p50_memory_bytes
      expect(specific_profile.recommended_memory_limit_bytes).to be >= specific_profile.max_memory_bytes
    end

    it "uses the memory limit as the effective sample when an OOM caps observed usage" do
      run = create(:agent_run,
        :failed,
        project: project,
        goal: "create_pr",
        agent_type: "claude_code",
        final_runner: "claude",
        completed_at: completed_at,
        peak_memory_bytes: 1.gigabyte,
        error_message: "Command failed (container OOM-killed; memory limit 2.0 GB)")
      create(:container_metric,
        agent_run: run,
        memory_bytes: 1.gigabyte,
        memory_limit_bytes: 2.gigabytes)

      2.times do |index|
        create_sample_run(memory_bytes: (index + 2).gigabytes, completed_at: completed_at - (index + 1).days)
      end

      described_class.call(agent_run: run)

      expect(specific_profile.p50_memory_bytes).to eq(2.gigabytes)
      expect(specific_profile.oom_count).to eq(1)
      expect(specific_profile.recommended_memory_limit_bytes).to be >= (2.gigabytes * 1.25).ceil
    end

    it "bumps the recommended limit for an OOM run without a container memory limit" do
      # OOM-killed run whose peak we observed but which has no ContainerMetric
      # row, so memory_limit_bytes defaults to 0. The bump must still fire,
      # using the observed peak as the conservative basis.
      oom_run = create(:agent_run,
        :failed,
        project: project,
        goal: "create_pr",
        agent_type: "claude_code",
        final_runner: "claude",
        completed_at: completed_at,
        peak_memory_bytes: 2.gigabytes,
        error_message: "Command failed (container OOM-killed; memory limit 2.0 GB)")

      2.times do |index|
        create_sample_run(memory_bytes: (index + 1).gigabytes, completed_at: completed_at - (index + 1).days)
      end

      described_class.call(agent_run: oom_run)

      profile = specific_profile
      expect(profile.oom_count).to eq(1)
      expect(profile.max_memory_bytes).to eq(2.gigabytes)
      expect(profile.recommended_memory_limit_bytes).to be >= (2.gigabytes * 1.25).ceil
    end

    it "marks the profile capacity-blocked when OOMs persist near the user ceiling" do
      project.created_by.settings.update!(
        container_memory_auto_ceiling_bytes: 4.gigabytes
      )

      oom_run = create_sample_run(memory_bytes: 4.gigabytes, completed_at: completed_at, status: "failed", oom: true)
      create_sample_run(memory_bytes: 4.gigabytes, completed_at: completed_at - 1.day, status: "failed", oom: true)
      create_sample_run(memory_bytes: 4.gigabytes, completed_at: completed_at - 2.days, status: "failed", oom: true)

      described_class.call(agent_run: oom_run)

      profile = specific_profile
      expect(profile.oom_count).to eq(3)
      expect(profile.capacity_blocked).to be(true)
      expect(profile.capacity_blocked_at).to be_present
    end

    it "does not tune downward until the sustained low-memory threshold is met" do
      project.created_by.settings.update!(
        container_memory_auto_floor_bytes: 256.megabytes,
        container_memory_auto_ceiling_bytes: 16.gigabytes
      )

      # First refresh seeds the profile from observed samples (≈ 1.2 GB).
      create_sample_run(memory_bytes: 1.gigabyte, completed_at: completed_at - 2.days)
      create_sample_run(memory_bytes: 1.gigabyte, completed_at: completed_at - 1.day)
      first_refresh_run = create_sample_run(memory_bytes: 1.gigabyte, completed_at: completed_at)

      described_class.call(agent_run: first_refresh_run)

      profile = specific_profile
      expect(profile.recommended_memory_limit_bytes).to be > 1.gigabyte
      starting_limit = profile.recommended_memory_limit_bytes

      # Subsequent low-memory refreshes should NOT collapse the limit below
      # the existing recommendation until the sustained counter is met.
      2.times do |index|
        next_run = create_sample_run(memory_bytes: 1.gigabyte, completed_at: completed_at + (index + 1).hours)
        described_class.call(agent_run: next_run)
      end

      expect(profile.reload.recommended_memory_limit_bytes).to eq(starting_limit)
      expect(profile.downward_tuning_count).to eq(0)
    end
  end
end
