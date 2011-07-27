# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2011, Apple Inc. All rights reserved.

framework 'Foundation'
require 'CTParser'
require 'stringio'

CTParser # Making sure the Objective-C class is pre-loaded

module ControlTower
  class RackSocket
    VERSION = [1,0].freeze
    QUIESCING_MSG = 'Resource limit reached. Redirecting until server quits (will auto-restart).'
    
    def log(msg, prepend_newline=false)
      time = Time.now
      tnum = Thread.current.inspect
      @log_queue.async(@log_group) do
        $stderr.puts "CTLOG::---------" if prepend_newline
        $stderr.puts "CTLOG::#{Process.pid}#{tnum} (#{time.strftime("%Y-%m-%d %H:%M:%S")}) #{msg}"
      end
    end

    def rsize
      `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
    end
    
    def initialize(host, port, server, concurrent)
      @log_queue = Dispatch::Queue.new('log_queue')
      @log_group = Dispatch::Group.new
      
      @under_launchd = (port == 0)
      @mem_high_water_mark = ENV['CT_MEM_BOUNCE_MB'].to_i || -1 if @under_launchd  # in megabytes; negative instructs to not bounce
      log "STARTING with pid=#{Process.pid}" + (@mem_high_water_mark ? " and memory bounce point=#{@mem_high_water_mark} MB" : "")

      if @under_launchd
        # Hash used for to determine if server is idle.  Old entries are cleared by a background timer thread (see below).
        @auth_sessions = {}

        # remove old sessions (not used for 60 seconds) from @auth_sessions, because there is no way for ControlTower to determine that a session is done
        clear_old_auth_sessions_interval_seconds = 60
        Dispatch::Source.timer(clear_old_auth_sessions_interval_seconds, clear_old_auth_sessions_interval_seconds, 5, Dispatch::Queue.concurrent) do
          @now = Time.now
          log "Checking for old auth sessions to remove"
          @auth_sessions.delete_if { |session_id, last_used|
            if @now-last_used > clear_old_auth_sessions_interval_seconds
              log "Removing old auth session: #{session_id}"
              true
            else
              false
            end
          }
          # if idle, check high water mark for memory usage
          if @auth_sessions.empty?
            mem_used = rsize
            if @mem_high_water_mark && mem_used >= @mem_high_water_mark
              @status = :closed
              log "MEMORY THRESHOLD EXCEEDED: Flaggging to not accept new connections; waiting for existing connections (if any) to finish"
              @request_group.wait
              log "MEMORY THRESHOLD EXCEEDED: All existing connections done."
              sleep 5  # give time for more authn'd requests to come in (might happen due to race condition between accepting a connection and adding its session_id to @auth_sessions)
              if @auth_sessions.empty?  # double-check to see if the race condition was exploited
                log "MEMORY THRESHOLD EXCEEDED: Server is confirmed idle; exiting pid=#{Process.pid}."
                exit  # We're idle, so just quit now
              else
                log "Opening back up... a request snuck in."
                @status = :open  # @auth_sessions isn't empty, which means there are current active sessions.  Let them finish (and as a side-effect possibly accepting new connections).
                sleep 1              
              end
            else
              log "empty session list, but not at memory threshold yet (used=#{mem_used}, threshold=#{@mem_high_water_mark})"
            end
          end
        end

        log "setup authnd session clearing timer"
      end

      @app = server.app
      if @under_launchd
        @socket = Socket.for_fd($stdin.fileno)  # launchd sockets
      else
        @socket = TCPServer.new(host, port)
        @socket.listen(50)
      end
      @status = :closed # Start closed and give the server time to start  <------ IS THIS IMPORTANT?  Try it w/ the suicide version.

      log "socket setup"

      if concurrent
        @multithread = true
        @request_queue = Dispatch::Queue.concurrent
        puts "Control Tower is operating in concurrent mode."
      else
        @multithread = false
        @request_queue = Dispatch::Queue.new('com.apple.ControlTower.rack_socket_queue')
        puts "Control Tower is operating in serial mode."
      end
      @request_group = Dispatch::Group.new

      log "initialization complete."
    end

    def open
      log "opening..."

      @status = :open
      while (@status == :open)

        log "Control Tower: waiting for connection..."
        connection, remote_addrinfo_str = @socket.accept
        
        # -------------- PROCESS REQUEST ASYNCHRONOUSLY ----------------

        @request_queue.async(@request_group) do
          remote_port, remote_ip = Socket.unpack_sockaddr_in(remote_addrinfo_str) if remote_addrinfo_str
          log "** new request received at #{Time.new} from #{remote_ip}:#{remote_port}", true

          env = { 'rack.errors' => $stderr,
                  'rack.multiprocess' => false,
                  'rack.multithread' => @multithread,
                  'rack.run_once' => false,
                  'rack.version' => VERSION }
          resp = nil
          x_sendfile_header = 'X-Sendfile'
          x_sendfile = nil
          log "** done setting rack env"
          begin
            log "** about to parse request"
            request_data = parse!(connection, env)
            log "** done parsing request" #: request_data=#{request_data.inspect}"
            # log "** env[]=#{env}"
            if request_data
              request_data['REMOTE_ADDR'] = remote_ip
              log "** about to app.call()"
              status, headers, body = @app.call(request_data)
              log "** app.call() is done"#; handling response, body=#{body.inspect}"

              # If there's an X-Sendfile header, we'll use sendfile(2)
              if headers.has_key?(x_sendfile_header)
                x_sendfile = headers[x_sendfile_header]
                x_sendfile = ::File.open(x_sendfile, 'r') unless x_sendfile.kind_of? IO
                x_sendfile_size = x_sendfile.stat.size
                headers.delete(x_sendfile_header)
                headers['Content-Length'] = x_sendfile_size
              end

              @auth_sessions[env['rack.session'].session_id] = Time.now if @under_launchd
              log "Added/updated session_id (#{env['rack.session'].session_id}) to @auth_sessions" if @under_launchd

              # Unless somebody's already set it for us (or we don't need it), set the Content-Length
              unless (status == -1 ||
                      (status >= 100 and status <= 199) ||
                      status == 204 ||
                      status == 304 ||
                      headers.has_key?('Content-Length'))
                headers['Content-Length'] = if body.respond_to?(:each)
                                              size = 0
                                              body.each { |x| size += x.bytesize }
                                              size
                                            else
                                              body.bytesize
                                            end
              end

              # TODO -- We don't handle keep-alive connections yet
              headers['Connection'] = 'close'

              resp = "HTTP/1.1 #{status}\r\n"
              headers.each do |header, value|
                resp << "#{header}: #{value}\r\n"
              end
              resp << "\r\n"

              # Start writing the response
              connection.write resp

              # Write the body
              if x_sendfile
                connection.sendfile(x_sendfile, 0, x_sendfile_size)
              elsif body.respond_to?(:each)
                body.each do |chunk|
                  connection.write chunk
                end
              else
                connection.write body
              end

            else
              log "Error: No request data received!"
            end
          rescue EOFError, Errno::ECONNRESET, Errno::EPIPE, Errno::EINVAL
            log "Error: Connection terminated!"
          rescue Object => e
            if resp.nil? && !connection.closed?
              connection.write "HTTP/1.1 500\r\n\r\n"
            end
            log "Error: Problem transmitting data -- #{e.inspect}"
            $stderr.puts e.backtrace.join("\n")
          ensure
            # We should clean up after our tempfile, if we used one.
            input = env['rack.input']
            input.unlink if input.class == Tempfile
            connection.close rescue nil
          end
        end
      end # while :open
    end

    def close
      puts "Received shutdown signal.  Waiting for current requests to complete..."
      @status = :close
      
      # 60 seconds to empty the request queue
      Dispatch::Source.timer(60, 0, 1, Dispatch::Queue.concurrent) do
        puts "Timed out waiting for connections to close. Stopping server with pid=#{Process.pid}."
        exit
      end
      
      @request_group.wait
      
      puts "All requests completed. Stopping server with pid=#{Process.pid}."      
      exit
    end

    private

    def parse!(connection, env)
      parser = Thread.current[:http_parser] ||= CTParser.new
      parser.reset
      data = NSMutableData.alloc.init
      data.increaseLengthBy(1) # add sentinel
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
          data.setLength(data.length - 1) # Remove sentinel
          data.appendData(incoming_bytes)
          data.increaseLengthBy(1) # Add sentinel
          nread = parser.parseData(data, forEnvironment: env, startingAt: nread)
          if parser.finished == 1
            parsing_headers = false # We're done, now on to receiving the body
            content_length = env['CONTENT_LENGTH'].to_i
            content_uploaded = env['rack.input'].length
          end
        else # Done parsing headers, now just collect request body:
          content_uploaded += incoming_bytes.length
          env['rack.input'].appendData(incoming_bytes)
        end
      end
      
      if content_length > 1024 * 1024
        body_file = Tempfile.new('control-tower-request-body-')
        NSFileHandle.alloc.initWithFileDescriptor(body_file.fileno).writeData(env['rack.input'])
        body_file.rewind
        env['rack.input'] = body_file
      else
        env['rack.input'] = StringIO.new(env['rack.input'], IO::RDONLY)
      end
      # Returning what we've got...
      return env
    end
  end
end
