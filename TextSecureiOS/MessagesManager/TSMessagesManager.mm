//
//  MessagesManager.m
//  TextSecureiOS
//
//  Created by Frederic Jacobs on 30/11/13.
//  Copyright (c) 2013 Open Whisper Systems. All rights reserved.
//

#import "TSMessagesManager.h"
#import "TSAxolotlRatchet.hh"
#import "TSMessage.h"
#import "NSData+Base64.h"
#import "TSSubmitMessageRequest.h"
#import "TSMessagesDatabase.h"
@implementation TSMessagesManager


+ (id)sharedManager {
    static TSMessagesManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] init];
    });
    return sharedMyManager;
}

- (id)init {
    if (self = [super init]) {
        
    }
    return self;
}

- (void)receiveMessagePush:(NSDictionary *)pushInfo{
  [TSAxolotlRatchet processIncomingMessage:[NSData  dataFromBase64String:[pushInfo objectForKey:@"m"]]];

}

-(void) sendMessage:(TSMessage*)message onThread:(TSThread*)thread ofType:(TSWhisperMessageType) messageType{
  [TSAxolotlRatchet processOutgoingMessage:message onThread:thread ofType:messageType];
  
}


-(void) submitMessageTo:(NSString*)recipientId message:(NSString*)serializedMessage ofType:(TSWhisperMessageType)messageType {
  
  [[TSNetworkManager sharedManager] queueAuthenticatedRequest:[[TSSubmitMessageRequest alloc] initWithRecipient:recipientId message:serializedMessage ofType:messageType] success:^(AFHTTPRequestOperation *operation, id responseObject) {
    
    switch (operation.response.statusCode) {
      case 200:
        DLog(@"we have some success information %@",responseObject);
        // So let's encrypt a message using this
        break;
        
      default:
        DLog(@"error sending message");
#warning Add error handling if not able to get contacts prekey
        break;
    }
  } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
#warning right now it is not succesfully processing returned response, but is giving 200
    DLog(@"failure %d, %@, %@",operation.response.statusCode,operation.response.description,[[NSString alloc] initWithData:operation.responseData encoding:NSUTF8StringEncoding]);
    [[NSNotificationCenter defaultCenter] postNotificationName:TSDatabaseDidUpdateNotification object:nil userInfo:@{@"messageType":@"send"}];
    
  }];
  
}


@end
