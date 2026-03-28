# frozen_string_literal: true

module Paid
  # Truncates log files that exceed a maximum size, keeping only the tail.
  # Used by bin/setup and bin/dev-update to prevent unbounded log growth.
  module LogTruncator
    module_function

    def truncate_logs(directory, max_bytes: 524_288, keep_bytes: 102_400)
      Dir[File.join(directory, "*.log")].each do |log_file|
        file_size = File.size(log_file)
        next unless file_size > max_bytes

        bytes_to_keep = [ keep_bytes, file_size ].min
        offset = file_size - bytes_to_keep
        next if offset <= 0

        tail = File.binread(log_file, bytes_to_keep, offset)
        File.binwrite(log_file, tail)
      end
    end
  end
end
