# frozen_string_literal: true

namespace :screenshots do
  desc "Capture rendered screenshots of key UI pages for PR review. " \
       "Set SCREENSHOT_OUTPUT_DIR to control output location (default: tmp/screenshots). " \
       "Set CHANGED_FILES (newline-separated) to only screenshot when UI files changed."
  task capture: :environment do
    require "screenshots/capture"

    changed_files = ENV.fetch("CHANGED_FILES", "").split("\n").map(&:strip).reject(&:empty?)

    if changed_files.any?
      ui_detection_options = { repo_path: Dir.pwd }
      config_path = File.join(Dir.pwd, Screenshots::ConfigParser::CONFIG_PATH)

      if File.exist?(config_path)
        ui_detection_options.merge!(
          Screenshots::ConfigParser.ui_detection_overrides(repo_path: Dir.pwd)
        )
      end

      result = Screenshots::DetectUiChanges.call(
        changed_files: changed_files,
        **ui_detection_options
      )
      unless result[:ui_changes?]
        puts "No UI-facing file changes detected. Skipping screenshot capture."
        next
      end
      changed_files = result[:ui_files]
      puts "Detected #{result[:ui_files].size} UI-facing file change(s):"
      result[:ui_files].each { |f| puts "  #{f}" }
    end

    output_dir = ENV.fetch("SCREENSHOT_OUTPUT_DIR", "tmp/screenshots")
    screenshots = Screenshots::Capture.call(output_dir: output_dir, changed_files: changed_files)

    puts "\nCaptured #{screenshots.size} screenshot(s) in #{output_dir}/"
    screenshots.each { |path| puts "  #{path}" }
  end
end
