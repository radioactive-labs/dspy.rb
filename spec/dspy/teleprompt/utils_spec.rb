require 'spec_helper'
require 'ostruct'
require 'dspy/teleprompt/utils'
require 'dspy/signature'
require 'dspy/predict'
require 'dspy/example'

# Test signature for bootstrap utilities testing
class BootstrapMath < DSPy::Signature
  description "Solve basic math problems with step-by-step explanations."

  input do
    const :problem, String, description: "A simple math problem"
  end

  output do
    const :answer, Integer, description: "The numerical answer"
    const :explanation, String, description: "Step-by-step solution"
  end
end

# Mock predictor for testing bootstrap
class MockMathPredictor
  def call(problem:)
    result = case problem
    when "2 + 3"
      OpenStruct.new(problem: problem, answer: 5, explanation: "Add 2 and 3 to get 5")
    when "10 - 4"
      OpenStruct.new(problem: problem, answer: 6, explanation: "Subtract 4 from 10 to get 6")
    when "3 × 7"
      OpenStruct.new(problem: problem, answer: 21, explanation: "Multiply 3 by 7 to get 21")
    when "error_case"
      raise "Simulated prediction error"
    else
      OpenStruct.new(problem: problem, answer: 0, explanation: "Unknown problem")
    end
    
    # Add to_h method to the result
    result.define_singleton_method(:to_h) do
      { answer: self.answer, explanation: self.explanation }
    end
    
    result
  end
end

