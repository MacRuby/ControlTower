# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

framework 'Foundation'
require 'CTParser'
require 'stringio'

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze

    def initialize(host, port, server, concurrent)
      @server = server
      @socket = TCPServer.new(host, port)
      @status = :closed # Start closed and give the server time to start

      if concurrent
        @multithread = true
        @request_queue = Dispatch::Queue.concurrent
        puts "Caution! Wake turbulance from heavy aircraft landing on parallel runway.\n(Parallel Request Action ENABLED!)"
      else
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
      end
      @request_group = Dispatch::Group.new
    end

    def open
      @status = :open
      while (@status == :open)
        connection = @socket.accept

        @request_queue.async(@request_group) do
          env = prepare_environment
          begin
            request_data = parse!(connection, env)
            if request_data
              request_data['REMOTE_ADDR'] = connection.addr[3]
              response_data = @server.handle_request(request_data)
              response_data.each do |chunk|
                connection.write chunk
              end
            else
              $stderr.puts "Error: No request data received!"
            end
          rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL
            $stderr.puts "Error: Connection terminated!"
          rescue Object => e
            $stderr.puts "Error: Problem transmitting data -- #{e.inspect}"
          ensure
            # We should clean up after our tempfile, if we used one.
            input = env['rack.input']
            unlink input if input.class == Tempfile
            connection.close rescue nil
          end
        end
      end
    end

    def close
      @status = :close

      # You get 30 seconds to empty the request queue and get outa here!
      Dispatch::Source.timer(30, 0, 1, Dispatch::Queue.concurrent) do
        $stderr.puts "Timed out waiting for connections to close"
        exit 1
      end
      @request_group.wait
      @socket.close
    end


    private

    def prepare_environment
      { 'rack.errors' => $stderr,
        'rack.input' => NSMutableArray.alloc.init, # For now, collect the body as an array of NSData's
        'rack.multiprocess' => false,
        'rack.multithread' => @multithread,
        'rack.run_once' => false,
        'rack.version' => VERSION }
    end

    def parse!(connection, env)
      parser = ::CTParser.new
      data = NSMutableData.alloc.init
      parsing_headers = true # Parse headers first
      nread = 0
      content_length = 0
      content_uploaded = 0
      connection_handle = NSFileHandle.alloc.initWithFileDescriptor(connection.fileno)

      while (parsing_headers || content_uploaded < content_length) do
        # Read the availableData on the socket and give up if there's nothing
        incoming_bytes = connection_handle.availableData
        return nil if incoming_bytes.length == 0

        # Until the headers are done being parsed, we'll parse them
        if parsing_headers
          data.appendData(incoming_bytes)
          nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
          if parser.finished == 1
            parsing_headers = false # We're done, now on to receiving the body
            content_uploaded = env['rack.input'].first.length
            content_length = env['CONTENT_LENGTH'].to_i
          end
        else # Done parsing headers, now just collect request body:
          content_uploaded += incoming_bytes.length
          env['rack.input'] << incoming_bytes
        end
      end

      if content_length > 1024 * 1024
        body = Tempfile.new('control-tower-request-body-')
        body_handle = NSFileHandle.alloc.initWithFileDescriptor(body.fileno)
        env['rack.input'].each { |upload_data| body_handle.writeData(upload_data) }
        body.rewind
        env['rack.input'] = body
        $stdout.puts "Finished creating the rack.input file at #{Time.now.to_f}"
      else
        body = StringIO.new
        env['rack.input'].each { |upload_data| body << upload_data.to_str }
        env['rack.input'] = body
      end
      # Returning what we've got...
      return env
    end
  end
end
