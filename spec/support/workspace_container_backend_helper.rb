# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module WorkspaceContainerBackendHelper
  class FakeContainer
    attr_reader :root

    def initialize(root)
      @root = root
    end

    def refresh!
      self
    end

    def info
      { "State" => { "Running" => true } }
    end
  end

  class FakeBackend
    attr_reader :exec_calls

    def initialize(container_roots)
      @container_roots = container_roots
      @exec_calls = []
    end

    def get_container(id)
      FakeContainer.new(@container_roots.fetch(id))
    end

    def exec_in_container(container, command, **options)
      @exec_calls << { container:, command:, options: }

      env = Array(options[:Env]).each_with_object({}) do |entry, memo|
        key, value = entry.split("=", 2)
        memo[key] = value
      end

      translated_command = translate_command(command, container.root)
      stdout, stderr, status = Open3.capture3(env, *translated_command)
      [ stdout.lines, stderr.lines, status.exitstatus ]
    end

    private

    def translate_command(command, workspace_root)
      return command unless command.first == "sh" && command.length == 3

      translated_script = command.last.gsub("/workspace", workspace_root)
      [ command.first, command[1], translated_script ]
    end
  end

  def with_fake_workspace_backend(workspace_root:, container_id: "chat-container-test")
    backend = FakeBackend.new(container_id => workspace_root)
    previous_backend = Rails.application.config.x.container_backend
    Rails.application.config.x.container_backend = backend
    yield backend
  ensure
    Rails.application.config.x.container_backend = previous_backend
  end

  def make_workspace_root
    Dir.mktmpdir("chat-workspace")
  end

  def clone_repo_into_workspace(workspace_root:, repo_name:, files:)
    source_root = Dir.mktmpdir("chat-source")
    create_git_repo(source_root, files)

    repo_host_path = File.join(workspace_root, repo_name)
    run_cmd!("git", "clone", source_root, repo_host_path)
    run_cmd!("git", "-C", repo_host_path, "config", "user.name", "Spec Bot")
    run_cmd!("git", "-C", repo_host_path, "config", "user.email", "spec@example.test")

    {
      repo_path: File.join("/workspace", repo_name),
      host_path: repo_host_path,
      source_path: source_root
    }
  end

  def create_git_repo(path, files)
    FileUtils.mkdir_p(path)
    run_cmd!("git", "-C", path, "init", "-b", "main")
    run_cmd!("git", "-C", path, "config", "user.name", "Spec Bot")
    run_cmd!("git", "-C", path, "config", "user.email", "spec@example.test")

    files.each do |relative_path, content|
      absolute_path = File.join(path, relative_path)
      FileUtils.mkdir_p(File.dirname(absolute_path))
      File.binwrite(absolute_path, content)
    end

    run_cmd!("git", "-C", path, "add", ".")
    run_cmd!("git", "-C", path, "commit", "-m", "Initial commit")
  end

  def run_cmd!(*command)
    stdout, stderr, status = Open3.capture3(*command)
    return stdout if status.success?

    raise "Command failed: #{command.join(' ')}\nSTDOUT:\n#{stdout}\nSTDERR:\n#{stderr}"
  end
end

RSpec.configure do |config|
  config.include WorkspaceContainerBackendHelper
end
