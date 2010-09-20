# This is a basic Sinatra sample.
#
# NOTE: You must have the Sinatra gem installed before running

require 'rubygems'
require 'sinatra/base'

class MyApp < Sinatra::Base
  get '/' do
    'Hello world!'
  end
end

run MyApp.new
