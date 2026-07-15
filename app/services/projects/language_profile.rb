# frozen_string_literal: true

module Projects
  # Maps a GitHub-reported repository primary language (e.g. "Ruby", "Elixir",
  # "Swift") to a human-friendly project-type label shown as a badge on project
  # tiles. The language key (downcased) is also the value surfaced by
  # +Project#detected_language+, which the prompt-building services consume.
  class LanguageProfile
    LABELS = {
      "ruby" => "Ruby on Rails",
      "elixir" => "Phoenix / Elixir",
      "swift" => "macOS / Swift",
      "objective-c" => "Objective-C",
      "javascript" => "JavaScript",
      "typescript" => "TypeScript",
      "python" => "Python",
      "go" => "Go",
      "rust" => "Rust",
      "java" => "Java",
      "kotlin" => "Kotlin / Android",
      "dart" => "Flutter / Dart",
      "php" => "PHP",
      "c#" => "C# / .NET",
      "f#" => "F#",
      "c++" => "C++",
      "c" => "C",
      "vue" => "Vue",
      "html" => "HTML",
      "css" => "CSS",
      "scss" => "SCSS",
      "shell" => "Shell",
      "scala" => "Scala",
      "clojure" => "Clojure",
      "haskell" => "Haskell",
      "lua" => "Lua",
      "perl" => "Perl",
      "r" => "R",
      "julia" => "Julia",
      "zig" => "Zig"
    }.freeze

    def self.label_for(language)
      return if language.blank?

      normalized = language.to_s.strip.downcase
      LABELS[normalized]
    end
  end
end
