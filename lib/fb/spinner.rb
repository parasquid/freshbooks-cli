# frozen_string_literal: true

module FB
  module Spinner
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    def self.spin(message)
      done = false
      result = nil

      thread = Thread.new do
        i = 0
        while !done
          print "\r#{FRAMES[i % FRAMES.length]} #{message}"
          $stdout.flush
          i += 1
          sleep 0.08
        end
      end

      begin
        result = yield
      ensure
        done = true
        thread.join
        print "\r✓ #{message}\n"
      end

      result
    end
  end
end
