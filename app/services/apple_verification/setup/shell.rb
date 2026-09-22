# frozen_string_literal: true

require "digest"

module AppleVerification
  module Setup
    # Injectable shell-out abstraction so preflight can run under tests
    # without the actual macOS toolchain. The default implementation shells
    # out via `Open3.capture3` so the preflight can be exercised on any
    # operator workstation.
    # @spec APPLE-SETUP-001
    class Shell
      CommandResult = Data.define(:stdout, :stderr, :status) do
        def success?
          status&.success?
        end

        def stdout_lines
          stdout.to_s.split("\n")
        end
      end

      def initialize(capture: method(:capture3))
        @capture = capture
      end

      def run(*argv)
        stdout, stderr, status = @capture.call(*argv)
        CommandResult.new(stdout:, stderr:, status:)
      rescue Errno::ENOENT, Errno::EACCES => error
        CommandResult.new(stdout: "", stderr: "#{error.class.name}: #{error.message}", status: nil)
      end

      def file_read(path)
        File.read(path)
      rescue Errno::ENOENT, Errno::EACCES => error
        "#{error.class.name}: #{error.message}"
      end

      def file_present?(path)
        File.exist?(path)
      rescue StandardError
        false
      end

      def command_path(name)
        stdout, _stderr, status = @capture.call("which", name)
        stdout.to_s.strip if status&.success?
      end

      # Tart stores cloned VMs under <tart_home>/vms/<name>. The home
      # directory honours the TART_HOME override; everything else falls
      # back to $HOME/.tart (Tart's documented default).
      def tart_home_dir
        override = ENV["TART_HOME"].to_s.strip
        return File.expand_path(override) if override.present?

        File.expand_path(".tart", ENV["HOME"].to_s)
      end

      # Names of local Tart VMs (directories under <tart_home>/vms that
      # Tart considers initialized). Hidden names and names with path
      # separators are skipped so the directory walk can never escape the
      # vms root.
      def local_tart_vm_names
        vms_root = File.join(tart_home_dir, "vms")
        return [] unless file_present?(vms_root) && File.directory?(vms_root)

        Dir.children(vms_root).sort.filter_map do |name|
          next nil unless safe_tart_vm_name?(name)

          name if File.directory?(File.join(vms_root, name))
        end
      end

      # Stable SHA-256 digest over every file under the named local Tart
      # VM directory. The hash covers relative path → file-content hash
      # pairs in sorted order so any mutation (content, filename, or
      # structural addition) produces a different digest. Hidden files,
      # hidden directories, and the files inside them are skipped — Tart
      # uses dotfiles for runtime bookkeeping (e.g. `.explicitly-pulled`)
      # that is not part of the image content. Returns nil when the
      # directory is missing or not a directory.
      def vm_dir_digest(name)
        path = File.join(tart_home_dir, "vms", name.to_s)
        return nil unless safe_tart_vm_name?(name.to_s)
        return nil unless file_present?(path) && File.directory?(path)

        entries = Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort
        manifest = entries.filter_map do |entry|
          next nil if File.directory?(entry)
          next nil if hidden_path?(entry, path)

          relative = entry.sub("#{path}/", "")
          "#{relative}\t#{Digest::SHA256.file(entry).hexdigest}"
        end

        # Hash an empty manifest deterministically so an empty (or fully
        # hidden) VM directory still produces a stable digest the caller
        # can compare against.
        Digest::SHA256.hexdigest(manifest.join("\n"))
      end

      private

      def capture3(*argv)
        require "open3"
        Open3.capture3(*argv)
      end

      def safe_tart_vm_name?(name)
        return false if name.nil?

        stripped = name.to_s
        return false if stripped.empty?
        return false if stripped.start_with?(".")
        return false if stripped.include?("/") || stripped.include?("\0")

        stripped.length < 256
      end

      def hidden_path?(entry, root)
        entry.sub(root, "").split("/").any? { |part| part.start_with?(".") }
      end
    end
  end
end
