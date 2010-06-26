# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

module ControlTower
  class Server
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

    def handle_request(env)
      wrap_output(*@app.call(env))
    end

    private

    def parse_options(opt)
      @port = (opt[:port] || 8080).to_i
      @host = opt[:host] || `hostname`.chomp
      @concurrent = opt[:concurrent]
    end

    def wrap_output(status, headers, body)
      # Unless somebody's already set it for us (or we don't need it), set the Content-Length
      unless (status == -1 ||
              (status >= 100 and status <= 199) ||
              status == 204 ||
              status == 304 ||
              headers.has_key?("Content-Length"))
        headers["Content-Length"] = if body.respond_to?(:each)
          size = 0
          body.each { |x| size += x.bytesize }
          size
        else
          body.bytesize
        end
      end

      # TODO -- We don't handle keep-alive connections yet
      headers["Connection"] = 'close'

      resp = "HTTP/1.1 #{status}\r\n"
      headers.each do |header, value|
        resp << "#{header}: #{value}\r\n"
      end
      resp << "\r\n"

      # Assemble our response...
      chunks = [resp]
      if body.respond_to?(:each)
        body.each do |chunk|
          chunks << chunk
        end
      else
        chunks << body
      end
      chunks
    end
  end
end
