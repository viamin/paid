# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Shared helper for specs that need to create executable scripts in a tmpdir.
# Some CI environments mount /tmp as noexec, so we probe for a usable directory.
module ExecTmpdir
  def exec_tmpdir
    candidates = %w[/tmp /workspace/tmp]

    if (dir = candidates.find { |d| File.directory?(d) && exec_allowed?(d) })
      return dir
    end

    if exec_allowed?(Dir.tmpdir)
      return Dir.tmpdir
    end

    project_tmp = File.join(Dir.pwd, "tmp")
    FileUtils.mkdir_p(project_tmp) unless File.directory?(project_tmp)

    return project_tmp if exec_allowed?(project_tmp)

    checked = (candidates + [ Dir.tmpdir, project_tmp ]).uniq
    raise "ExecTmpdir: no executable tmpdir found; checked: #{checked.join(', ')}"
  end

  def exec_allowed?(dir)
    Dir.mktmpdir(nil, dir) do |d|
      f = File.join(d, "t.sh")
      File.write(f, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, f)
      system(f, out: File::NULL, err: File::NULL)
    end
  rescue StandardError
    false
  end
end
