#import "YapCollectionsDatabase.h"
#import "YapCollectionsDatabasePrivate.h"
#import "YapAbstractDatabasePrivate.h"
#import "YapCollectionKey.h"
#import "YapDatabaseLogging.h"

#import "sqlite3.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_INFO;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif

NSString *const YapCollectionsDatabaseObjectChangesKey      = @"objectChanges";
NSString *const YapCollectionsDatabaseMetadataChangesKey    = @"metadataChanges";
NSString *const YapCollectionsDatabaseRemovedKeysKey        = @"removedKeys";
NSString *const YapCollectionsDatabaseRemovedCollectionsKey = @"removedCollections";
NSString *const YapCollectionsDatabaseAllKeysRemovedKey     = @"allKeysRemoved";

/**
 * YapDatabase provides concurrent thread-safe access to a key-value database backed by sqlite.
 *
 * A vast majority of the implementation is in YapAbstractDatabase.
 * The YapAbstractDatabase implementation is shared between YapDatabase and YapCollectionsDatabase.
**/
@implementation YapCollectionsDatabase

/**
 * The default serializer & deserializer use NSCoding (NSKeyedArchiver & NSKeyedUnarchiver).
 * Thus the objects need only support the NSCoding protocol.
**/
+ (YapCollectionsDatabaseSerializer)defaultSerializer
{
	return ^ NSData* (NSString *collection, NSString *key, id object){
		return [NSKeyedArchiver archivedDataWithRootObject:object];
	};
}

/**
 * The default serializer & deserializer use NSCoding (NSKeyedArchiver & NSKeyedUnarchiver).
 * Thus the objects need only support the NSCoding protocol.
**/
+ (YapCollectionsDatabaseDeserializer)defaultDeserializer
{
	return ^ id (NSString *collection, NSString *key, NSData *data){
		return [NSKeyedUnarchiver unarchiveObjectWithData:data];
	};
}

/**
 * Property lists ONLY support the following: NSData, NSString, NSArray, NSDictionary, NSDate, and NSNumber.
 * Property lists are highly optimized and are used extensively Apple.
 *
 * Property lists make a good fit when your existing code already uses them,
 * such as replacing NSUserDefaults with a database.
**/
+ (YapCollectionsDatabaseSerializer)propertyListSerializer
{
	return ^ NSData* (NSString *collection, NSString *key, id object){
		return [NSPropertyListSerialization dataWithPropertyList:object
		                                                  format:NSPropertyListBinaryFormat_v1_0
		                                                 options:NSPropertyListImmutable
		                                                   error:NULL];
	};
}

