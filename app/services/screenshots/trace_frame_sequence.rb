# frozen_string_literal: true

require "json"

module Screenshots
  module TraceFrameSequence
    class Error < StandardError; end

    module_function

    def ordered_pngs(extract_dir)
      trace_files = Dir.glob(File.join(extract_dir, "**", "*.trace")).sort
      raise Error, "trace metadata is missing .trace events" if trace_files.empty?

      frame_refs = trace_files.flat_map { |trace_file| frame_refs_from_trace_file(trace_file) }
      raise Error, "trace metadata contains no screencast frames" if frame_refs.empty?

      frame_refs.map.with_index do |frame_ref, index|
        path = File.join(extract_dir, "resources", frame_ref.fetch("sha1"))
        raise Error, "missing screencast frame resource #{frame_ref.fetch("sha1")} at index #{index}" unless File.exist?(path)

        path
      end
    end

    def frame_refs_from_trace_file(trace_file)
      File.foreach(trace_file).flat_map.with_index do |line, line_index|
        next [] if line.blank?

        event = JSON.parse(line)
        extract_screencast_frames(event)
      rescue JSON::ParserError => e
        raise Error, "invalid trace metadata in #{trace_file}:#{line_index + 1} (#{e.message})"
      end
    end

    def extract_screencast_frames(node)
      case node
      when Hash
        frames = node.fetch("page.screencastFrames", [])
        return normalize_frames(frames) if frames.present?

        node.values.flat_map { |value| extract_screencast_frames(value) }
      when Array
        node.flat_map { |value| extract_screencast_frames(value) }
      else
        []
      end
    end

    def normalize_frames(frames)
      frames
        .sort_by { |frame| frame.fetch("timestamp", 0) }
        .filter_map do |frame|
          sha1 = frame["sha1"]
          next if sha1.blank?

          { "sha1" => sha1 }
        end
    end
  end
end
