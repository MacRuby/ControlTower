# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

framework 'Foundation'
require 'CTParser'

module ControlTower
  class RackSocket
    READ_SIZE = 16 * 1024
    RACK_VERSION = 'rack.version'.freeze
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @server = server
      @socket = TCPServer.new(host, port)
      @status = :closed # Start closed and give the server time to start
      prepare_environment

      #if concurrent
      #  @env['rack.multithread'] = true
      #  @request_queue = Dispatch::Queue.concurrent
      #else
      #  @env['rack.multithread'] = false
      #  @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      #end
      #@request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      while (@status == :open)
        connection = @socket.accept

        # TODO -- Concurrency doesn't quite work yet...
        #@request_group.dispatch(@request_queue) do
          req_data = parse!(connection, prepare_environment)
          req_data['REMOTE_ADDR'] = connection.addr[3]
          data = @server.handle_request(req_data)
          data.each do |chunk|
            connection.write chunk
          end
          connection.close
        #end
      end
    end

    def close
      @status = :close

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        puts "Timed out waiting for connections to close"
        exit 1
      end
      #@request_group.wait
      @socket.close
    end


    private

    def prepare_environment
      { 'rack.errors' => $stderr,
        'rack.input' => ''.force_encoding('ASCII-8BIT'),
        'rack.multiprocess' => false, # No multiprocess, yet...probably never
        'rack.run_once' => false,
        RACK_VERSION => VERSION }
    end

    def parse!(connection, env)
      parser = ::CTParser.new
      data = ""
      headers_done = false
      content_length = 0
      connection_handle = NSFileHandle.alloc.initWithFileDescriptor(connection.fileno)

      while (!headers_done || env['rack.input'].bytesize < content_length) do
        select([connection], nil, nil, 1)
        if headers_done
          begin
            env['rack.input'].appendString(NSString.alloc.initWithData(connection_handle.availableData,
                                                                       encoding: NSUTF8StringEncoding))
          rescue EOFError
            break
          end
        else
          data.appendString(NSString.alloc.initWithData(connection_handle.availableData, encoding: NSUTF8StringEncoding))
          nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
          if parser.finished
            headers_done = true
            content_length = env['CONTENT_LENGTH'].to_i
          end
        end
      end

      # Rack says "Make that a StringIO!"
      body = Tempfile.new('control-tower-request-body-')
      body << env['rack.input']
      body.rewind
      env['rack.input'] = body
      # Returning what we've got...
      return env
    end
  end
end
