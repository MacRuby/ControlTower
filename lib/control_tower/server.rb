# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

module ControlTower
  class Server
    attr_reader :app

    def initialize(app, options)
      @app = app
      parse_options(options)
      @socket = RackSocket.new(@host, @port, self, @concurrent)
    end

    def start
      trap 'INT' do
        @socket.close
        exit
      end

      # Ok, let the server do it's thing
      @socket.open
    end

    private

    def parse_options(opt)
      @port = (opt[:port] || 8080).to_i
      @host = opt[:host] || `hostname`.chomp
      @concurrent = opt[:concurrent]
    end
  end
end
