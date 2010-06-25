/*
 * This file is covered by the Ruby license. See COPYING for more details.
 * Copyright (C) 2009-2010, Apple Inc. All rights reserved.
 */

#include "http11_parser.h"
#import <Foundation/Foundation.h>

// TODO - We should grab this from a plist somewhere...
#define SERVER_SOFTWARE @"Control Tower v0.1"

@interface CTParser : NSObject
{
  http_parser *_parser;
}

- (id)init;
- (void)reset;

- (NSNumber *)parseData:(NSData *)dataBuf forEnvironment:(NSDictionary *)env startingAt:(NSNumber *)startingPos;
- (NSNumber *)parseData:(NSData *)dataBuf forEnvironment:(NSDictionary *)env;

- (BOOL)errorCond;
- (BOOL)finished;
- (NSNumber *)nread;

- (void)finalize;

@end
