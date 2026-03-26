# frozen_string_literal: true

require "open3"
require "timeout"

module Knowledge
  class BaseCollector
    attr_reader :project, :project_version, :collector_run, :options

    def initialize(project:, project_version:, collector_run:, options: {})
      @project = project
      @project_version = project_version
      @collector_run = collector_run
      @options = options
    end

    # Must return Array<Hash> with keys:
    #   artifact_type:, scope_path:, identifier:, content:, metadata:, chunks: [...]
    # Each chunk: { chunk_type:, content:, scope_tags:, sequence: }
    def collect
      raise NotImplementedError, "#{self.class}#collect must be implemented"
    end

    def collector_type
      raise NotImplementedError, "#{self.class}#collector_type must be implemented"
    end

    def tool_version
      nil
    end

    private

    def resolve_repo_path
      project.worktrees.order(created_at: :desc).first&.path || default_repo_path
    end

    def default_repo_path
      path = Rails.root.join("tmp", "repos", project.id.to_s)
      path.exist? ? path.to_s : nil
    end

    def run_command(*argv, timeout: 30)
      stdout_str = +""
      stderr_str = +""
      status = nil

      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin&.close

        out_thread = Thread.new do
          Thread.current.report_on_exception = false
          stdout_str << stdout.read.to_s
        rescue IOError
          # IO closed during timeout cleanup — expected
        end
        err_thread = Thread.new do
          Thread.current.report_on_exception = false
          stderr_str << stderr.read.to_s
        rescue IOError
          # IO closed during timeout cleanup — expected
        end

        begin
          Timeout.timeout(timeout) do
            status = wait_thr.value
            out_thread.join
            err_thread.join
          end
        rescue Timeout::Error
          kill_process_group(wait_thr.pid)
          # Reap with a short timeout to avoid blocking forever if the process
          # cannot be signaled (e.g. EPERM from kill_process_group).
          reap_thread = Thread.new { wait_thr.value }
          unless reap_thread.join(5)
            reap_thread.kill
          end
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
          out_thread.join(5)
          err_thread.join(5)
          raise Timeout::Error, "Command timed out after #{timeout} seconds: #{argv.join(' ')}"
        ensure
          stdout.close unless stdout.closed?
          stderr.close unless stderr.closed?
        end
      end

      unless status&.success?
        raise "Command failed (exit #{status&.exitstatus}) for `#{argv.join(' ')}`: #{stderr_str.first(500)}"
      end

      stdout_str
    end

    def kill_process_group(pid)
      # Errno::ESRCH from getpgid (process already exited) is caught by the
      # method-level rescue below, keeping timeout cleanup deterministic.
      pgid = Process.getpgid(pid)
      Process.kill("TERM", -pgid)
      sleep 1
      Process.kill("KILL", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      # Process already exited or cannot be signaled
    end
  end
end
