# frozen_string_literal: true

# Shared helper for specs that need to create executable scripts in a tmpdir.
# Some CI environments mount /tmp as noexec, so we probe for a usable directory.
module ExecTmpdir
  def exec_tmpdir
    %w[/tmp /workspace/tmp].find { |d| File.directory?(d) && exec_allowed?(d) } || Dir.tmpdir
  end

  def exec_allowed?(dir)
    Dir.mktmpdir(nil, dir) do |d|
      f = File.join(d, "t.sh")
      File.write(f, "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, f)
      system(f, out: File::NULL, err: File::NULL)
    end
  end
end
