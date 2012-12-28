# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

require "control_tower"

module Rack
  module Handler
    class ControlTower
      def self.run(app, options={})
        options[:port] = options.delete(:Port) if options[:Port]
        options[:host] = options.delete(:Host) if options[:Host]
      
        app = Rack::Chunked.new(Rack::ContentLength.new(app))
        server = ::ControlTower::Server.new(app, options)
        yield server if block_given?
        server.start
      end
    end
    
    register 'control_tower', ControlTower
  end
end
