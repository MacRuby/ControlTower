# NOTE: Your cwd needs to be the sample/ directory when you start ControlTower
class FileSender
  def call(env)
    headers = { 'Content-Type' => 'text/plain',
                'X-Sendfile' => ::File.expand_path('../body_content.txt', __FILE__) }
    [200, headers, "You shouldn't get this body..."]
  end
end

run FileSender.new