/**
 * Property lists ONLY support the following: NSData, NSString, NSArray, NSDictionary, NSDate, and NSNumber.
 * Property lists are highly optimized and are used extensively Apple.
 *
 * Property lists make a good fit when your existing code already uses them,
 * such as replacing NSUserDefaults with a database.
**/
+ (YapCollectionsDatabaseDeserializer)propertyListDeserializer
{
	return ^ id (NSString *collection, NSString *key, NSData *data){
		return [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
	};
}

/**
 * A FASTER serializer than the default, if serializing ONLY a NSDate object.
 * You may want to use timestampSerializer & timestampDeserializer if your metadata is simply an NSDate.
**/
+ (YapCollectionsDatabaseSerializer)timestampSerializer
{
	return ^ NSData* (NSString *collection, NSString *key, id object) {
		
		if ([object isKindOfClass:[NSDate class]])
		{
			NSTimeInterval timestamp = [(NSDate *)object timeIntervalSinceReferenceDate];
			
			return [[NSData alloc] initWithBytes:(void *)&timestamp length:sizeof(NSTimeInterval)];
		}
		else
		{
			return [NSKeyedArchiver archivedDataWithRootObject:object];
		}
	};
}

/**
 * A FASTER deserializer than the default, if deserializing data from timestampSerializer.
 * You may want to use timestampSerializer & timestampDeserializer if your metadata is simply an NSDate.
**/
+ (YapCollectionsDatabaseDeserializer)timestampDeserializer
{
	return ^ id (NSString *collection, NSString *key, NSData *data) {
		
		if ([data length] == sizeof(NSTimeInterval))
		{
			NSTimeInterval timestamp;
			memcpy((void *)&timestamp, [data bytes], sizeof(NSTimeInterval));
			
			return [[NSDate alloc] initWithTimeIntervalSinceReferenceDate:timestamp];
		}
		else
		{
			return [NSKeyedUnarchiver unarchiveObjectWithData:data];
		}
	};
}

#pragma mark Properties

@synthesize objectSerializer = objectSerializer;
@synthesize objectDeserializer = objectDeserializer;
@synthesize metadataSerializer = metadataSerializer;
@synthesize metadataDeserializer = metadataDeserializer;
@synthesize objectSanitizer = objectSanitizer;
@synthesize metadataSanitizer = metadataSanitizer;

#pragma mark Init

- (id)initWithPath:(NSString *)inPath
{
	return [self initWithPath:inPath
	         objectSerializer:NULL
	       objectDeserializer:NULL
	       metadataSerializer:NULL
	     metadataDeserializer:NULL
	          objectSanitizer:NULL
	        metadataSanitizer:NULL];
}

- (id)initWithPath:(NSString *)inPath
        serializer:(YapCollectionsDatabaseSerializer)inSerializer
      deserializer:(YapCollectionsDatabaseDeserializer)inDeserializer
{
	return [self initWithPath:inPath
	         objectSerializer:inSerializer
	       objectDeserializer:inDeserializer
	       metadataSerializer:inSerializer
	     metadataDeserializer:inDeserializer
	          objectSanitizer:NULL
	        metadataSanitizer:NULL];
}

- (id)initWithPath:(NSString *)inPath
        serializer:(YapCollectionsDatabaseSerializer)inSerializer
      deserializer:(YapCollectionsDatabaseDeserializer)inDeserializer
         sanitizer:(YapCollectionsDatabaseSanitizer)inSanitizer
{
	return [self initWithPath:inPath
	         objectSerializer:inSerializer
	       objectDeserializer:inDeserializer
	       metadataSerializer:inSerializer
	     metadataDeserializer:inDeserializer
	          objectSanitizer:inSanitizer
	        metadataSanitizer:inSanitizer];
}

- (id)initWithPath:(NSString *)inPath objectSerializer:(YapCollectionsDatabaseSerializer)inObjectSerializer
                                    objectDeserializer:(YapCollectionsDatabaseDeserializer)inObjectDeserializer
                                    metadataSerializer:(YapCollectionsDatabaseSerializer)inMetadataSerializer
                                  metadataDeserializer:(YapCollectionsDatabaseDeserializer)inMetadataDeserializer
{
	return [self initWithPath:inPath
	         objectSerializer:inObjectSerializer
	       objectDeserializer:inObjectDeserializer
	       metadataSerializer:inMetadataSerializer
	     metadataDeserializer:inMetadataDeserializer
	          objectSanitizer:NULL
	        metadataSanitizer:NULL];
}

- (id)initWithPath:(NSString *)inPath objectSerializer:(YapCollectionsDatabaseSerializer)inObjectSerializer
                                    objectDeserializer:(YapCollectionsDatabaseDeserializer)inObjectDeserializer
                                    metadataSerializer:(YapCollectionsDatabaseSerializer)inMetadataSerializer
                                  metadataDeserializer:(YapCollectionsDatabaseDeserializer)inMetadataDeserializer
                                       objectSanitizer:(YapCollectionsDatabaseSanitizer)inObjectSanitizer
                                     metadataSanitizer:(YapCollectionsDatabaseSanitizer)inMetadataSanitizer;
{
	if ((self = [super initWithPath:inPath]))
	{
		YapCollectionsDatabaseSerializer defaultSerializer     = nil;
		YapCollectionsDatabaseDeserializer defaultDeserializer = nil;
		
		if (!inObjectSerializer || !inMetadataSerializer)
			defaultSerializer = [[self class] defaultSerializer];
		
		if (!inObjectDeserializer || !inMetadataDeserializer)
			defaultDeserializer = [[self class] defaultDeserializer];
		
		objectSerializer = inObjectSerializer ? inObjectSerializer : defaultSerializer;
		objectDeserializer = inObjectDeserializer ? inObjectDeserializer : defaultDeserializer;
		
		metadataSerializer = inMetadataSerializer ? inMetadataSerializer : defaultSerializer;
		metadataDeserializer = inMetadataDeserializer ? inMetadataDeserializer : defaultDeserializer;
		
		objectSanitizer = inObjectSanitizer;
		metadataSanitizer = inMetadataSanitizer;
	}
	return self;
}

#pragma mark Setup

/**
 * Required override method from YapAbstractDatabase.
 *
 * The abstract version creates the 'yap' table, which is used internally.
 * Our version creates the 'database' table, which holds the key/object/metadata rows.
**/
- (BOOL)createTables
{
	int status;
	
	char *createDatabaseStatement =
	    "CREATE TABLE IF NOT EXISTS \"database2\""
	    " (\"rowid\" INTEGER PRIMARY KEY,"
	    "  \"collection\" CHAR NOT NULL,"
	    "  \"key\" CHAR NOT NULL,"
	    "  \"data\" BLOB,"
	    "  \"metadata\" BLOB"
	    " );";
	
	status = sqlite3_exec(db, createDatabaseStatement, NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"Failed creating 'database' table: %d %s", status, sqlite3_errmsg(db));
		return NO;
	}
	
	char *createIndexStatement =
	    "CREATE UNIQUE INDEX IF NOT EXISTS \"true_primary_key\" ON \"database2\" ( \"collection\", \"key\" );";
	
	status = sqlite3_exec(db, createIndexStatement, NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		NSLog(@"Failed creating index on 'database' table: %d %s", status, sqlite3_errmsg(db));
		return NO;
	}
	
	return [super createTables];
}

