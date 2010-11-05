require 'rack/session/gcd'

class SessionCheck
  def call(env)
    session = env['rack.session']
    if session
      if session[:num_accesses]
        session[:num_accesses] += 1
        msg = "This session has been accessed #{session[:num_accesses]} times"
      else
        session[:num_accesses] = 1
        msg = 'This is the first time this session has been accessed'
      end
    else
      msg = 'Whoops! No session...'
    end
    [200, {'Content-Type' => 'text/plain'}, msg]
  end
end

$VERBOSE = true, $DEBUG = true
use Rack::Session::GCD, :expire_after => 30
run SessionCheck.new
