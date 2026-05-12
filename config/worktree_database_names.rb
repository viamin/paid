# frozen_string_literal: true

require "digest"
require "open3"

module Paid
  module WorktreeDatabaseNames
    module_function

    def development_primary_name(app_root: default_app_root)
      explicit_name("PAID_DEVELOPMENT_DATABASE") || database_name("paid_development", app_root:)
    end

    def development_cable_name(app_root: default_app_root)
      explicit_name("PAID_DEVELOPMENT_CABLE_DATABASE") || database_name("paid_development_cable", app_root:)
    end

    def test_name(app_root: default_app_root)
      explicit_name("PAID_TEST_DATABASE") || database_name("paid_test", app_root:)
    end

    def suffix(app_root: default_app_root)
      explicit = explicit_name("PAID_WORKTREE_DB_SUFFIX")
      return sanitize(explicit) if explicit

      return nil unless linked_worktree_checkout?(app_root:)

      context = git_context(app_root:)
      token = sanitize(context[:branch])
      token = sanitize(File.basename(app_root)) if token.empty? || token == "head"
      token = "worktree" if token.empty?

      digest = Digest::SHA256.hexdigest(context[:identity])[0, 8]
      "#{token}_#{digest}"
    end

    def database_name(base_name, app_root: default_app_root)
      derived_suffix = suffix(app_root:)
      return base_name if blank?(derived_suffix)

      max_suffix_length = 63 - base_name.length - 1
      truncated_suffix = derived_suffix[0, max_suffix_length]

      "#{base_name}_#{truncated_suffix}"
    end

    def default_app_root
      File.expand_path("..", __dir__)
    end

    def explicit_name(name)
      value = ENV[name]
      return if blank?(value)

      value
    end

    def blank?(value)
      value.nil? || value.strip.empty?
    end

    def git_context(app_root:)
      {
        branch: git_output(app_root, "rev-parse", "--abbrev-ref", "HEAD"),
        git_dir: git_output(app_root, "rev-parse", "--absolute-git-dir"),
        identity: git_output(app_root, "rev-parse", "--absolute-git-dir") || File.realpath(app_root)
      }
    end

    def git_output(app_root, *args)
      stdout, status = Open3.capture2("git", *args, chdir: app_root)
      return unless status.success?

      value = stdout.strip
      value unless value.empty?
    rescue Errno::ENOENT
      nil
    end

    def linked_worktree_checkout?(app_root:)
      File.file?(File.join(app_root, ".git"))
    end

    def sanitize(value)
      value.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
    end
  end
end