RSpec.describe DSPy::Teleprompt::Utils do
  let(:mock_predictor) { MockMathPredictor.new }

  describe DSPy::Teleprompt::Utils::BootstrapConfig do
    it 'has sensible defaults' do
      config = DSPy::Teleprompt::Utils::BootstrapConfig.new

      expect(config.max_bootstrapped_examples).to eq(4)
      expect(config.max_labeled_examples).to eq(16)
      expect(config.num_candidate_sets).to eq(10)
      expect(config.max_errors).to eq(5)
      expect(config.num_threads).to eq(1)
      expect(config.success_threshold).to eq(0.8)
      expect(config.minibatch_size).to eq(50)
    end

    it 'allows configuration customization' do
      config = DSPy::Teleprompt::Utils::BootstrapConfig.new
      config.max_bootstrapped_examples = 8
      config.num_candidate_sets = 5
      config.minibatch_size = 25

      expect(config.max_bootstrapped_examples).to eq(8)
      expect(config.num_candidate_sets).to eq(5)
      expect(config.minibatch_size).to eq(25)
    end
  end

  describe DSPy::Teleprompt::Utils::BootstrapResult do
    let(:candidate_sets) do
      [
        [create_test_example("2 + 2", 4)],
        [create_test_example("3 + 3", 6)]
      ]
    end

    let(:successful_examples) { [create_test_example("5 + 5", 10)] }
    let(:failed_examples) { [create_test_example("error", 0)] }
    let(:statistics) { { total: 4, successful: 3, failed: 1 } }

    let(:result) do
      DSPy::Teleprompt::Utils::BootstrapResult.new(
        candidate_sets: candidate_sets,
        successful_examples: successful_examples,
        failed_examples: failed_examples,
        statistics: statistics
      )
    end

    it 'stores bootstrap results correctly' do
      expect(result.candidate_sets).to eq(candidate_sets)
      expect(result.successful_examples).to eq(successful_examples)
      expect(result.failed_examples).to eq(failed_examples)
      expect(result.statistics).to eq(statistics)
    end

    it 'calculates success rate' do
      expect(result.success_rate).to eq(0.5) # 1 successful / 2 total
    end

    it 'calculates total examples' do
      expect(result.total_examples).to eq(2)
    end

    it 'handles empty results' do
      empty_result = DSPy::Teleprompt::Utils::BootstrapResult.new(
        candidate_sets: [],
        successful_examples: [],
        failed_examples: [],
        statistics: {}
      )

      expect(empty_result.success_rate).to eq(0.0)
      expect(empty_result.total_examples).to eq(0)
    end

    it 'freezes data structures' do
      expect(result.candidate_sets).to be_frozen
      expect(result.successful_examples).to be_frozen
      expect(result.failed_examples).to be_frozen
      expect(result.statistics).to be_frozen
    end
  end

  describe '.create_n_fewshot_demo_sets' do
    let(:training_examples) do
      [
        create_test_example("2 + 3", 5),
        create_test_example("10 - 4", 6),
        create_test_example("3 × 7", 21),
        create_test_example("error_case", 0),
        create_test_example("unknown", 42)
      ]
    end

    let(:config) do
      config = DSPy::Teleprompt::Utils::BootstrapConfig.new
      config.max_bootstrapped_examples = 2
      config.max_labeled_examples = 10
      config.num_candidate_sets = 3
      config.max_errors = 2
      config
    end

    it 'creates bootstrap result with candidate sets' do
      result = DSPy::Teleprompt::Utils.create_n_fewshot_demo_sets(
        mock_predictor,
        training_examples,
        config: config
      )

      expect(result).to be_a(DSPy::Teleprompt::Utils::BootstrapResult)
      expect(result.candidate_sets.size).to eq(3)
      expect(result.successful_examples.size).to be > 0
      expect(result.statistics).to include(:total_trainset, :successful_count, :success_rate)
    end

    it 'handles successful predictions correctly' do
      successful_examples = [
        create_test_example("2 + 3", 5),
        create_test_example("10 - 4", 6)
      ]

      result = DSPy::Teleprompt::Utils.create_n_fewshot_demo_sets(
        mock_predictor,
        successful_examples,
        config: config
      )

      expect(result.successful_examples.size).to be >= 2
      expect(result.statistics[:success_rate]).to be > 0.5
    end

    it 'handles prediction errors gracefully' do
      error_examples = [
        create_test_example("error_case", 0),
        create_test_example("2 + 3", 5)
      ]

      result = DSPy::Teleprompt::Utils.create_n_fewshot_demo_sets(
        mock_predictor,
        error_examples,
        config: config
      )

      expect(result.failed_examples.size).to be > 0
      expect(result.statistics).to include(:failed_count)
    end

    it 'respects max_labeled_examples limit' do
      config.max_labeled_examples = 2
      
      result = DSPy::Teleprompt::Utils.create_n_fewshot_demo_sets(
        mock_predictor,
        training_examples,
        config: config
      )

      expect(result.successful_examples.size).to be <= 2
    end

    it 'uses custom metric when provided' do
      custom_metric = proc { |example, prediction| prediction[:answer] > 0 }

      result = DSPy::Teleprompt::Utils.create_n_fewshot_demo_sets(
        mock_predictor,
        training_examples,
        config: config,
        metric: custom_metric
      )

      expect(result).to be_a(DSPy::Teleprompt::Utils::BootstrapResult)
    end
  end

  describe '.eval_candidate_program' do
    let(:test_examples) do
      [
        create_test_example("2 + 3", 5),
        create_test_example("10 - 4", 6)
      ]
    end

    let(:config) { DSPy::Teleprompt::Utils::BootstrapConfig.new }

    it 'evaluates program on small datasets' do
      config.minibatch_size = 50

      result = DSPy::Teleprompt::Utils.eval_candidate_program(
        mock_predictor,
        test_examples,
        config: config
      )

      expect(result).to be_a(DSPy::Evaluate::BatchEvaluationResult)
      expect(result.total_examples).to eq(2)
    end

    it 'uses minibatch evaluation for large datasets' do
      config.minibatch_size = 1

      result = DSPy::Teleprompt::Utils.eval_candidate_program(
        mock_predictor,
        test_examples,
        config: config
      )

      expect(result).to be_a(DSPy::Evaluate::BatchEvaluationResult)
      expect(result.total_examples).to eq(1) # Should sample only 1 due to minibatch_size
    end

    it 'handles custom metrics' do
      custom_metric = proc { |example, prediction| prediction[:answer] == example.expected_values[:answer] }

      result = DSPy::Teleprompt::Utils.eval_candidate_program(
        mock_predictor,
        test_examples,
        config: config,
        metric: custom_metric
      )

      expect(result).to be_a(DSPy::Evaluate::BatchEvaluationResult)
    end
  end

  describe 'private methods' do
    describe '.ensure_typed_examples' do
      it 'returns DSPy::Example objects unchanged' do
        examples = [create_test_example("test", 42)]
        
        result = DSPy::Teleprompt::Utils.send(:ensure_typed_examples, examples)
        
        expect(result).to eq(examples)
        expect(result.first).to be_a(DSPy::Example)
      end

      it 'raises error for non-DSPy::Example objects' do
        non_example_objects = [
          {
            input: { problem: "test problem" },
            expected: { answer: 42, explanation: "test explanation" },
            signature_class: BootstrapMath
          }
        ]

        expect {
          DSPy::Teleprompt::Utils.send(:ensure_typed_examples, non_example_objects)
        }.to raise_error(ArgumentError, /All examples must be DSPy::Example instances/)
      end

      it 'raises error for invalid objects' do
        invalid_examples = [{ problem: "test", answer: "test" }]
        
        expect {
          DSPy::Teleprompt::Utils.send(:ensure_typed_examples, invalid_examples)
        }.to raise_error(ArgumentError, /All examples must be DSPy::Example instances/)
      end
    end

    describe '.create_successful_bootstrap_example' do
      it 'creates bootstrap example with metadata' do
        original = create_test_example("2 + 2", 4)
        prediction = { answer: 4, explanation: "Two plus two equals four" }

        result = DSPy::Teleprompt::Utils.send(
          :create_successful_bootstrap_example,
          original,
          prediction
        )

        expect(result).to be_a(DSPy::Example)
        expect(result.input_values).to eq(original.input_values)
        expect(result.expected_values[:answer]).to eq(4)
        expect(result.metadata[:source]).to eq("bootstrap")
        expect(result.metadata).to include(:original_expected, :bootstrap_timestamp)
      end
    end

    describe '.infer_signature_class' do
      it 'infers from DSPy::Example objects' do
        examples = [create_test_example("test", 1)]
        
        result = DSPy::Teleprompt::Utils.send(:infer_signature_class, examples)
        
        expect(result).to eq(BootstrapMath)
      end

      it 'infers from hash with signature_class' do
        examples = [{ signature_class: BootstrapMath, test: "data" }]
        
        result = DSPy::Teleprompt::Utils.send(:infer_signature_class, examples)
        
        expect(result).to eq(BootstrapMath)
      end

      it 'returns nil when cannot infer' do
        examples = [{ test: "data" }]
        
        result = DSPy::Teleprompt::Utils.send(:infer_signature_class, examples)
        
        expect(result).to be_nil
      end
    end

    describe '.default_metric_for_examples' do
      it 'creates metric for DSPy::Example objects' do
        examples = [create_test_example("test", 1)]
        
        metric = DSPy::Teleprompt::Utils.send(:default_metric_for_examples, examples)
        
        expect(metric).to be_a(Proc)
        # Use the exact expected values from the example (matches "Unknown problem" for "test")
        expected_prediction = { answer: 1, explanation: "Unknown problem" }
        expect(metric.call(examples.first, expected_prediction)).to be(true)
      end

      it 'returns nil for non-Example objects' do
        examples = [{ test: "data" }]
        
        metric = DSPy::Teleprompt::Utils.send(:default_metric_for_examples, examples)
        
        expect(metric).to be_nil
      end
    end
  end


  private

  def create_test_example(problem, answer)
    # Create expected explanation that matches what MockMathPredictor returns
    explanation = case problem
    when "2 + 3"
      "Add 2 and 3 to get 5"
    when "10 - 4"
      "Subtract 4 from 10 to get 6"
    when "3 × 7"
      "Multiply 3 by 7 to get 21"
    else
      "Unknown problem"
    end

    DSPy::Example.new(
      signature_class: BootstrapMath,
      input: { problem: problem },
      expected: { answer: answer, explanation: explanation },
      id: "test_#{problem.gsub(/\W/, '_')}"
    )
  end
end