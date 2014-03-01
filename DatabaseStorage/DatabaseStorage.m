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

#import <sqlite3.h>

#import "DatabaseStorage.h"

typedef enum {
  kValueType_Undefined = 0,
  kValueType_Boolean,
  kValueType_Integer,
  kValueType_Double,
  kValueType_String,
  kValueType_Data,
  kValueType_Object
} ValueType;

#define MAKE_SQLLITE3_ERROR(database) [NSError errorWithDomain:@"SQLite3" \
                                                          code:sqlite3_errcode(database) \
                                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(database)]}]

#define THROW_EXCEPTION(...) do { \
    NSString* reason = [NSString stringWithFormat:__VA_ARGS__]; \
    @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil]; \
  } while (0)

@interface DatabaseStorage () {
  sqlite3* _database;
  sqlite3_stmt* _insertStatement;
  sqlite3_stmt* _selectStatement;
  sqlite3_stmt* _deleteStatement;
  dispatch_queue_t _serialQueue;
}
@end

@implementation DatabaseStorage

+ (DatabaseStorage*)sharedStorage {
  static DatabaseStorage* storage = nil;
  static dispatch_once_t token = 0;
  dispatch_once(&token, ^{
    NSString* documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString* identifier = [[NSBundle mainBundle] bundleIdentifier];
    if (identifier == nil) {
      identifier = [[NSProcessInfo processInfo] processName];
    }
    storage = [[DatabaseStorage alloc] initWithPath:[documentsPath stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"db"]]];
  });
  return storage;
}

