# frozen_string_literal: true

require "rspec/given"
require "webmock/rspec"
require "tmpdir"
require "fb"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.around(:each) do |example|
    Dir.mktmpdir("fb_test_") do |tmpdir|
      FB::Auth.data_dir = tmpdir
      example.run
    end
    FB::Auth.instance_variable_set(:@data_dir, nil)
  end

  config.before(:each) do
    allow(FB::Spinner).to receive(:spin) do |_msg, &block|
      block.call
    end
  end
end
