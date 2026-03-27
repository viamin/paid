# frozen_string_literal: true

module Activities
  # Determines whether a merged PR requires a lightweight or full dev
  # environment update, then spawns `bin/dev-update` in a detached process.
  #
  # Only triggers for PRs merged on the Paid repository itself (detected via
  # the PAID_REPO_FULL_NAME environment variable). No-ops for other repos.
  #
  # Lightweight update (git pull only):
  #   Any changes that do not match FULL_RESTART_PATTERNS. This includes most
  #   Rails-autoloaded app/ code as well as non-critical files such as docs.
  #
  # Full restart (git pull + Overmind stop + bin/setup):
  #   Any changes matching FULL_RESTART_PATTERNS: Temporal code under
  #   app/temporal/, config changes, database migrations, Gemfile/lockfile
  #   or JS dependency/lockfile changes, bin/ scripts, lib/ code, or the
  #   Procfile.
  class TriggerDevEnvironmentUpdateActivity < BaseActivity
    activity_name "TriggerDevEnvironmentUpdate"

    FULL_RESTART_PATTERNS = [
      %r{\Aapp/temporal/},
      %r{\Aconfig/},
      %r{\Adb/migrate/},
      %r{\AGemfile},
      %r{\Ayarn\.lock\z},
      %r{\Apackage-lock\.json\z},
      %r{\Apackage\.json\z},
      %r{\Abin/},
      %r{\Alib/},
      %r{\AProcfile}
    ].freeze

    def execute(input)
      project = Project.find(input[:project_id])
      pr_number = input[:pr_number]

      unless self_repo?(project)
        logger.info(
          message: "dev_update.skipped_external_repo",
          project_id: project.id,
          pr_number: pr_number
        )
        return { triggered: false, reason: "not_self_repo" }
      end

      changed_files = fetch_changed_files(project, pr_number)
      return { triggered: false, reason: "no_changed_files" } if changed_files.empty?

      restart_trigger_files = full_restart_trigger_files(changed_files)
      mode = determine_update_mode(restart_trigger_files)
      return { triggered: false, reason: "spawn_failed" } unless trigger_update(mode)

      logger.info(
        message: "dev_update.triggered",
        project_id: project.id,
        pr_number: pr_number,
        mode: mode,
        changed_files_count: changed_files.size,
        changed_files: changed_files,
        restart_trigger_files: restart_trigger_files
      )

      { triggered: true, mode: mode, changed_files_count: changed_files.size }
    end

    private

    def self_repo?(project)
      paid_repo = ENV["PAID_REPO_FULL_NAME"]
      return false if paid_repo.blank?

      project.full_name.casecmp?(paid_repo)
    end

    def fetch_changed_files(project, pr_number)
      client = project.github_token.client
      client.pull_request_files(project.full_name, pr_number)
    rescue GithubClient::Error => e
      logger.warn(
        message: "dev_update.fetch_files_failed",
        project_id: project.id,
        pr_number: pr_number,
        error: e.message
      )
      []
    end

    def determine_update_mode(restart_trigger_files)
      restart_trigger_files.any? ? "full" : "lightweight"
    end

    def full_restart_trigger_files(changed_files)
      changed_files.select do |file|
        FULL_RESTART_PATTERNS.any? { |pattern| pattern.match?(file) }
      end
    end

    def trigger_update(mode)
      script = File.expand_path("../../../bin/dev-update", __dir__)
      flag = mode == "full" ? "--full" : "--lightweight"
      log_path = Rails.root.join("log", "dev-update", "dev-update.log")
      log_path.dirname.mkpath

      # Spawn detached so the Temporal worker (which runs under Overmind)
      # is not the parent — setsid creates a new session.
      pid = Process.spawn(
        "setsid", script, flag,
        out: [ log_path.to_s, "a" ],
        err: [ log_path.to_s, "a" ]
      )
      Process.detach(pid)

      logger.info(
        message: "dev_update.process_spawned",
        pid: pid,
        mode: mode,
        log_path: log_path.to_s
      )

      true
    rescue Errno::ENOENT, Errno::EACCES => e
      # Best-effort: if setsid or bin/dev-update is missing/not executable,
      # log and return gracefully rather than failing the activity.
      logger.warn(
        message: "dev_update.spawn_failed",
        mode: mode,
        error: e.message
      )
      nil
    end
  end
end
