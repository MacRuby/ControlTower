# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

require 'CTParser'

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @server = server
      @socket = TCPServer.new(host, port)
      @status = :closed # Start closed and give the server time to start
      @concurrent = concurrent

      if @concurrent
        @request_queue = Dispatch::Queue.concurrent
        $stdout.puts "Caution: Wake turbulance! Heavy landing on parallel runway."
      else
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      end
      @request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      while (@status == :open)
        connection = @socket.accept
        $stderr.puts "Got a connection: #{connection}(fd:#{connection.to_i})" if ENV['CT_DEBUG']

        @request_queue.async(@request_group) do
          parse!(connection, prepare_environment) do |env|
            response = @server.handle_request(env)
            response.each do |chunk|
              connection.write chunk
            end
          end
        end
      end
    end

    def close
      @status = :closed

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        puts "Timed out waiting for connections to close"
        exit 1
      end
      @request_group.wait
      @socket.close
    end


    private

    def prepare_environment
      { 'rack.errors' => $stderr,
        'rack.input' => '',
        'rack.multiprocess' => false, # No multiprocess, yet...possibly never
        'rack.run_once' => false,
        'rack.multithread' => @concurrent ? true : false,
        'rack.version' => VERSION }
    end

    def parse!(connection, env, &block)
      connection_queue = Dispatch::Queue.new('com.apple.ControlTower.connection_queue')
      parser = ::CTParser.new
      data = ""
      parsing_headers = true
      content_length = 0

      Dispatch::Source.new(Dispatch::Source::READ, connection, 0, connection_queue) do |source|
        $stderr.puts "#{source.data} bytes incoming" if ENV['CT_DEBUG']
        begin
          if parsing_headers
            $stderr.puts "Parsing headers..." if ENV['CT_DEBUG']
            data << connection.readpartial(source.data)
            nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
            if parser.finished
              parsing_headers = false
              $stderr.puts "Headers done! Content-Length: #{env['CONTENT_LENGTH']}" if ENV['CT_DEBUG']
              content_length = env['CONTENT_LENGTH'].to_i
            end
          else
            $stderr.puts "Reading body" if ENV['CT_DEBUG']
            env['rack.input'] << connection.readpartial(source.data)
          end
        rescue EOFError
          content_length = env['rack.input'].bytesize
        end

        $stderr.puts "Input Length: #{env['rack.input'].bytesize}, Content-Length: #{content_length}" if ENV['CT_DEBUG']
        unless parsing_headers || env['rack.input'].bytesize < content_length
          # Rack says "Make that a IO!"
          body = Tempfile.new('control-tower-request-body-')
          body << env['rack.input']
          body.rewind
          env['rack.input'] = body
          block.call(env)
          $stderr.puts "All done. Canceling source for #{source.handle}(fd:#{source.handle.to_i})" if ENV['CT_DEBUG']
          source.cancel!
        end
      end
    end
  end
end
