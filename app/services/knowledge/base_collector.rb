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

    def skip!(reason)
      raise SkipCollector, reason
    end

    def container_runner
      options[:container_runner]
    end

    def containerized?
      container_runner.present?
    end

    # Returns the repo path suitable for passing to commands executed via
    # run_command. In containerized mode this is the container workspace
    # mount (where the repo was seeded), not the host tmpdir.
    def resolve_repo_path
      if containerized?
        container_runner.options[:workspace_mount]
      elsif options[:scan_path]
        options[:scan_path]
      elsif project.respond_to?(:worktrees)
        project.worktrees.order(created_at: :desc).first&.path || default_repo_path
      else
        default_repo_path
      end
    end

    # Reads a file from the repo. In containerized mode reads from the
    # host-side clone so Ruby file I/O works without a container exec.
    def read_repo_file(relative_path)
      full_path = File.join(host_repo_path.to_s, relative_path)
      File.read(full_path)
    end

    # Checks if a file exists in the repo.
    def repo_file_exists?(relative_path)
      full_path = File.join(host_repo_path.to_s, relative_path)
      File.exist?(full_path)
    end

    # Returns the host-side repo path for direct file I/O. In
    # containerized mode this is the host tmpdir clone; otherwise
    # it falls back to resolve_repo_path.
    def host_repo_path
      if containerized?
        container_runner.host_repo_dir
      else
        resolve_repo_path
      end
    end

    def default_repo_path
      path = Rails.root.join("tmp", "repos", project.id.to_s)
      path.exist? ? path.to_s : nil
    end

    def run_command(*argv, timeout: 30)
      return container_runner.execute(argv, timeout: timeout) if containerized?

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
          out_thread.join(5) || begin
            out_thread.kill
            out_thread.join
          end
          err_thread.join(5) || begin
            err_thread.kill
            err_thread.join
          end
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
      sleep timeout_kill_grace_seconds
      Process.kill("KILL", -pgid)
    rescue Errno::ESRCH, Errno::EPERM
      # Process already exited or cannot be signaled
    end

    def timeout_kill_grace_seconds
      options.fetch(:timeout_kill_grace_seconds, 1)
    end
  end
end
