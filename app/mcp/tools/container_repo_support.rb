# frozen_string_literal: true

require "base64"
require "shellwords"

module Tools
  module ContainerRepoSupport
    WORKSPACE_ROOT = "/workspace"
    MAX_TEXT_BYTES = 200 * 1024
    EXEC_TIMEOUT = 60

    private

    def ensure_container_ready!
      raise ArgumentError, "This tool requires a chat session with a running workspace container" if session.blank?
      raise ArgumentError, "This tool requires a running workspace container" if session.container_id.blank?
    end

    def repo_context_for!(repo_path, require_non_stale: false, policy_query: :show?)
      ensure_container_ready!

      manifest_lookup_path = expand_workspace_path(repo_path)
      manifest_entry = session.clone_manifest_entries.find do |entry|
        expand_manifest_path(entry[:path]) == manifest_lookup_path
      end
      normalized_repo_path = normalize_workspace_path(manifest_lookup_path)
      raise ArgumentError, "Repo is not present in the clone manifest: #{manifest_lookup_path}" unless manifest_entry
      if require_non_stale && manifest_entry_stale?(manifest_entry)
        raise ArgumentError, "Repo manifest entry is stale: #{normalized_repo_path}"
      end

      project = project_for_manifest_entry(manifest_entry.fetch(:project_id))
      authorize(project, policy_query, policy_class: ProjectPolicy)

      {
        project: project,
        repo_path: normalized_repo_path,
        manifest_entry: manifest_entry
      }
    end

    def project_for_manifest_entry(project_id)
      @manifest_projects ||= {}
      @manifest_projects[project_id] ||= Project.find_by(id: project_id)
    end

    def project_for_authorization!(repo_path)
      normalized_repo_path = expand_workspace_path(repo_path)
      manifest_entry = session&.clone_manifest_entries&.find do |entry|
        expand_manifest_path(entry[:path]) == normalized_repo_path
      end
      raise ArgumentError, "Repo is not present in the clone manifest: #{normalized_repo_path}" unless manifest_entry

      project_for_manifest_entry(manifest_entry.fetch(:project_id))
    end

    def normalize_workspace_path(path)
      normalized = expand_workspace_path(path)
      resolved = resolve_container_path(normalized)
      return normalized if path_within_root?(resolved, workspace_root_realpath)

      raise ArgumentError, "Path escapes the workspace: #{path}"
    end

    def expand_workspace_path(path)
      candidate = path.to_s.strip
      raise ArgumentError, "repo_path must be provided" if candidate.blank?

      normalized = candidate.start_with?("/") ? File.expand_path(candidate) : File.expand_path(candidate, WORKSPACE_ROOT)
      return normalized if path_within_root?(normalized, WORKSPACE_ROOT)

      raise ArgumentError, "Path escapes the workspace: #{path}"
    end

    def normalize_repo_relative_path(repo_path, relative_path)
      candidate = relative_path.to_s.strip
      raise ArgumentError, "path must be provided" if candidate.blank?

      absolute = File.expand_path(candidate, repo_path)
      resolved_absolute = resolve_container_path(absolute)
      return [ absolute, absolute.delete_prefix("#{repo_path}/") ] if path_within_root?(resolved_absolute, resolve_container_path(repo_path))

      raise ArgumentError, "Path escapes the cloned repo: #{relative_path}"
    end

    def write_repo_text_file!(repo_path:, relative_path:, content:)
      _, normalized_relative_path = normalize_repo_relative_path(repo_path, relative_path)
      env = [ encode_env("FILE_CONTENT_B64", content) ]
      ruby_code = <<~RUBY
        require "base64"

        repo_path = ARGV.fetch(0)
        relative_path = ARGV.fetch(1)
        content = Base64.decode64(ENV.fetch("FILE_CONTENT_B64"))
        repo_realpath = File.realpath(repo_path)
        current = repo_realpath
        components = relative_path.split("/")
        filename = components.pop

        raise ArgumentError, "path must be provided" if filename.nil? || filename.empty? || filename == "." || filename == ".."

        components.each do |component|
          raise ArgumentError, "Path escapes the cloned repo: #{relative_path}" if component.empty? || component == "." || component == ".."

          current = File.join(current, component)

          if File.symlink?(current)
            raise ArgumentError, "Path escapes the cloned repo: #{relative_path}"
          elsif File.exist?(current)
            raise ArgumentError, "Path escapes the cloned repo: #{relative_path}" unless File.directory?(current)
          else
            Dir.mkdir(current)
          end
        end

        destination = File.join(current, filename)
        raise ArgumentError, "Path escapes the cloned repo: #{relative_path}" if File.symlink?(destination)
        raise ArgumentError, "Path escapes the cloned repo: #{relative_path}" if File.exist?(destination) && File.directory?(destination)

        fd = File.sysopen(destination, File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW, 0o644)
        File.open(fd, "wb") { |file| file.write(content) }
      RUBY
      script = "ruby -e #{Shellwords.escape(ruby_code)} #{Shellwords.escape(repo_path)} #{Shellwords.escape(normalized_relative_path)}"
      stdout, stderr, exit_code = git_exec!(script, env:)
      raise ArgumentError, stderr.presence || stdout.presence || "File write failed" unless exit_code.zero?

      normalized_relative_path
    end

    def path_within_root?(path, root)
      path == root || path.start_with?("#{root}/")
    end

    def workspace_root_realpath
      @workspace_root_realpath ||= resolve_container_path(WORKSPACE_ROOT)
    end

    def resolve_container_path(path)
      script = <<~SH
        ruby -e '
          path = ARGV.fetch(0)

          begin
            puts File.realpath(path)
          rescue Errno::ENOENT
            current = path
            missing_components = []

            until File.exist?(current) || File.symlink?(current) || current == File.dirname(current)
              missing_components.unshift(File.basename(current))
              current = File.dirname(current)
            end

            puts File.join(File.realpath(current), *missing_components)
          end
        ' #{Shellwords.escape(path)}
      SH
      stdout, stderr, exit_code = git_exec!(script)
      raise ArgumentError, stderr.presence || stdout.presence || "Path could not be resolved: #{path}" unless exit_code.zero?

      stdout.lines.last.to_s.strip
    end

    def expand_manifest_path(path)
      expand_workspace_path(path)
    rescue ArgumentError
      nil
    end

    def manifest_entry_stale?(manifest_entry)
      manifest_entry[:stale] == true ||
        manifest_entry[:status].to_s == "stale" ||
        manifest_entry[:stale_at].present?
    end

    def ensure_text_payload!(value, field_name:, max_bytes: MAX_TEXT_BYTES)
      bytes = value.to_s.dup.force_encoding("BINARY")
      raise ArgumentError, "#{field_name} exceeds #{max_bytes / 1024}KB size limit" if bytes.bytesize > max_bytes
      raise ArgumentError, "#{field_name} appears to be binary" unless utf8_text?(bytes)
    end

    def utf8_text?(raw)
      return false if raw.include?("\x00")

      raw.dup.force_encoding("UTF-8").valid_encoding?
    end

    def git_exec!(script, env: [])
      container = container_handle
      stdout, stderr, exit_code = Containers.backend.exec_in_container(
        container,
        [ "sh", "-lc", script ],
        user: "agent",
        wait: EXEC_TIMEOUT,
        Env: env
      )
      extend_idle_timeout!

      [ Array(stdout).join, Array(stderr).join, exit_code.to_i ]
    rescue Docker::Error::DockerError => e
      raise ArgumentError, "Workspace command failed: #{e.message}"
    end

    def container_handle
      @container_handle ||= begin
        container = Containers.backend.get_container(session.container_id)
        container.refresh! if container.respond_to?(:refresh!)
        if container.respond_to?(:info)
          running = container.info.dig("State", "Running") == true
          raise ArgumentError, "Workspace container is not running" unless running
        end
        container
      end
    rescue Docker::Error::NotFoundError
      raise ArgumentError, "Workspace container not found"
    end

    def extend_idle_timeout!
      session.update!(idle_timeout_at: ChatSession::IDLE_TIMEOUT_DURATION.from_now)
    end

    def encode_env(name, value)
      "#{name}=#{Base64.strict_encode64(value.to_s)}"
    end

    def git_status_result(repo_path)
      stdout, stderr, exit_code = git_exec!("git -C #{Shellwords.escape(repo_path)} status --short --branch --untracked-files=all")
      raise ArgumentError, stderr.presence || stdout.presence || "git status failed" unless exit_code.zero?

      stdout
    end

    def git_diff_result(repo_path)
      script = <<~SH
        git -C #{Shellwords.escape(repo_path)} diff --no-color
        git -C #{Shellwords.escape(repo_path)} ls-files --others --exclude-standard |
          while IFS= read -r file; do
            git -C #{Shellwords.escape(repo_path)} diff --no-color --no-index -- /dev/null "$file" || true
          done
      SH
      stdout, stderr, exit_code = git_exec!(script)
      raise ArgumentError, stderr.presence || stdout.presence || "git diff failed" unless exit_code.zero?

      stdout
    end
  end
end
