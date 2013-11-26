//
//  TSEncryptedDatabase.m
//  TextSecureiOS
//
//  Created by Christine Corbett Moran on 10/12/13.
//  Copyright (c) 2013 Open Whisper Systems. All rights reserved.
//

#import "TSEncryptedDatabase.h"
#import "RNDecryptor.h"
#import "RNEncryptor.h"
#import "Cryptography.h"
#import "FMDatabase.h"
#import "FMDatabaseQueue.h"
#import "ECKeyPair.h"
#import "FilePath.h"
#include "NSData+Base64.h"
#import "TSRegisterPrekeys.h"
#import "KeychainWrapper.h"

#define kDBWasCreatedBool @"DBWasCreated"
#define databaseFileName @"cryptography.db"

// Reference to the singleton
static TSEncryptedDatabase *SharedCryptographyDatabase = nil;


#pragma mark Private Methods
@interface TSEncryptedDatabase(Private)

-(instancetype) initWithDatabaseQueue:(FMDatabaseQueue *)queue;

// DB creation helper functions
-(void) generatePersonalPrekeys;
-(void) generateIdentityKey;

// DB master key functions
+(NSData*) generateDatabaseMasterKeyWithPassword:(NSString *)userPassword;
+(NSData*) getDatabaseMasterKeyWithPassword:(NSString *)userPassword error:(NSError **)error;
+(void) eraseDatabaseMasterKey;
@end


@implementation TSEncryptedDatabase


#pragma mark DB Instantiation Methods

+(instancetype) database {
  if (!SharedCryptographyDatabase) {
     @throw [NSException exceptionWithName:@"incorrect initialization" reason:@"database must be unlocked or created prior to being able to use this method" userInfo:nil];
  }
  return SharedCryptographyDatabase;
  
}


+(void) databaseErase {
    @synchronized(SharedCryptographyDatabase) {
        [TSEncryptedDatabase databaseLock];
        
        // Erase the DB file
        [[NSFileManager defaultManager] removeItemAtPath:[FilePath pathInDocumentsDirectory:databaseFileName] error:nil];
        
        // Erase the DB encryption key from the Keychain
        [TSEncryptedDatabase eraseDatabaseMasterKey];
        
        // Update the preferences
        [[NSUserDefaults standardUserDefaults] setBool:FALSE forKey:kDBWasCreatedBool];
    }
}


+(void) databaseLock {
    @synchronized(SharedCryptographyDatabase.dbQueue) {
        // Synchronized in case some other code/thread still has a reference to the DB
        [SharedCryptographyDatabase.dbQueue close];
        SharedCryptographyDatabase.dbQueue = nil;
    }
}