/**
 * Required override method from YapAbstractDatabase.
 * 
 * This method is used when creating the YapSharedCache, and provides the type of key's we'll be using for the cache.
**/
- (Class)cacheKeyClass
{
	return [YapCollectionKey class];
}

/**
 * In version 3 (more commonly known as version 2.1),
 * we altered the tables to use INTEGER PRIMARY KEY's so we could pass rowid's to extensions.
 * 
 * This method migrates 'database' to 'database2'.
**/
- (BOOL)upgradeTable_2_3
{
	int status;
	
	char *stmt = "INSERT INTO \"database2\" (\"collection\", \"key\", \"data\", \"metadata\")"
	             " SELECT \"collection\", \"key\", \"data\", \"metadata\" FROM \"database\";";
	
	status = sqlite3_exec(db, stmt, NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"Error migrating 'database' to 'database2': %d %s", status, sqlite3_errmsg(db));
		return NO;
	}
	
	status = sqlite3_exec(db, "DROP TABLE IF EXISTS \"database\"", NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"Failed dropping 'database' table: %d %s", status, sqlite3_errmsg(db));
		return NO;
	}
	
	return YES;
}

#pragma mark Connections

/**
 * This is a public method called to create a new connection.
 *
 * All the details of managing connections, and managing connection state, is handled by YapAbstractDatabase.
**/
- (YapCollectionsDatabaseConnection *)newConnection
{
	YapCollectionsDatabaseConnection *connection = [[YapCollectionsDatabaseConnection alloc] initWithDatabase:self];
	
	[self addConnection:connection];
	return connection;
}

@end
