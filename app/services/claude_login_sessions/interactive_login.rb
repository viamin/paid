# frozen_string_literal: true

require "shellwords"

module ClaudeLoginSessions
  class InteractiveLogin
    CONFIG_DIR = "/home/agent/.claude-session".freeze
    CREDENTIALS_PATH = "#{CONFIG_DIR}/.credentials.json"
    OAUTH_URL_PATTERN = %r{https://claude\.com/\S+|https://claude\.ai/\S+}.freeze
    IMAGE = Containers::Provision::DEFAULTS.fetch(:image)

    def initialize(session:, backend: Containers.backend)
      @session = session
      @backend = backend
      @coordination = ClaudeLoginSessions::Coordination.new(session: session)
      @mutex = Mutex.new
      @url_ready = ConditionVariable.new
      @last_output = +""
      @running = false
    end

    def start
      create_container!
      coordination.register_live!
      @running = true
      spawn_login_process!
    rescue StandardError
      cleanup
      raise
    end

    def wait_for_url(timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

      mutex.synchronize do
        until session.oauth_url.present? || session.terminal?
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if remaining <= 0

          url_ready.wait(mutex, remaining)
        end
      end
    end

    def cleanup
      @running = false
      close_io(writer)
      close_io(reader)
      coordination.clear!
      cleanup_container
    end

    private

    attr_reader :session, :backend, :container, :reader, :writer, :wait_thread, :mutex, :url_ready, :last_output, :coordination

    def create_container!
      @container = backend.create_container(
        "Image" => IMAGE,
        "name" => "paid-claude-login-#{session.id}-#{SecureRandom.hex(4)}",
        "User" => "agent",
        "ReadonlyRootfs" => true,
        "CapDrop" => [ "ALL" ],
        "SecurityOpt" => [ "no-new-privileges:true" ],
        "WorkingDir" => "/home/agent",
        "Env" => [ "HOME=/home/agent" ],
        "Cmd" => [ "tail", "-f", "/dev/null" ],
        "Tty" => false,
        "OpenStdin" => false,
        "HostConfig" => {
          "Memory" => 512 * 1024 * 1024,
          "MemorySwap" => 512 * 1024 * 1024,
          "CpuPeriod" => 100_000,
          "CpuQuota" => 50_000,
          "PidsLimit" => 128,
          "NetworkMode" => NetworkPolicy::INFRA_NETWORK_NAME,
          "Tmpfs" => {
            "/tmp" => "exec,size=268435456,mode=1777",
            "/home/agent" => "exec,size=67108864,mode=700"
          }
        }
      )
      backend.start_container(container)
      backend.exec_in_container(container, [ "sh", "-lc", "mkdir -p #{Shellwords.escape(CONFIG_DIR)} && chown -R agent:agent /home/agent" ], user: "root")

      session.update!(container_id: container.id)
    end

    def spawn_login_process!
      @reader, @writer = IO.pipe
      @wait_thread = spawn_worker_thread do
        exit_code = run_login_exec!
        finalize_process!(exit_code)
      ensure
        close_io(reader)
      end
      spawn_heartbeat_thread!
      spawn_code_consumer_thread!
      spawn_deadline_watcher_thread!
    end

    def spawn_heartbeat_thread!
      spawn_worker_thread do
        while running?
          coordination.refresh_live!
          sleep(ClaudeLoginSessions::Coordination::LIVE_TTL / 2.0)
        end
      rescue StandardError => e
        session.fail!(e.message) unless session.terminal?
      end
    end

    def spawn_code_consumer_thread!
      spawn_worker_thread do
        while running?
          submitted_code = coordination.pop_code
          next if submitted_code.blank?

          write_code_to_process(submitted_code)
        end
      rescue StandardError => e
        session.fail!(e.message) unless session.terminal?
      end
    end

    def spawn_deadline_watcher_thread!
      spawn_worker_thread do
        while running?
          enforce_deadline!
          sleep(1)
        end
      rescue StandardError => e
        session.fail!(e.message) unless session.terminal?
      end
    end

    def spawn_worker_thread(&block)
      Thread.new do
        run_in_thread_context(&block)
      end.tap do |thread|
        thread.report_on_exception = false
      end
    end

    def run_in_thread_context(&block)
      executor = Rails.application.executor if defined?(Rails) && Rails.respond_to?(:application) && Rails.application.respond_to?(:executor)
      thread_scoped = proc do
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connection_pool)
          ActiveRecord::Base.connection_pool.with_connection do
            run_in_tenant_context(&block)
          end
        else
          run_in_tenant_context(&block)
        end
      end

      executor ? executor.wrap(&thread_scoped) : thread_scoped.call
    end

    def run_in_tenant_context(&block)
      account = TenantContext.with_system_access { Account.find_by(id: session.account_id) }

      if account
        TenantContext.with(account, &block)
      else
        TenantContext.with_system_access(&block)
      end
    end

    def consume_output(chunk)
      output = append_output(chunk)

      match = output.match(OAUTH_URL_PATTERN)
      return unless match
      return if session.oauth_url.present?

      session.update!(oauth_url: match[0], status: "awaiting_code")
      signal_waiters
    end

    def append_output(chunk)
      mutex.synchronize do
        last_output << chunk.to_s
        last_output.slice!(0, last_output.length - 4000) if last_output.length > 4000
        last_output.dup
      end
    end

    def write_code_to_process(code)
      raise ArgumentError, "authorization code is blank" if code.blank?

      writer.puts(code)
      writer.flush
    end

    def enforce_deadline!
      return if session.reload.terminal?
      return unless session.expired?

      message = "This Claude login session expired before the browser login completed."
      session.fail!(message)
      record_failure_audit(message)
      signal_waiters
      cleanup
    end

    def finalize_process!(exit_code)
      credentials_json = read_container_file(CREDENTIALS_PATH)

      if exit_code.to_i.zero? && credentials_json.present?
        persist_captured_credentials!(credentials_json)
      elsif !session.terminal?
        session.fail!(last_output.presence || "Claude login exited before a credential was captured.")
        record_failure_audit(last_output.presence)
      end
    rescue StandardError => e
      session.fail!(e.message) unless session.terminal?
      record_failure_audit(e.message)
    ensure
      signal_waiters
      cleanup
    end

    def persist_captured_credentials!(credentials_json)
      parsed = ClaudeCredentials::Secret.parse(credentials_json)
      raise "Claude login did not produce a native .credentials.json payload" unless parsed.native_credentials_json?

      credential = existing_or_new_claude_runner_credential

      credential.assign_attributes(
        created_by: session.created_by,
        auth_kind: "oauth_token",
        token: credentials_json,
        long_lived: false,
        revoked_at: nil,
        expires_at: parsed.expires_at,
        metadata: credential.metadata.to_h.merge(
          "source" => "browser_completed_login",
          "storage_format" => "claude_credentials_json",
          "access_token_expires_at" => parsed.expires_at&.iso8601,
          "subscription_type" => parsed.subscription_type,
          "scopes" => parsed.scopes
        ).compact
      )
      credential.save!

      session.update!(
        runner_credential: credential,
        status: "completed",
        completed_at: Time.current,
        error_message: nil,
        expires_at: parsed.expires_at
      )

      Audit::RecordEvent.call(
        action: "runner.claude_login_completed",
        actor: session.created_by,
        subject: credential,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: [ "Captured native Claude OAuth credential via server-side login session." ]
        }
      )
    end

    def existing_or_new_claude_runner_credential
      session.account.runner_credentials.find_or_initialize_by(
        runner_key: "claude",
        name: session.credential_name
      )
    end

    def record_failure_audit(message)
      Audit::RecordEvent.call(
        action: "runner.claude_login_failed",
        actor: session.created_by,
        subject: session,
        account: session.account,
        metadata: {
          credential_name: session.credential_name,
          details: Array(message).compact
        }
      )
    rescue StandardError
      nil
    end

    def read_container_file(path)
      stdout, _stderr, exit_code = backend.exec_in_container(
        container,
        [ "sh", "-lc", "cat #{Shellwords.escape(path)}" ],
        user: "agent"
      )
      return nil unless exit_code.to_i.zero?

      Array(stdout).join
    rescue Docker::Error::DockerError
      nil
    end

    def run_login_exec!
      _stdout, _stderr, exit_code = backend.exec_in_container(
        container,
        [ "sh", "-lc", "mkdir -p #{Shellwords.escape(CONFIG_DIR)} && claude auth login" ],
        user: "agent",
        tty: true,
        stdin: reader,
        "Env" => [ "HOME=/home/agent", "CLAUDE_CONFIG_DIR=#{CONFIG_DIR}" ]
      ) do |chunk|
        consume_output(chunk)
      end

      exit_code
    end

    def cleanup_container
      return unless container

      backend.stop_container(container, timeout: 0)
      backend.delete_container(container, force: true)
    rescue Docker::Error::DockerError
      nil
    end

    def close_io(io)
      io&.close unless io&.closed?
    rescue IOError
      nil
    end

    def signal_waiters
      mutex.synchronize { url_ready.broadcast }
    end

    def running?
      @running
    end
  end
end
