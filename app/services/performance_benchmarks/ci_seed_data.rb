# frozen_string_literal: true

module PerformanceBenchmarks
  class CiSeedData
    ACCOUNT_SLUG = "performance-benchmarks"
    USER_EMAIL = "performance-benchmarks@example.com"
    REPO_GITHUB_ID = 723_136_700
    COMMIT_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    BENCHMARK_QUERY = "PerformanceBenchmarks::CiSeedData"

    def self.call(...)
      new(...).call
    end

    def initialize(now: Time.current)
      @now = now
    end

    FIXTURE_RUNS = [
      { offset_minutes: 10, duration_seconds: 540, provision_seconds: 10, commit: "b" * 40, pr_number: 1 },
      { offset_minutes: 60, duration_seconds: 420, provision_seconds: 8,  commit: "c" * 40, pr_number: 2 },
      { offset_minutes: 180, duration_seconds: 600, provision_seconds: 12, commit: "d" * 40, pr_number: 3 },
      { offset_minutes: 360, duration_seconds: 480, provision_seconds: 9,  commit: "e" * 40, pr_number: 4 },
      { offset_minutes: 720, duration_seconds: 510, provision_seconds: 11, commit: "f" * 40, pr_number: 5 }
    ].freeze

    def call
      raise "Performance benchmark CI seed data is only supported in test." unless Rails.env.test?

      ActiveRecord::Base.transaction do
        seed_agent_runs
        seed_knowledge_artifact
      end
    end

    private

    attr_reader :now

    def seed_agent_runs
      FIXTURE_RUNS.each do |fixture|
        run = AgentRun.find_or_initialize_by(
          project: project,
          custom_prompt: "Benchmark fixture ##{fixture.fetch(:pr_number)}"
        )
        run.assign_attributes(
          agent_type: "claude_code",
          trigger_type: "manual",
          status: "completed",
          goal: "create_pr",
          created_at: now - fixture.fetch(:offset_minutes).minutes,
          started_at: now - fixture.fetch(:offset_minutes).minutes + 1.minute,
          completed_at: now - fixture.fetch(:offset_minutes).minutes + fixture.fetch(:duration_seconds).seconds,
          duration_seconds: fixture.fetch(:duration_seconds),
          result_commit_sha: fixture.fetch(:commit),
          pull_request_url: "https://github.com/paid/performance-benchmarks/pull/#{fixture.fetch(:pr_number)}",
          pull_request_number: fixture.fetch(:pr_number)
        )
        run.save!

        provision_start = now - fixture.fetch(:offset_minutes).minutes + 1.minute
        AgentRunPhase.find_or_initialize_by(agent_run: run, phase_key: "provision_container").tap do |phase|
          phase.assign_attributes(
            phase_group: "setup",
            status: "completed",
            started_at: provision_start,
            finished_at: provision_start + fixture.fetch(:provision_seconds).seconds,
            duration_seconds: fixture.fetch(:provision_seconds),
            metadata: { source: "performance_benchmark_ci_seed" }
          )
          phase.save!
        end

        ContainerPoolEntry.find_or_initialize_by(project: project, workspace_volume: "paid-pool-workspace-fixture-#{fixture.fetch(:pr_number)}").tap do |entry|
          entry.assign_attributes(
            agent_run: run,
            status: "claimed",
            container_id: "pool-container-fixture-#{fixture.fetch(:pr_number)}",
            image: Containers::Provision::DEFAULTS[:image],
            network: "paid_agent",
            warmed_at: provision_start - 30.seconds,
            claimed_at: provision_start,
            last_error: nil
          )
          entry.save!
        end
      end
    end

    def seed_knowledge_artifact
      KnowledgeChunk.find_or_initialize_by(knowledge_artifact: knowledge_artifact, sequence: 0).tap do |chunk|
        chunk.assign_attributes(
          project: project,
          chunk_type: "definition",
          status: "active",
          content: "Performance benchmark fixture for exact knowledge search latency.",
          content_hash: Digest::SHA256.hexdigest("performance-benchmark-ci-seed-chunk"),
          scope_tags: [ "performance", "benchmark" ]
        )
        chunk.save!
      end
    end

    def knowledge_artifact
      @knowledge_artifact ||= KnowledgeArtifact.find_or_initialize_by(
        collector_run: collector_run,
        content_hash: Digest::SHA256.hexdigest("performance-benchmark-ci-seed-artifact")
      ).tap do |artifact|
        artifact.assign_attributes(
          project: project,
          collector_type: collector_run.collector_type,
          artifact_type: "service",
          scope_path: "app/services/performance_benchmarks/ci_seed_data.rb",
          identifier: BENCHMARK_QUERY,
          content: "Performance benchmark fixture",
          metadata: { source: "performance_benchmark_ci_seed" },
          status: "active"
        )
        artifact.save!
      end
    end

    def collector_run
      @collector_run ||= CollectorRun.find_or_initialize_by(
        project_version: project_version,
        collector_type: "performance_benchmark"
      ).tap do |run|
        run.assign_attributes(
          status: "completed",
          started_at: now - 5.minutes,
          completed_at: now - 4.minutes,
          duration_ms: 60_000,
          artifacts_count: 1,
          metadata: { source: "performance_benchmark_ci_seed" }
        )
        run.save!
      end
    end

    def project_version
      @project_version ||= ProjectVersion.find_or_create_by!(project: project, commit_sha: COMMIT_SHA) do |version|
        version.branch = "main"
        version.committed_at = now - 1.day
        version.metadata = { source: "performance_benchmark_ci_seed" }
      end
    end

    def project
      @project ||= Project.find_or_create_by!(account: account, github_id: REPO_GITHUB_ID) do |project|
        project.github_token = github_token
        project.created_by = user
        project.name = "Performance Benchmarks"
        project.owner = "paid"
        project.repo = "performance-benchmarks"
        project.default_branch = "main"
        project.allowed_github_usernames = [ "paid-benchmark" ]
        project.knowledge_status = "ready"
      end
    end

    def github_token
      @github_token ||= GithubToken.find_or_create_by!(account: account, name: "Performance benchmark token") do |token|
        token.created_by = user
        token.token = "ghp_#{"a" * 36}"
        token.validation_status = "validated"
        token.scopes = [ "repo" ]
      end
    end

    def user
      @user ||= User.find_or_create_by!(email: USER_EMAIL) do |user|
        user.account = account
        user.name = "Performance Benchmark"
        user.password = "password"
        user.password_confirmation = "password"
      end
    end

    def account
      @account ||= Account.find_or_create_by!(slug: ACCOUNT_SLUG) do |account|
        account.name = "Performance Benchmarks"
        account.plan = "trial"
      end
    end
  end
end
