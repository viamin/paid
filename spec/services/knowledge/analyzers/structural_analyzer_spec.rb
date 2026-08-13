# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Analyzers::StructuralAnalyzer, :no_db do
  describe ".call" do
    subject(:analysis) { described_class.call(artifacts) }

    context "with mixed structural artifacts" do
      let(:artifacts) do
        [
          structure("class", "UserService", language: "ruby", naming_style: "pascal",
                    line_count: 45, parent: "BaseService"),
          structure("class", "OrderProcessor", language: "ruby", naming_style: "pascal",
                    line_count: 120),
          structure("method", "process_order", language: "ruby", naming_style: "snake",
                    line_count: 8, params: "order, options"),
          structure("method", "validate", language: "ruby", naming_style: "snake",
                    line_count: 3, params: ""),
          structure("method", "send_notification", language: "ruby", naming_style: "snake",
                    line_count: 25, params: "user, message, channel"),
          structure("function", "createUser", language: "typescript", naming_style: "camel",
                    line_count: 12, params: "name: string, email: string"),
          structure("interface", "UserRepository", language: "typescript",
                    naming_style: "pascal", line_count: 5),
          structure("struct", "Config", language: "go", naming_style: "pascal",
                    line_count: 10),
          # Non-structure artifact should be ignored
          { artifact_type: "symbol", metadata: { element_type: "class" } }
        ]
      end

      describe "naming_conventions" do
        it "groups naming styles by element type" do
          conventions = analysis[:naming_conventions]

          expect(conventions).to have_key("class")
          expect(conventions).to have_key("method")
          expect(conventions).to have_key("function")
        end

        it "detects dominant naming style for methods" do
          expect(analysis[:naming_conventions]["method"][:dominant]).to eq("snake")
        end

        it "detects dominant naming style for classes" do
          expect(analysis[:naming_conventions]["class"][:dominant]).to eq("pascal")
        end

        it "includes style tallies" do
          method_styles = analysis[:naming_conventions]["method"][:styles]

          expect(method_styles["snake"]).to eq(3)
        end

        it "includes totals" do
          expect(analysis[:naming_conventions]["method"][:total]).to eq(3)
        end
      end

      describe "method_metrics" do
        it "counts all methods and functions" do
          expect(analysis[:method_metrics][:count]).to eq(4)
        end

        it "calculates average method length" do
          expect(analysis[:method_metrics][:avg_length]).to eq(12.0)
        end

        it "finds maximum method length" do
          expect(analysis[:method_metrics][:max_length]).to eq(25)
        end

        it "calculates average parameter count" do
          expect(analysis[:method_metrics][:avg_params]).to eq(1.8)
        end

        it "finds maximum parameter count" do
          expect(analysis[:method_metrics][:max_params]).to eq(3)
        end

        it "counts long methods (over 20 lines)" do
          expect(analysis[:method_metrics][:long_methods]).to eq(1)
        end
      end

      describe "class_metrics" do
        it "counts all classes and structs" do
          expect(analysis[:class_metrics][:count]).to eq(3)
        end

        it "counts classes with inheritance" do
          expect(analysis[:class_metrics][:with_inheritance]).to eq(1)
        end

        it "calculates average class length" do
          expected_avg = ((45 + 120 + 10) / 3.0).round(1)
          expect(analysis[:class_metrics][:avg_length]).to eq(expected_avg)
        end

        it "finds maximum class length" do
          expect(analysis[:class_metrics][:max_length]).to eq(120)
        end

        it "counts large classes (over 100 lines)" do
          expect(analysis[:class_metrics][:large_classes]).to eq(1)
        end
      end

      describe "languages" do
        it "lists all detected languages sorted" do
          expect(analysis[:languages]).to eq(%w[go ruby typescript])
        end
      end
    end

    context "with empty artifacts" do
      let(:artifacts) { [] }

      it "returns empty analysis" do
        expect(analysis[:naming_conventions]).to eq({})
        expect(analysis[:method_metrics]).to eq({})
        expect(analysis[:class_metrics]).to eq({})
        expect(analysis[:languages]).to eq([])
      end
    end

    context "with only non-structure artifacts" do
      let(:artifacts) do
        [
          { artifact_type: "symbol", metadata: { element_type: "class", language: "ruby" } },
          { artifact_type: "dependency", metadata: { element_type: "gem", language: "ruby" } }
        ]
      end

      it "returns empty analysis" do
        expect(analysis[:naming_conventions]).to eq({})
        expect(analysis[:method_metrics]).to eq({})
        expect(analysis[:class_metrics]).to eq({})
        expect(analysis[:languages]).to eq([])
      end
    end

    context "with methods that have no params" do
      let(:artifacts) do
        [
          structure("method", "run", language: "ruby", naming_style: "snake",
                    line_count: 5, params: nil),
          structure("method", "stop", language: "ruby", naming_style: "snake",
                    line_count: 3, params: "")
        ]
      end

      it "counts zero params for parameterless methods" do
        expect(analysis[:method_metrics][:avg_params]).to eq(0.0)
        expect(analysis[:method_metrics][:max_params]).to eq(0)
      end
    end
  end

  # Helper to build a structure artifact hash matching the collector output format
  def structure(element_type, name, language:, naming_style: "snake",
                line_count: 1, parent: nil, params: nil)
    metadata = {
      language: language,
      element_type: element_type,
      name: name,
      line: 1,
      end_line: line_count,
      line_count: line_count,
      naming_style: naming_style
    }
    metadata[:parent] = parent if parent
    metadata[:params] = params if params

    {
      artifact_type: "structure",
      scope_path: "test.rb",
      identifier: "test.rb::#{element_type}::#{name}::1",
      content: "#{element_type} #{name}",
      metadata: metadata,
      chunks: [ { chunk_type: "definition", content: "#{element_type} #{name}",
                   scope_tags: [ language, element_type ], sequence: 0 } ]
    }
  end
end
