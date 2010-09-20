# This is just a basic "hello, world" stlye rack-up to get you going

class Hello
  def call(env)
    [200, { 'Content-Type' => 'text/plain' }, "Hello, world! Your environment is #{env}"]
  end
end

run Hello.new
