# This is a quick demonstration of ControlTower's X-Sendfile functionality
#
# NOTE: Set the EXAMPLE_FILE environment variable to the path of the file you
# want to send. See the README for more info.

class FileSender
  def call(env)
    headers = { 'Content-Type' => 'text/plain' }
    headers['X-Sendfile'] = ::File.expand_path(ENV['EXAMPLE_FILE']) if ENV['EXAMPLE_FILE']
    [200, headers, "You shouldn't get this body... see the README for more info\n"]
  end
end

run FileSender.new
