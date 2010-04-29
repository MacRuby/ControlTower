# This file is covered by the Ruby license. See COPYING for more details.
# Copyright (C) 2009-2010, Apple Inc. All rights reserved.

require "bacon"
require 'stringio'

framework "CTParser"

describe "Instantiating a new Parser" do
  it "should return an object of class CTParser" do
    parser = CTParser.new
    parser.class.should == CTParser
  end
end

describe "Parsing a minimal header" do
  before do
    @env = { 'rack.input' => StringIO.new }
    @parser = CTParser.new
    @header = "GET / HTTP/1.1\r\n\r\n"
    @read = @parser.parseData(@header, forEnvironment:@env)
  end

  it "should parse the full header length" do
    @read.should == @header.length
  end

  it "should finish" do
    @parser.finished.should == 1
  end

  it "should not have any errors" do
    @parser.errorCond.should == 0
  end

  it "should have read as many bytes as it read" do
    @parser.nread.should == @read
  end

  it "should populate SERVER_PROTOCOL" do
    @env['SERVER_PROTOCOL'].should == 'HTTP/1.1'
  end

  it "should populate PATH_INFO" do
    @env['PATH_INFO'].should == "/"
  end

  it "should populate HTTP_VERSION" do
    @env['HTTP_VERSION'].should == 'HTTP/1.1'
  end

  it "should populate GATEWAY_INTERFACE" do
    @env['GATEWAY_INTERFACE'].should == 'CGI/1.2'
  end

  it "should populate REQUEST_METHOD" do
    @env['REQUEST_METHOD'].should == 'GET'
  end

  it "should not have generated any fragments" do
    @env['FRAGMENT'].should.be.nil
  end

  it "should not populate QUERY_STRING" do
    @env['QUERY_STRING'].should.be.empty
  end
end
