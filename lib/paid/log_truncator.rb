# frozen_string_literal: true

module Paid
  # Truncates log files that exceed a maximum size, keeping only the tail.
  # Used by bin/setup and bin/dev-update to prevent unbounded log growth.
  module LogTruncator
    module_function

    def truncate_logs(directory, max_bytes: 524_288, keep_bytes: 102_400)
      Dir[File.join(directory, "*.log")].each do |log_file|
        next unless File.size(log_file) > max_bytes

        tail = File.binread(log_file, keep_bytes, File.size(log_file) - keep_bytes)
        File.binwrite(log_file, tail)
      end
    end
  end
end