+(instancetype) databaseCreateWithPassword:(NSString *)userPassword error:(NSError **)error {

    // Have we created a DB on this device already ?
    if ([TSEncryptedDatabase databaseWasCreated]) {
        if (error) {
            NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
            // TODO : define error codes
            [errorDetail setValue:@"database already exists" forKey:NSLocalizedDescriptionKey];
            *error = [NSError errorWithDomain:@"textSecure" code:101 userInfo:errorDetail];
        }
        return nil;
    }


    // 1. Create the DB encryption key, the DB and the tables
    NSData *dbMasterKey = [TSEncryptedDatabase generateDatabaseMasterKeyWithPassword: userPassword];
    __block BOOL dbInitSuccess = NO;
    FMDatabaseQueue *dbQueue = [FMDatabaseQueue databaseQueueWithPath:[FilePath pathInDocumentsDirectory:databaseFileName]];
    [dbQueue inDatabase:^(FMDatabase *db) {
        
        if(![db setKeyWithData:dbMasterKey]) {
            return;
        }
        
        if (![db executeUpdate:@"CREATE TABLE persistent_settings (setting_name TEXT UNIQUE,setting_value TEXT)"]) {
            // Happens when the master key is wrong (ie. wrong (old?) encrypted key in the keychain)
            return;
        }
        if (![db executeUpdate:@"CREATE TABLE personal_prekeys (prekey_id INTEGER UNIQUE,public_key TEXT,private_key TEXT, last_counter INTEGER)"]){
            return;
        }
        dbInitSuccess = YES;
    }
     ];
    
    if (!dbInitSuccess) {
        if (error) {
            NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
            // TODO : define error codes
            [errorDetail setValue:@"could not create database" forKey:NSLocalizedDescriptionKey];
            *error = [NSError errorWithDomain:@"textSecure" code:102 userInfo:errorDetail];
        }
        // Cleanup
        [TSEncryptedDatabase databaseErase];
        return nil;
    }
    
    // We have now have an empty DB
    SharedCryptographyDatabase = [[TSEncryptedDatabase alloc] initWithDatabaseQueue:dbQueue];

    
    // 3. Generate and store the user's identity keys and prekeys
    [SharedCryptographyDatabase generateIdentityKey];
    [SharedCryptographyDatabase generatePersonalPrekeys];

    // Send new prekeys to network
    [[TSNetworkManager sharedManager] queueAuthenticatedRequest:[[TSRegisterPrekeys alloc] initWithPrekeyArray:[SharedCryptographyDatabase getPersonalPrekeys] identityKey:[SharedCryptographyDatabase getIdentityKey]] success:^(AFHTTPRequestOperation *operation, id responseObject) {
        
        switch (operation.response.statusCode) {
            case 200:
                DLog(@"Device registered prekeys");
                break;
                
            default:
                DLog(@"response %d, %@",operation.response.statusCode,operation.response.description);
#warning Add error handling if not able to send the prekeys
                break;
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
#warning Add error handling if not able to send the token
        DLog(@"failure %d, %@",operation.response.statusCode,operation.response.description);
    }];
    
    // 4. Success
    // Store in the preferences that the DB has been successfully created
    [[NSUserDefaults standardUserDefaults] setBool:TRUE forKey:kDBWasCreatedBool];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    return SharedCryptographyDatabase;
}


+(instancetype) databaseUnlockWithPassword:(NSString *)userPassword error:(NSError **)error {
    
    // DB is already unlocked
    if ((SharedCryptographyDatabase) && (![SharedCryptographyDatabase isLocked])) {
        return SharedCryptographyDatabase;
    }
    
    // Make sure a DB has already been created
    if (![TSEncryptedDatabase databaseWasCreated]) {
        if (error) {
            NSMutableDictionary *errorDetail = [NSMutableDictionary dictionary];
            [errorDetail setValue:@"no DB available" forKey:NSLocalizedDescriptionKey];
            // TODO: Define error codes
            *error = [NSError errorWithDomain:@"textSecure" code:103 userInfo:errorDetail];
        }
        return nil;
    }
    
    // Get the DB master key
    NSData *key = [TSEncryptedDatabase getDatabaseMasterKeyWithPassword:userPassword error:error];
    if(key == nil) {
        return nil;
    }
    
    // Try to open the DB
    __block BOOL initSuccess = NO;
    FMDatabaseQueue *dbQueue = [FMDatabaseQueue databaseQueueWithPath:[FilePath pathInDocumentsDirectory:databaseFileName]];
    [dbQueue inDatabase:^(FMDatabase *db) {
        
        if(![db setKeyWithData:key]) {
            // Supplied password was valid but the master key wasn't !?
            return;
        }
        
        // Do a test query to make sure the DB is available
        FMResultSet *rset = [db executeQuery:@"SELECT * FROM persistent_settings"];
        if (rset) {
            [rset close];
            initSuccess = YES;
        }
    }];
    if (!initSuccess) {
        @throw [NSException exceptionWithName:@"DB unlock failed" reason:@"DB was corrupted" userInfo:nil];
        return nil;
    }
    
    // Initialize the DB singleton
    if (!SharedCryptographyDatabase) {
        // First time in the app's lifecycle we're unlocking the DB
        SharedCryptographyDatabase = [[TSEncryptedDatabase alloc] initWithDatabaseQueue:dbQueue];
    }
    else {
        // DB had already been instantiated but was locked
        SharedCryptographyDatabase.dbQueue = dbQueue;
    }
    
    return SharedCryptographyDatabase;
}


+(BOOL) databaseWasCreated {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDBWasCreatedBool];
}



-(BOOL) isLocked {
    if ((!SharedCryptographyDatabase) || (!SharedCryptographyDatabase.dbQueue) ) {
        return YES;
    }
    return NO;
}


#pragma mark DB Master Key Private Methods


+(NSData*) generateDatabaseMasterKeyWithPassword:(NSString*) userPassword {
    NSData *dbMasterKey = [Cryptography generateRandomBytes:36];
    NSData *encryptedDbMasterKey = [RNEncryptor encryptData:dbMasterKey withSettings:kRNCryptorAES256Settings password:userPassword error:nil];
    
    if(!encryptedDbMasterKey) {
        @throw [NSException exceptionWithName:@"DB creation failed" reason:@"could not generate a master key" userInfo:nil];
    }
    
    [KeychainWrapper createKeychainValue:[encryptedDbMasterKey base64EncodedString] forIdentifier:encryptedMasterSecretKeyStorageId];
    return dbMasterKey;
}


+ (NSData*) getDatabaseMasterKeyWithPassword:(NSString*) userPassword error:(NSError**) error {
#warning TODO: verify the settings of RNCryptor to assert that what is going on in encryption/decryption is exactly what we want
    NSString *encryptedDbMasterKey = [KeychainWrapper keychainStringFromMatchingIdentifier:encryptedMasterSecretKeyStorageId];
    if (!encryptedDbMasterKey) {
        @throw [NSException exceptionWithName:@"keychain corrupted" reason:@"could not retrieve DB master key from the keychain" userInfo:nil];
    }
    
    NSData *dbMasterKey = [RNDecryptor decryptData:[NSData dataFromBase64String:encryptedDbMasterKey] withPassword:userPassword error:error];
    return dbMasterKey;
}


