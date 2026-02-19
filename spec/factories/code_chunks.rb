# frozen_string_literal: true

FactoryBot.define do
  factory :code_chunk do
    project

    sequence(:file_path) { |n| "app/models/model_#{n}.rb" }
    chunk_type { "file" }
    identifier { nil }
    content { "class Example\n  def hello\n    \"world\"\n  end\nend" }
    content_hash { Digest::SHA256.hexdigest(content) }
    language { "ruby" }
    start_line { nil }
    end_line { nil }
    embedding { nil }

    trait :with_identifier do
      chunk_type { "function" }
      sequence(:identifier) { |n| "method_#{n}" }
    end

    trait :with_line_range do
      start_line { 1 }
      end_line { 10 }
    end

    trait :javascript do
      language { "javascript" }
      sequence(:file_path) { |n| "src/components/component_#{n}.js" }
      content { "function hello() {\n  return 'world';\n}" }
      content_hash { Digest::SHA256.hexdigest(content) }
    end

    trait :python do
      language { "python" }
      sequence(:file_path) { |n| "src/module_#{n}.py" }
      content { "def hello():\n    return 'world'" }
      content_hash { Digest::SHA256.hexdigest(content) }
    end
  end
end