- (id)initWithPath:(NSString*)path {
  if ((self = [super init])) {
    if (sqlite3_threadsafe() == 0) {
      NSLog(@"SQLite3 not thread safe");
      return nil;
    }
    
    int result = sqlite3_open_v2([path fileSystemRepresentation], &_database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
    if (result != SQLITE_OK) {
      NSLog(@"Failed opening database (%i): %s", result, sqlite3_errmsg(_database));
      return nil;
    }
    
    sqlite3_stmt* statement = NULL;
    result = sqlite3_prepare_v2(_database, "CREATE TABLE IF NOT EXISTS 'store_v1' ('key' TEXT PRIMARY KEY, 'type' INTEGER, 'value')", -1, &statement, NULL);
    if (result == SQLITE_OK) {
      result = sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
    if (result != SQLITE_DONE) {
      NSLog(@"Failed creating database table (%i): %s", result, sqlite3_errmsg(_database));
      return nil;
    }
    
    result = sqlite3_prepare_v2(_database, "INSERT OR REPLACE INTO store_v1 (key, type, value) VALUES (?1, ?2, ?3)", -1, &_insertStatement, NULL);
    if (result == SQLITE_OK) {
      result = sqlite3_prepare_v2(_database, "SELECT type, value FROM store_v1 WHERE key=?1", -1, &_selectStatement, NULL);
    }
    if (result == SQLITE_OK) {
      result = sqlite3_prepare_v2(_database, "DELETE FROM store_v1 WHERE key=?1", -1, &_deleteStatement, NULL);
    }
    if (result != SQLITE_OK) {
      NSLog(@"Failed creating database statements (%i): %s", result, sqlite3_errmsg(_database));
      return nil;
    }
    
    _serialQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)dealloc {
  dispatch_release(_serialQueue);
  sqlite3_finalize(_selectStatement);
  sqlite3_finalize(_insertStatement);
  sqlite3_finalize(_deleteStatement);
  sqlite3_close(_database);
}

- (BOOL)writeBackupToPath:(NSString*)path error:(NSError**)error {
  __block BOOL success = NO;
  sqlite3* database = NULL;
  int result = sqlite3_open_v2([path fileSystemRepresentation], &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, NULL);
  if (result == SQLITE_OK) {
    dispatch_sync(_serialQueue, ^{
      sqlite3_backup* backup = sqlite3_backup_init(database, "main", _database, "main");
      if (backup) {
        sqlite3_backup_step(backup, -1);
        sqlite3_backup_finish(backup);
      }
      if (sqlite3_errcode(database) == SQLITE_OK) {
        success = YES;
      } else if (error) {
        *error = MAKE_SQLLITE3_ERROR(database);
      }
    });
  } else if (error) {
    *error = MAKE_SQLLITE3_ERROR(database);
  }
  if (database) {
    sqlite3_close(database);
  }
  return success;
}

- (BOOL)readBackupFromPath:(NSString*)path error:(NSError**)error {
  __block BOOL success = NO;
  sqlite3* database = NULL;
  int result = sqlite3_open_v2([path fileSystemRepresentation], &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
  if (result == SQLITE_OK) {
    dispatch_sync(_serialQueue, ^{
      sqlite3_backup* backup = sqlite3_backup_init(_database, "main", database, "main");
      if (backup) {
        sqlite3_backup_step(backup, -1);
        sqlite3_backup_finish(backup);
      }
      if (sqlite3_errcode(_database) == SQLITE_OK) {
        success = YES;
      } else if (error) {
        *error = MAKE_SQLLITE3_ERROR(_database);
      }
    });
  } else if (error) {
    *error = MAKE_SQLLITE3_ERROR(database);
  }
  if (database) {
    sqlite3_close(database);
  }
  return success;
}

- (void)_insertOrReplaceValue:(const void*)valuePtr forKey:(NSString*)key withType:(ValueType)type {
  dispatch_sync(_serialQueue, ^{
    int result = sqlite3_reset(_insertStatement);
    if (result == SQLITE_OK) {
      result = sqlite3_bind_text(_insertStatement, 1, [key UTF8String], -1, SQLITE_STATIC);
      if (result == SQLITE_OK) {
        result = sqlite3_bind_int(_insertStatement, 2, type);
        if (result == SQLITE_OK) {
          switch (type) {
            
            case kValueType_Undefined:
              break;
            
            case kValueType_Boolean: {
              BOOL boolValue = *(BOOL*)valuePtr;
              result = sqlite3_bind_int(_insertStatement, 3, boolValue ? 1 : 0);
              break;
            }
            
            case kValueType_Integer: {
              NSInteger integerValue = *(NSInteger*)valuePtr;
              result = sqlite3_bind_int64(_insertStatement, 3, integerValue);
              break;
            }
            
            case kValueType_Double: {
              double doubleValue = *(double*)valuePtr;
              result = sqlite3_bind_double(_insertStatement, 3, doubleValue);
              break;
            }
            
            case kValueType_String: {
              NSString* stringValue = (__bridge NSString*)valuePtr;
              result = sqlite3_bind_text(_insertStatement, 3, [stringValue UTF8String], -1, SQLITE_STATIC);
              break;
            }
            
            case kValueType_Data: {
              NSData* dataValue = (__bridge NSData*)valuePtr;
              result = sqlite3_bind_blob(_insertStatement, 3, dataValue.bytes, dataValue.length, SQLITE_STATIC);  // Equivalent to sqlite3_bind_null() for zero-length
              break;
            }
            
            case kValueType_Object: {
              id<NSCoding> objectValue = (__bridge id<NSCoding>)valuePtr;
              NSData* data = [NSKeyedArchiver archivedDataWithRootObject:objectValue];
              result = sqlite3_bind_blob(_insertStatement, 3, data.bytes, data.length, SQLITE_STATIC);
              break;
            }
            
          }
          if (result == SQLITE_OK) {
            result = sqlite3_step(_insertStatement);
          }
        }
      }
    }
    if (result != SQLITE_DONE) {
      THROW_EXCEPTION(@"Failed writing database storage value for key '%@': %s (%i)", key, sqlite3_errmsg(_database), result);
    }
  });
}

- (id)_selectValueForKey:(NSString*)key requestedType:(ValueType)requestedType valuePtr:(void*)valuePtr {
  __block id value = nil;
  dispatch_sync(_serialQueue, ^{
    int result = sqlite3_reset(_selectStatement);
    if (result == SQLITE_OK) {
      sqlite3_bind_text(_selectStatement, 1, [key UTF8String], -1, SQLITE_STATIC);
      result = sqlite3_step(_selectStatement);
      if (result == SQLITE_ROW) {
        ValueType type = sqlite3_column_int(_selectStatement, 0);
        if ((requestedType != kValueType_Undefined) && (requestedType != type)) {
          THROW_EXCEPTION(@"Incompatible database storage type for key '%@'", key);
        }
        switch (type) {
          
          case kValueType_Undefined:
            break;
          
          case kValueType_Boolean:
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_INTEGER) {
              BOOL boolValue = sqlite3_column_int(_selectStatement, 1) ? YES : NO;
              if (requestedType == kValueType_Undefined) {
                value = [NSNumber numberWithBool:boolValue];
              } else {
                *(BOOL*)valuePtr = boolValue;
              }
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
            
          case kValueType_Integer:
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_INTEGER) {
              NSInteger integerValue = sqlite3_column_int64(_selectStatement, 1);
              if (requestedType == kValueType_Undefined) {
                value = [NSNumber numberWithInteger:integerValue];
              } else {
                *(NSInteger*)valuePtr = integerValue;
              }
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
            
          case kValueType_Double:
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_FLOAT) {
              double doubleValue = sqlite3_column_double(_selectStatement, 1);
              if (requestedType == kValueType_Undefined) {
                value = [NSNumber numberWithDouble:doubleValue];
              } else {
                *(double*)valuePtr = doubleValue;
              }
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
            
          case kValueType_String: {
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_TEXT) {
              const unsigned char* text = sqlite3_column_text(_selectStatement, 1);
              if (text) {
                value = [NSString stringWithUTF8String:(const char*)text];
              }
              if (value == nil) {
                THROW_EXCEPTION(@"Unexpected database storage string for key '%@'", key);
              }
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
          }
            
          case kValueType_Data: {
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_BLOB) {
              const void* bytes = sqlite3_column_blob(_selectStatement, 1);
              if (bytes) {
                int length = sqlite3_column_bytes(_selectStatement, 1);
                value = [NSData dataWithBytes:bytes length:length];
              }
              if (value == nil) {
                THROW_EXCEPTION(@"Unexpected database storage data for key '%@'", key);
              }
            } else if (sqlite3_column_type(_selectStatement, 1) == SQLITE_NULL) {
              value = [NSData data];
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
          }
            
          case kValueType_Object: {
            if (sqlite3_column_type(_selectStatement, 1) == SQLITE_BLOB) {
              const void* bytes = sqlite3_column_blob(_selectStatement, 1);
              if (bytes) {
                int length = sqlite3_column_bytes(_selectStatement, 1);
                NSData* data = [NSData dataWithBytesNoCopy:(void*)bytes length:length freeWhenDone:NO];
                value = [NSKeyedUnarchiver unarchiveObjectWithData:data];
              }
              if (value == nil) {
                THROW_EXCEPTION(@"Unexpected database storage object for key '%@'", key);
              }
            } else {
              THROW_EXCEPTION(@"Unexpected database storage type for key '%@'", key);
            }
            break;
          }
            
        }
        result = sqlite3_step(_selectStatement);
      }
    }
    if (result != SQLITE_DONE) {
      THROW_EXCEPTION(@"Failed reading database storage value for key '%@': %s (%i)", key, sqlite3_errmsg(_database), result);
    }
  });
  return value;
}

- (void)_deleteValueForKey:(NSString*)key {
  dispatch_sync(_serialQueue, ^{
    int result = sqlite3_reset(_deleteStatement);
    if (result == SQLITE_OK) {
      sqlite3_bind_text(_deleteStatement, 1, [key UTF8String], -1, SQLITE_STATIC);
      result = sqlite3_step(_deleteStatement);
    }
    if (result != SQLITE_DONE) {
      THROW_EXCEPTION(@"Failed deleting database storage value for key '%@': %s (%i)", key, sqlite3_errmsg(_database), result);
    }
  });
}

- (void)_deleteAllValues {
  dispatch_sync(_serialQueue, ^{
    sqlite3_stmt* statement = NULL;
    int result = sqlite3_prepare_v2(_database, "DELETE FROM store_v1", -1, &statement, NULL);
    if (result == SQLITE_OK) {
      result = sqlite3_step(statement);
      sqlite3_finalize(statement);
    }
    if (result != SQLITE_DONE) {
      THROW_EXCEPTION(@"Failed deleting all database storage values: %s (%i)", sqlite3_errmsg(_database), result);
    }
  });
}

- (void)setValue:(id)value forKey:(NSString*)key {
  if (value) {
    if ([value isKindOfClass:[NSNumber class]]) {
      if (((__bridge CFTypeRef)value == kCFBooleanFalse) || ((__bridge CFTypeRef)value == kCFBooleanTrue)) {
        BOOL booleanValue = [(NSNumber*)value boolValue];
        [self _insertOrReplaceValue:&booleanValue forKey:key withType:kValueType_Boolean];
      } else if (CFNumberIsFloatType((CFNumberRef)value)) {
        double doubleValue = [(NSNumber*)value doubleValue];
        [self _insertOrReplaceValue:&doubleValue forKey:key withType:kValueType_Double];
      } else {
        NSInteger integerValue = [(NSNumber*)value integerValue];
        [self _insertOrReplaceValue:&integerValue forKey:key withType:kValueType_Integer];
      }
    } else if ([value isKindOfClass:[NSString class]]) {
      [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_String];
    } else if ([value isKindOfClass:[NSData class]]) {
      [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_Data];
    } if ([value conformsToProtocol:@protocol(NSCoding)]) {
      [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_Object];
    } else {
      THROW_EXCEPTION(@"Unsupported database storage value type for key '%@': %@", key, [value class]);
    }
  } else {
    [self _deleteValueForKey:key];
  }
}

- (id)valueForKey:(NSString*)key {
  return [self _selectValueForKey:key requestedType:kValueType_Undefined valuePtr:NULL];
}

- (void)removeValueForKey:(NSString*)key {
  [self _deleteValueForKey:key];
}

- (void)removeAllValues {
  [self _deleteAllValues];
}

@end

@implementation DatabaseStorage (Extensions)

- (void)setBool:(BOOL)value forKey:(NSString*)key {
  [self _insertOrReplaceValue:&value forKey:key withType:kValueType_Boolean];
}

- (BOOL)boolForKey:(NSString*)key {
  BOOL value;
  [self _selectValueForKey:key requestedType:kValueType_Boolean valuePtr:&value];
  return value;
}

- (void)setInteger:(NSInteger)value forKey:(NSString*)key {
  [self _insertOrReplaceValue:&value forKey:key withType:kValueType_Integer];
}

- (NSInteger)integerForKey:(NSString*)key {
  NSInteger value;
  [self _selectValueForKey:key requestedType:kValueType_Integer valuePtr:&value];
  return value;
}

- (void)setDouble:(double)value forKey:(NSString*)key {
  if (!isnan(value)) {
    [self _insertOrReplaceValue:&value forKey:key withType:kValueType_Double];
  } else {
    [self _deleteValueForKey:key];
  }
}

- (double)doubleForKey:(NSString*)key {
  double value;
  [self _selectValueForKey:key requestedType:kValueType_Double valuePtr:&value];
  return value;
}

- (void)setString:(NSString*)value forKey:(NSString*)key {
  [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_String];
}

- (NSString*)stringForKey:(NSString*)key {
  return [self _selectValueForKey:key requestedType:kValueType_String valuePtr:NULL];
}

- (void)setData:(NSData*)value forKey:(NSString*)key {
  if (value) {
    [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_Data];
  } else {
    [self _deleteValueForKey:key];
  }
}

- (NSData*)dataForKey:(NSString*)key {
  return [self _selectValueForKey:key requestedType:kValueType_Data valuePtr:NULL];
}

- (void)setObject:(id<NSCoding>)value forKey:(NSString*)key {
  if (value) {
    [self _insertOrReplaceValue:(__bridge const void*)value forKey:key withType:kValueType_Object];
  } else {
    [self _deleteValueForKey:key];
  }
}

- (id<NSCoding>)objectForKey:(NSString*)key {
  return [self _selectValueForKey:key requestedType:kValueType_Object valuePtr:NULL];
}

@end
