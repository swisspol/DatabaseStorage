/*
 Copyright (c) 2014, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "DatabaseStorage.h"

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/storage.db" error:NULL];
    DatabaseStorage* storage = [[DatabaseStorage alloc] initWithPath:@"/tmp/storage.db"];
    
    [storage setString:@"Hello World" forKey:@"string"];
    NSLog(@"\"%@\"", [storage stringForKey:@"string"]);
    
    [storage setValue:[NSNumber numberWithBool:YES] forKey:@"foo"];
    NSLog(@"%@", [storage valueForKey:@"foo"]);
    [storage removeValueForKey:@"foo"];
    NSLog(@"%@", [storage valueForKey:@"foo"]);
    
    [storage setDouble:123.456 forKey:@"bar"];
    NSLog(@"%f", [storage doubleForKey:@"bar"]);
    
    NSError* error = [NSError errorWithDomain:NSCocoaErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Unexpected error"}];
    [storage setObject:error forKey:@"error"];
    NSLog(@"%@", [storage objectForKey:@"error"]);
    
    NSString* backupPath = [@"/tmp" stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
    if ([storage writeBackupToPath:backupPath error:NULL]) {
      [storage removeAllValues];
      NSLog(@"\"%@\"", [storage stringForKey:@"string"]);
      if ([storage readBackupFromPath:backupPath error:NULL]) {
        NSLog(@"\"%@\"", [storage stringForKey:@"string"]);
      }
    }
  }
  return 0;
}
