/*
 * This file is covered by the Ruby license. See COPYING for more details.
 * Copyright (C) 2009-2010, Apple Inc. All rights reserved.
 */

#import "CTParser.h"

#pragma mark Parser Callbacks

#define DEF_MAX_LENGTH(N, val) const size_t MAX_##N##_LENGTH = val

#define VALIDATE_MAX_LENGTH(len, N)\
  if(len > MAX_##N##_LENGTH) {\
    [NSException raise:@"ParserFieldLengthError"\
                format:@"HTTP element " # N " is longer than the " # len " character allowed length."];\
  }

#define PARSE_FIELD(field)\
  void parse_##field (void *env, const char *at, size_t length)\
  {\
    VALIDATE_MAX_LENGTH(length, field)\
    [(NSMutableDictionary *)env setObject:[[NSString alloc] initWithBytes:at\
                                                                   length:length\
                                                                 encoding:NSUTF8StringEncoding ]\
                                   forKey:@"" #field];\
    return;\
  }

// Max field lengths
DEF_MAX_LENGTH(FIELD_NAME, 256);
DEF_MAX_LENGTH(FIELD_VALUE, 80 * 1024);
DEF_MAX_LENGTH(REQUEST_METHOD, 256);
DEF_MAX_LENGTH(REQUEST_URI, 1024 * 12);
DEF_MAX_LENGTH(FRAGMENT, 1024);
DEF_MAX_LENGTH(PATH_INFO, 1024);
DEF_MAX_LENGTH(QUERY_STRING, (1024 * 10));
DEF_MAX_LENGTH(HTTP_VERSION, 256);
DEF_MAX_LENGTH(HEADER, (1024 * (80 + 32)));

void parse_HTTP_FIELD(void *env, const char *field, size_t flen, const char *value, size_t vlen)
{
  VALIDATE_MAX_LENGTH(flen, FIELD_NAME);
  VALIDATE_MAX_LENGTH(vlen, FIELD_VALUE);
  [(NSMutableDictionary *)env setObject:[[NSString alloc] initWithBytes:value
                                                                 length:vlen
                                                               encoding:NSUTF8StringEncoding]
                                 forKey:[@"HTTP_" stringByAppendingString:[[NSString alloc] initWithBytes:field
                                                                                                   length:flen
                                                                                                 encoding:NSUTF8StringEncoding]]];
  return;
}

// Parsing callback functions
PARSE_FIELD(REQUEST_METHOD);
PARSE_FIELD(REQUEST_URI);
PARSE_FIELD(FRAGMENT);
PARSE_FIELD(PATH_INFO);
PARSE_FIELD(QUERY_STRING);
PARSE_FIELD(HTTP_VERSION);

void header_done(void *env, const char *at, size_t length)
{
  NSMutableDictionary *environment = (NSMutableDictionary *)env;
  NSString *contentLength = [environment objectForKey:@"HTTP_CONTENT_LENGTH"];
  if (contentLength != nil) {
    [environment setObject:contentLength forKey:@"CONTENT_LENGTH"];
  }

  NSString *contentType = [environment objectForKey:@"HTTP_CONTENT_TYPE"];
  if (contentType != nil) {
    [environment setObject:contentType forKey:@"CONTENT_TYPE"];
  }

  [environment setObject:@"CGI/1.2" forKey:@"GATEWAY_INTERFACE"];

  NSString *hostString = [environment objectForKey:@"HTTP_HOST"];
  NSString *serverName = nil;
  NSString *serverPort = nil;
  if (hostString != nil) {
    NSRange colon_pos = [hostString rangeOfString:@":"];
    if (colon_pos.location != NSNotFound) {
      serverName = [hostString substringToIndex:colon_pos.location];
      serverPort = [hostString substringFromIndex:(colon_pos.location + 1)];
    } else {
      serverName = [NSString stringWithString:hostString];
      serverPort = @"80";
    }
    [environment setObject:serverName forKey:@"SERVER_NAME"];
    [environment setObject:serverPort forKey:@"SERVER_PORT"];
  }

  [environment setObject:@"HTTP/1.1" forKey:@"SERVER_PROTOCOL"];
  [environment setObject:SERVER_SOFTWARE forKey:@"SERVER_SOFTWARE"];

  // We don't do tls yet
  [environment setObject:@"http" forKey:@"rack.url_scheme"];

  // To satisfy Rack specs...
  if ([environment objectForKey:@"QUERY_STRING"] == nil) {
    [environment setObject:@"" forKey:@"QUERY_STRING"];
  }

  // If we've been given any part of the body, put it here
  NSMutableString *body = [environment objectForKey:@"rack.input"];
  if (body != nil) {
    [body appendString:[[NSString alloc] initWithBytes:at length:length encoding:NSASCIIStringEncoding]];
  } else {
    NSLog(@"Hmm...you seem to have body data but no where to put it. That's probably an error.");
  }

  return;
}

@implementation CTParser

@synthesize body = _body;

- (id)init {
  [super init];
  _parser = malloc(sizeof(http_parser));

  // Setup the callbacks
  _parser->http_field     = parse_HTTP_FIELD;
  _parser->request_method = parse_REQUEST_METHOD;
  _parser->request_uri    = parse_REQUEST_URI;
  _parser->fragment       = parse_FRAGMENT;
  _parser->request_path   = parse_PATH_INFO;
  _parser->query_string   = parse_QUERY_STRING;
  _parser->http_version   = parse_HTTP_VERSION;
  _parser->header_done    = header_done;

  http_parser_init(_parser);
  return self;
}

- (void)reset
{
  http_parser_init(_parser);
  return;
}


- (NSNumber *)parseData:(NSString *)dataBuf forEnvironment:(NSMutableDictionary *)env startingAt:(NSNumber *)startingPos
{
  const char *data = [dataBuf UTF8String];
  size_t length = [dataBuf length];
  size_t offset = [startingPos unsignedLongValue];
  _parser->data = env;

  http_parser_execute(_parser, data, length, offset);
  if (http_parser_has_error(_parser)) {
    [NSException raise:@"CTParserError" format:@"Invalid HTTP format, parsing failed."];
  }

  NSNumber *headerLength = [NSNumber numberWithUnsignedLong:_parser->nread];
  VALIDATE_MAX_LENGTH([headerLength unsignedLongValue], HEADER);
  return headerLength;
}

- (NSNumber *)parseData:(NSString *)dataBuf forEnvironment:(NSDictionary *)env
{
  return [self parseData:dataBuf forEnvironment:env startingAt:0];
}

- (BOOL)errorCond
{
  return http_parser_has_error(_parser);
}

- (BOOL)finished
{
  return http_parser_is_finished(_parser);
}

- (NSNumber *)nread
{
  return [NSNumber numberWithInt:_parser->nread];
}

- (void)finalize
{
  if (_parser != NULL)
    free(_parser);
  [super finalize];
}

@end

void
Init_CTParser(void)
{
  // Do nothing. This function is required by the MacRuby runtime when this
  // file is compiled as a C extension bundle.
}