+(void) eraseDatabaseMasterKey {
    [KeychainWrapper deleteItemFromKeychainWithIdentifier:encryptedMasterSecretKeyStorageId];
}


#pragma mark DB Creation Private Methods

-(instancetype) initWithDatabaseQueue:(FMDatabaseQueue *)queue {
    if (self = [super init]) {
        self.dbQueue = queue;
    }
    return self;
}


-(void) generateIdentityKey {
    /*
     An identity key is an ECC key pair that you generate at install time. It never changes, and is used to certify your identity (clients remember it whenever they see it communicated from other clients and ensure that it's always the same).
     
     In secure protocols, identity keys generally never actually encrypt anything, so it doesn't affect previous confidentiality if they are compromised. The typical relationship is that you have a long term identity key pair which is used to sign ephemeral keys (like the prekeys).
     */
    
    // No need to the check if the DB is locked as this happens during DB creation
    ECKeyPair *identityKey = [ECKeyPair createAndGeneratePublicPrivatePair:-1];
    
    [self.dbQueue inDatabase:^(FMDatabase *db) {
        BOOL updateResult = NO;
        
        updateResult = [db executeUpdate:@"INSERT OR REPLACE INTO persistent_settings (setting_name,setting_value) VALUES (?, ?)",@"identity_key_private",[identityKey privateKey]];
        if (updateResult == NO) {
            NSLog(@"Error updating DB: %@", [db lastErrorMessage]);
        }
        updateResult = [db executeUpdate:@"INSERT OR REPLACE INTO persistent_settings (setting_name,setting_value) VALUES (?, ?)",@"identity_key_public",[identityKey publicKey]];
        if (updateResult == NO) {
            NSLog(@"Error updating DB: %@", [db lastErrorMessage]);
        }
    }];
}


-(void) generatePersonalPrekeys {
    
    // No need to the check if the DB is locked as this happens during DB creation
    // TODO: Error checking
    int numberOfPreKeys = 70;
    int prekeyCounter = arc4random() % 16777215; // 16777215 is 0xFFFFFF
    
    // Generate keys
    for(int i=0; i<numberOfPreKeys; i++) {
        ECKeyPair *keyPair = [ECKeyPair createAndGeneratePublicPrivatePair:++prekeyCounter];
        [self.dbQueue inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"INSERT OR REPLACE INTO personal_prekeys (prekey_id,public_key,private_key,last_counter) VALUES (?,?,?,?)",[NSNumber numberWithInt:[keyPair prekeyId]], [keyPair publicKey], [keyPair privateKey],[NSNumber numberWithInt:0]];
        }];
    }
}


#pragma mark Keys Fetching Methods

-(NSArray*) getPersonalPrekeys {
    
    // TODO: Error handling
    if ([SharedCryptographyDatabase isLocked]) {
        @throw [NSException exceptionWithName:@"DB is locked" reason:@"database must be unlocked or created prior to being able to use this method" userInfo:nil];
    }
    
  NSMutableArray *prekeyArray = [[NSMutableArray alloc] init];
  [self.dbQueue inDatabase:^(FMDatabase *db) {
    FMResultSet  *rs = [db executeQuery:[NSString stringWithFormat:@"SELECT * FROM personal_prekeys"]];
    while([rs next]) {
      ECKeyPair *keyPair = [[ECKeyPair alloc] initWithPublicKey:[rs stringForColumn:@"public_key"]
                                                     privateKey:[rs stringForColumn:@"private_key"]
                                                       prekeyId:[rs intForColumn:@"prekey_id"]];
      [prekeyArray addObject:keyPair];
    }
  }];
  return prekeyArray;
}


-(ECKeyPair*) getIdentityKey {
    
    // TODO: Error handling
    if ([SharedCryptographyDatabase isLocked]) {
        @throw [NSException exceptionWithName:@"DB is locked" reason:@"database must be unlocked or created prior to being able to use this method" userInfo:nil];
    }
    
  __block NSString* identityKeyPrivate = nil;
  __block NSString* identityKeyPublic = nil;
  [self.dbQueue inDatabase:^(FMDatabase *db) {
    FMResultSet  *rs = [db executeQuery:[NSString stringWithFormat:@"SELECT setting_value FROM persistent_settings WHERE setting_name=\"identity_key_public\""]];
    if([rs next]){
      identityKeyPublic = [rs stringForColumn:@"setting_value"];
    }
    [rs close];
    rs = [db executeQuery:[NSString stringWithFormat:@"SELECT setting_value FROM persistent_settings WHERE setting_name=\"identity_key_private\""]];

    if([rs next]){
      identityKeyPrivate = [rs stringForColumn:@"setting_value"];
    }
    [rs close];
  }];
  if(identityKeyPrivate==nil || identityKeyPublic==nil) {
    return nil;
  }
  else {
    return [[ECKeyPair alloc] initWithPublicKey:identityKeyPublic privateKey:identityKeyPrivate];
  }
}

@end
