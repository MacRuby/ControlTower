# This sample will read a file passed as part of a multipart-post body in a
# section named 'file'

require 'rack'

class Uploader
  def call(env)
    params = Rack::Request.new(env).params
    response = params.map do |k,v|
      if k == 'file' && v[:tempfile]
        "#{k} => File Contents: #{v[:tempfile].read}"
      else
        "#{k} => #{v.inspect}"
      end
    end.join("\n") + "\n"
    [200, { 'Content-Type' => 'text/plain' }, response]
  end
end

run Uploader.new
