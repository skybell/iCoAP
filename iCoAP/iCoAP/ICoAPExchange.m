//
//  ICoAPExchange.m
//  iCoAP
//
//  Created by Wojtek Kordylewski on 25.06.13.


#import "ICoAPExchange.h"
#import "NSString+hex.h"
#import <CommonCrypto/CommonCryptor.h>

@interface ICoAPExchange ()
- (BOOL)setupUdpSocket;
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext;
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error;
- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error;
- (void)noResponseExpected;
- (void)sendDidReceiveMessageToDelegateWithCoAPMessage:(ICoAPMessage *)coapMessage;
- (void)sendDidRetransmitMessageToDelegateWithCoAPMessage:(ICoAPMessage *)coapMessage;
- (void)sendFailWithErrorToDelegateWithError:(NSError *)error;
- (void)handleBlock2OptionForCoapMessage:(ICoAPMessage *)cO;
- (NSMutableData *)getHexDataFromString:(NSString *)string;
- (void)sendCircumstantialResponseWithMessageID:(NSUInteger)messageID type:(ICoAPType)type toAddress:(NSData *)address;
- (void)startSending;
- (void)performTransmissionCycle;
- (void)sendCoAPMessage;
- (void)resetState;
- (void)sendHttpMessageFromCoAPMessage:(ICoAPMessage *)coapMessage;
- (NSString *)getHttpHeaderFieldForCoAPOptionDelta:(NSUInteger)delta;
- (NSString *)getHttpMethodForCoAPMessageCode:(NSUInteger)code;
- (ICoAPType)getCoapTypeForString:(NSString *)typeString;
@end

@implementation ICoAPExchange

#pragma mark - Init

- (id)init {
    if (self = [super init]) {
        randomMessageId = 1 + arc4random() % 65536;
        randomToken = 1 + arc4random() % INT_MAX;
        
        supportedOptions =  [NSArray arrayWithObjects:
                            [NSNumber numberWithInt: IC_IF_MATCH],
                            [NSNumber numberWithInt: IC_URI_HOST],
                            [NSNumber numberWithInt: IC_ETAG],
                            [NSNumber numberWithInt: IC_IF_NONE_MATCH],
                            [NSNumber numberWithInt: IC_OBSERVE],
                            [NSNumber numberWithInt: IC_URI_PORT],
                            [NSNumber numberWithInt: IC_LOCATION_PATH],
                            [NSNumber numberWithInt: IC_URI_PATH],
                            [NSNumber numberWithInt: IC_CONTENT_FORMAT],
                            [NSNumber numberWithInt: IC_MAX_AGE],
                            [NSNumber numberWithInt: IC_URI_QUERY],
                            [NSNumber numberWithInt: IC_ACCEPT],
                            [NSNumber numberWithInt: IC_LOCATION_QUERY],
                            [NSNumber numberWithInt: IC_BLOCK2],
                            [NSNumber numberWithInt: IC_BLOCK1],
                            [NSNumber numberWithInt: IC_SIZE2],
                            [NSNumber numberWithInt: IC_PROXY_URI],
                            [NSNumber numberWithInt: IC_PROXY_SCHEME],
                            [NSNumber numberWithInt: IC_SIZE1],
                            [NSNumber numberWithInt: IC_INTROSPECTION],
                            nil];
    }
    return self;
}

- (id)initAndSendRequestWithCoAPMessage:(ICoAPMessage *)cO toHost:(NSString* )host port:(uint)port delegate:(id)delegate {
    if (self = [self init]) {
        self.delegate = delegate;
        [self sendRequestWithCoAPMessage:cO toHost:host port:port];
    }
    return self;
}

- (BOOL)setupUdpSocket {
    self.udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    
    NSError *error;
    if (![self.udpSocket bindToPort:self.udpPort error:&error]) {
        return NO;
    }
    
    if (![self.udpSocket beginReceiving:&error]) {
        [self.udpSocket close];
        return NO;
    }
    return YES;
}

#pragma mark - Decode Message

- (ICoAPMessage *)decodeCoAPMessageFromData:(NSData *)data {
    NSString *hexString = [NSString stringFromDataWithHex:data];
    NSRange hexStringRange = NSMakeRange(0, [hexString length]);
    
    //Check if header exists:
    if ([hexString length] < 8) {
        return nil;
    }
    
    ICoAPMessage *cO = [[ICoAPMessage alloc] init];
    
    cO.isRequest = NO;
    
    //Check Version and type (first 4 bits)
    cO.type = strtol([[hexString substringWithRange:NSMakeRange(0, 1)] UTF8String], NULL, 16);

//    if (IC_CONFIRMABLE < cO.type > IC_RESET) {
//        return nil;
//    }

    // i have no clue what is going on with the above conditional. here, i have
    // assumed that it is merely a check to make sure the value is valid.
    if (cO.type < IC_CONFIRMABLE || cO.type > IC_RESET)
    {
        return nil;
    }

#define RETURN_IF_RANGE_INVALID(range) { \
    if (NSMaxRange(range) > NSMaxRange(hexStringRange)) \
    { \
        return nil; \
    } \
}

    //Check Token length and save it.

    NSRange tokenLengthRange = NSMakeRange(1, 1);
    RETURN_IF_RANGE_INVALID(tokenLengthRange);
    NSUInteger tokenLength = strtol([[hexString substringWithRange: tokenLengthRange] UTF8String], NULL, 16); // in Bytes

    NSRange tokenValueRange = NSMakeRange(8, tokenLength * 2);
    RETURN_IF_RANGE_INVALID(tokenValueRange);
    cO.token = strtol([[hexString substringWithRange: tokenValueRange] UTF8String], NULL, 16);
    
    //Code
    NSRange codeRange = NSMakeRange(2, 2);
    RETURN_IF_RANGE_INVALID(codeRange);
    cO.code = strtol([[hexString substringWithRange: codeRange] UTF8String], NULL, 16);
     
    //Message ID
    NSRange messageIDRange = NSMakeRange(4, 4);
    RETURN_IF_RANGE_INVALID(messageIDRange);
    cO.messageID = strtol([[hexString substringWithRange: messageIDRange] UTF8String], NULL, 16);
    
    //Options && Payload
    NSInteger optionIndex = 8 + (tokenLength * 2);
    NSInteger payloadStartIndex = optionIndex;
    uint prevOptionDelta = 0;
    
    
    //Check if Options and More exists
    BOOL isOptionLoopRunning = YES;
    
    while (isOptionLoopRunning) {
        if (optionIndex + 2 < [hexString length]) {
            NSRange optionDeltaRange = NSMakeRange(optionIndex, 1);
            RETURN_IF_RANGE_INVALID(optionDeltaRange);
            NSUInteger optionDelta = strtol([[hexString substringWithRange: optionDeltaRange] UTF8String], NULL, 16);

            NSRange optionLengthRange = NSMakeRange(optionIndex + 1, 1);
            RETURN_IF_RANGE_INVALID(optionLengthRange);
            NSUInteger optionLength = strtol([[hexString substringWithRange: optionLengthRange] UTF8String], NULL, 16);
            
            if (optionDelta == kOptionDeltaPayloadIndicator) {
                //Payload should follow instead of Option_length. Verifying...
                if (optionLength != kOptionDeltaPayloadIndicator) {
                    return nil;
                }
                isOptionLoopRunning = NO;
                payloadStartIndex = optionIndex;
                continue;
            }
            
            NSUInteger extendedDelta = 0;
            int optionIndexOffset = 2; //marks the range between the beginning of the initial option byte and the end of the 'option delta' plus 'option lenght' extended bytes in hex steps (2 = 1 byte)
            
            if (optionDelta == k8bitIntForOption) {
                optionIndexOffset += 2;
            }
            else if (optionDelta == k16bitIntForOption) {
                optionIndexOffset += 4;
            }
            
            if (optionIndex + optionIndexOffset <= [hexString length]) {
                NSRange extendedDeltaRange = NSMakeRange(optionIndex + 2, optionIndexOffset - 2);
                RETURN_IF_RANGE_INVALID(extendedDeltaRange);
                extendedDelta = strtol([[hexString substringWithRange: extendedDeltaRange] UTF8String], NULL, 16);
            }
            else {
                return nil;
            }
            
            //Verify Length
            int optionLengthExtendedOffsetIndex = optionIndexOffset;
            if (optionLength == k8bitIntForOption) {
                optionIndexOffset += 2;
            }
            else if (optionLength == k16bitIntForOption) {
                optionIndexOffset += 4;
            }
            else if (optionLength == kOptionDeltaPayloadIndicator) {
                return nil;
            }

            NSRange secondOptionLengthRange = NSMakeRange(optionIndex + optionLengthExtendedOffsetIndex , optionIndexOffset - optionLengthExtendedOffsetIndex);
            RETURN_IF_RANGE_INVALID(secondOptionLengthRange);
            optionLength += strtol([[hexString substringWithRange: secondOptionLengthRange] UTF8String], NULL, 16);

            
            if (optionIndex + optionIndexOffset + optionLength * 2 > [hexString length]) {
                return nil;
            }
            
            NSUInteger newOptionNumber = optionDelta + extendedDelta + prevOptionDelta;
            NSString *optVal;            
            
            if (newOptionNumber == IC_ETAG || newOptionNumber == IC_IF_MATCH) {
                NSRange optionValueRange = NSMakeRange(optionIndex + optionIndexOffset, optionLength * 2);
                RETURN_IF_RANGE_INVALID(optionValueRange);
                optVal = [hexString substringWithRange: optionValueRange];
            }
            else if (newOptionNumber == IC_BLOCK2 || newOptionNumber == IC_URI_PORT || newOptionNumber == IC_CONTENT_FORMAT || newOptionNumber == IC_MAX_AGE || newOptionNumber == IC_ACCEPT || newOptionNumber == IC_SIZE1 || newOptionNumber == IC_SIZE2 || newOptionNumber == IC_OBSERVE) {
                NSRange optionValueRange = NSMakeRange(optionIndex + optionIndexOffset, optionLength * 2);
                RETURN_IF_RANGE_INVALID(optionValueRange);
                optVal = [NSString stringWithFormat:@"%i", (int)strtol([[hexString substringWithRange: optionValueRange] UTF8String], NULL, 16)];
            }
            else {
                NSRange optionValueRange = NSMakeRange(optionIndex + optionIndexOffset, optionLength * 2);
                RETURN_IF_RANGE_INVALID(optionValueRange);
                optVal = [NSString stringFromHexString:[[hexString substringWithRange: optionValueRange] stringByRemovingPercentEncoding]];
            }
            
            [cO addOption:newOptionNumber withValue:optVal];
            
            prevOptionDelta += optionDelta + extendedDelta;
            optionIndex += optionIndexOffset + optionLength * 2;
        }
        else {
            isOptionLoopRunning = NO;
            payloadStartIndex = optionIndex;
        }
    }
    
    //Payload, first check if payloadmarker exists
    if (payloadStartIndex + 2 < [hexString length]) {
        cO.payload = [self requiresPayloadStringDecodeForCoAPMessage:cO] ? [[NSString stringFromHexString:[hexString substringFromIndex:payloadStartIndex + 2]] stringByRemovingPercentEncoding] : [hexString substringFromIndex:payloadStartIndex + 2];

        if (!cO.payload) {
            cO.payload = [NSString stringFromHexString:[hexString substringFromIndex:payloadStartIndex + 2]];
        }
    }
    return cO;

#undef RETURN_IF_RANGE_INVALID
}

#pragma mark - Encode Message

- (NSData *)encodeDataFromCoAPMessage:(ICoAPMessage *)cO {
    NSMutableString *final = [[NSMutableString alloc] init];
    NSString *tokenAsString = [NSString get0To4ByteHexStringFromInt:(int32_t)cO.token];
    NSString *message = [NSString stringWithFormat:@"%01lX%01lX%02lX%04lX%@", (unsigned long)cO.type, [tokenAsString length] / 2, (unsigned long)cO.code, (unsigned long)cO.messageID, tokenAsString];
    [final appendString: message];
    
    NSArray *sortedArray;
    sortedArray = [[cO.optionDict allKeys] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [a integerValue] > [b integerValue];
    }];
    
    NSUInteger previousDelta = 0;
    
    for (NSString* key in sortedArray) {
        NSMutableArray *valueArray = [cO.optionDict valueForKey:key];
        
        for (uint i = 0; i < [valueArray count]; i++) {
            NSUInteger delta = [key integerValue] - previousDelta;
            NSString *valueForKey;
            
            if ([key intValue] == IC_ETAG || [key intValue] == IC_IF_MATCH) {
                valueForKey = [valueArray objectAtIndex:i];
            }
            else if ([key intValue] == IC_BLOCK2 || [key intValue] == IC_URI_PORT || [key intValue] == IC_CONTENT_FORMAT || [key intValue] == IC_MAX_AGE || [key intValue] == IC_ACCEPT || [key intValue] == IC_SIZE1 || [key intValue] == IC_SIZE2) {
                valueForKey = [NSString get0To4ByteHexStringFromInt:[[valueArray objectAtIndex:i] intValue]];
            }
            else {
                valueForKey = [NSString hexStringFromString:[valueArray objectAtIndex:i]];
            }
            
            NSUInteger length = [valueForKey length] / 2;

            NSString *extendedDelta = @"";
            NSString *extendedLength = @"";
            
            if (delta >= 269) {
                [final appendString:[NSString stringWithFormat:@"%01X", 14]];
                extendedDelta = [NSString stringWithFormat:@"%04lX", delta - 269];
            }
            else if (delta >= 13) {
                [final appendString:[NSString stringWithFormat:@"%01X", 13]];
                extendedDelta = [NSString stringWithFormat:@"%02lX", delta - 13];
            }
            else {
                [final appendString:[NSString stringWithFormat:@"%01lX", delta]];
            }
            
            if (length >= 269) {
                [final appendString:[NSString stringWithFormat:@"%01X", 14]];
                extendedLength = [NSString stringWithFormat:@"%04lX", length - 269];
            }
            else if (length >= 13) {
                [final appendString:[NSString stringWithFormat:@"%01X", 13]];
                extendedLength = [NSString stringWithFormat:@"%02lX", length - 13];
            }
            else {
                [final appendString:[NSString stringWithFormat:@"%01lX", length]];
            }
            
            [final appendString:extendedDelta];
            [final appendString:extendedLength];
            [final appendString:valueForKey];

            previousDelta += delta;
        }

    }    
    
    //Payload encoded to UTF-8
    if ([cO.payload length] > 0) {
        if ([self requiresPayloadStringDecodeForCoAPMessage:cO]) {
            [final appendString:[NSString stringWithFormat:@"%02X%@", 255, [NSString hexStringFromString:cO.payload]]];
        }
        else {
            [final appendString:[NSString stringWithFormat:@"%02X%@", 255, cO.payload]];
        }
    }

    return [self getHexDataFromString:final];
}

#pragma mark - GCD Async UDP Socket Delegate

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data fromAddress:(NSData *)address withFilterContext:(id)filterContext {
    unsigned char *bytes = (unsigned char*)[data bytes];
    unsigned char firstByte = bytes[0];

    NSData *refinedData = data;

    if (firstByte == 130) {
        NSRange range = NSMakeRange(1, [data length] - 1);
        NSData *encData = [data subdataWithRange:range];
        NSString *initVector = @"4430305242334c4c4430305242333131";
        NSString *key        = @"386b794233314c4c386b794233313121";
        NSData *keyData      = [self getHexDataFromString:key];
        NSData *ivData       = [self getHexDataFromString:initVector];
        NSError *error;
        refinedData = [self doCipher:encData
                                  iv:ivData
                                 key:keyData
                             context:kCCDecrypt
                               error:&error];
    }

    ICoAPMessage *cO = [self decodeCoAPMessageFromData:refinedData];

    //Check if received data is a valid CoAP Message
    if (!cO) {
        return;
    }

    //Set Timestamp
    cO.timestamp = [[NSDate alloc] init];

    //Check for spam and if Observe is Cancelled
    if ((cO.messageID != pendingCoAPMessageInTransmission.messageID && cO.token != pendingCoAPMessageInTransmission.token) || ([cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]] && isObserveCancelled && cO.type != IC_ACKNOWLEDGMENT)) {
        if (cO.type <= IC_NON_CONFIRMABLE) {
            [self sendCircumstantialResponseWithMessageID:cO.messageID type:IC_RESET toAddress:address];
        }
        return;
    }
    
    //Invalidate Timers: Resend- and Max-Wait Timer
    if (cO.type == IC_ACKNOWLEDGMENT || cO.type == IC_RESET || cO.type == IC_NON_CONFIRMABLE) {
        [sendTimer invalidate];
        [maxWaitTimer invalidate];
    }

    if (!(cO.type == IC_ACKNOWLEDGMENT && cO.code == IC_EMPTY) && !([cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_BLOCK2]] && ![cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]])) {
        _isMessageInTransmission = NO;
    }
    
    //Separate Response / Observe: Send ACK
    if (cO.type == IC_CONFIRMABLE) {        
        [self sendCircumstantialResponseWithMessageID:cO.messageID type:IC_ACKNOWLEDGMENT toAddress:address];
    }
    
    //Block Options: Only send a Block2 request when observe option is inactive:
    if ([cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_BLOCK2]] && ![cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]]) {
        [self handleBlock2OptionForCoapMessage:cO];
    }
    
    //Check for Observe Option: If Observe Option is present, the message is only sent to the delegate if the order is correct.
    if ([cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]] && cO.type != IC_ACKNOWLEDGMENT) {
        uint currentObserveValue = [[[cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]] objectAtIndex:0] intValue];
       
        if (!recentNotificationDate) {
            recentNotificationDate = [[NSDate alloc] init];
        }
        
        recentNotificationDate = [recentNotificationDate dateByAddingTimeInterval:kMaxNotificationDelayTime];
        
        if ((observeOptionValue < currentObserveValue && currentObserveValue - observeOptionValue < kMaxObserveOptionValue) ||
            (observeOptionValue > currentObserveValue && observeOptionValue - currentObserveValue > kMaxObserveOptionValue) ||
            [recentNotificationDate compare:cO.timestamp] == NSOrderedAscending) {
            
            recentNotificationDate = cO.timestamp;
            observeOptionValue = currentObserveValue;
        }
        else {
            return;
        }
    }
    
    [self sendDidReceiveMessageToDelegateWithCoAPMessage:cO];
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didNotSendDataWithTag:(long)tag dueToError:(NSError *)error {
    [self closeExchange];
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"UDP Socket could not send data." forKey:NSLocalizedDescriptionKey];
    [self sendFailWithErrorToDelegateWithError:[[NSError alloc] initWithDomain:kiCoAPErrorDomain code:IC_UDP_SOCKET_ERROR userInfo:userInfo]];
}

- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)sock withError:(NSError *)error {
    [self closeExchange];
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"UDP Socket Closed" forKey:NSLocalizedDescriptionKey];
    [self sendFailWithErrorToDelegateWithError:[[NSError alloc] initWithDomain:kiCoAPErrorDomain code:IC_UDP_SOCKET_ERROR userInfo:userInfo]];
}

#pragma mark - Delegate Method Calls

- (void)noResponseExpected {
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"No Response expected for recently sent CoAP Message" forKey:NSLocalizedDescriptionKey];

    [self sendFailWithErrorToDelegateWithError:[[NSError alloc] initWithDomain:kiCoAPErrorDomain code:IC_RESPONSE_TIMEOUT userInfo:userInfo]];
    [self closeExchange];
}

- (void)sendDidReceiveMessageToDelegateWithCoAPMessage:(ICoAPMessage *)coapMessage {
    if ([self.delegate respondsToSelector:@selector(iCoAPExchange:didReceiveCoAPMessage:)]) {
        [self.delegate iCoAPExchange:self didReceiveCoAPMessage:coapMessage];
    }
}

- (void)sendDidRetransmitMessageToDelegateWithCoAPMessage:(ICoAPMessage *)coapMessage {
    if ([self.delegate respondsToSelector:@selector(iCoAPExchange:didRetransmitCoAPMessage:number:finalRetransmission:)]) {
        retransmissionCounter == kMAX_RETRANSMIT ?
        [self.delegate iCoAPExchange:self didRetransmitCoAPMessage:pendingCoAPMessageInTransmission number:retransmissionCounter finalRetransmission:YES] :
        [self.delegate iCoAPExchange:self didRetransmitCoAPMessage:pendingCoAPMessageInTransmission number:retransmissionCounter finalRetransmission:NO];
    }
}

- (void)sendFailWithErrorToDelegateWithError:(NSError *)error {
    if ([self.delegate respondsToSelector:@selector(iCoAPExchange:didFailWithError:)]) {
        [self.delegate iCoAPExchange:self didFailWithError:error];
    }
}

#pragma mark - Other Methods

- (void)handleBlock2OptionForCoapMessage:(ICoAPMessage *)cO {
    NSString *blockValue = [NSString stringWithFormat:@"%02X", [[[cO.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_BLOCK2]] objectAtIndex:0] intValue]];
    
    NSUInteger blockNum = strtol([[blockValue substringToIndex:[blockValue length] - 1] UTF8String], NULL, 16);
    NSUInteger blockTail = strtol([[blockValue substringFromIndex:[blockValue length] - 1] UTF8String], NULL, 16);
    
    if (blockTail > 7) {
        //More Flag is set
        ICoAPMessage *blockObject = [[ICoAPMessage alloc] init];
        blockObject.isRequest = YES;
        blockObject.type = IC_CONFIRMABLE;
        blockObject.code = pendingCoAPMessageInTransmission.code;
        blockObject.messageID = pendingCoAPMessageInTransmission.messageID + 1 % 65536;
        randomMessageId++;
        blockObject.token = pendingCoAPMessageInTransmission.token;
        blockObject.host = pendingCoAPMessageInTransmission.host;
        blockObject.port = pendingCoAPMessageInTransmission.port;
        blockObject.httpProxyHost = pendingCoAPMessageInTransmission.httpProxyHost;
        blockObject.httpProxyPort = pendingCoAPMessageInTransmission.httpProxyPort;
        blockObject.optionDict =  [[NSMutableDictionary alloc] init];
        for (id key in pendingCoAPMessageInTransmission.optionDict) {
            if (![key isEqualToString:[NSString stringWithFormat:@"%i", IC_BLOCK2]]) {
                [blockObject.optionDict setValue:[[NSMutableArray alloc] initWithArray:[pendingCoAPMessageInTransmission.optionDict valueForKey:key]] forKey:key];
            }
        }
        
        NSString *newBlockValue = [NSString stringWithFormat:@"%lu", (blockNum + 1) * 16 + blockTail - 8];
        [blockObject addOption:IC_BLOCK2 withValue:newBlockValue];
        
        pendingCoAPMessageInTransmission = blockObject;
        if (cO.usesHttpProxying) {
            [self sendHttpMessageFromCoAPMessage:pendingCoAPMessageInTransmission];
        }
        else {
            [self startSending];
        }
    }
    else {
        _isMessageInTransmission = NO;
    }
}

- (NSMutableData *)getHexDataFromString:(NSString *)string {
    NSMutableData *commandData= [[NSMutableData alloc] init];
    unsigned char byteRepresentation;
    char byte_chars[3] = {'\0','\0','\0'};
    
    for (int i = 0; i < (string.length / 2); i++) {
        byte_chars[0] = [string characterAtIndex:i * 2];
        byte_chars[1] = [string characterAtIndex:i * 2 + 1];
        byteRepresentation = strtol(byte_chars, NULL, 16);
        [commandData appendBytes:&byteRepresentation length:1];
    }

    return commandData;
}

- (void)cancelObserve {
    isObserveCancelled = YES;
}

- (NSData *)obfuscate:(NSData *)data withKey:(char)key
{
    NSMutableData *result = [data mutableCopy];


    // Get pointer to data to obfuscate
    char *dataPtr = (char *) [result mutableBytes];

    // For each character in data, xor with current value in key
    for (int x = 0; x < [data length]; x++)
    {
        dataPtr[x] = dataPtr[x] ^ key;
    }

    return result;
}

- (NSData *)doCipher:(NSData *)dataIn
                  iv:(NSData *)iv
                 key:(NSData *)symmetricKey
             context:(CCOperation)encryptOrDecrypt // kCCEncrypt or kCCDecrypt
               error:(NSError **)error
{
    CCCryptorStatus ccStatus   = kCCSuccess;
    size_t          cryptBytes = 0;
    NSMutableData  *dataOut    = [NSMutableData dataWithLength:dataIn.length + kCCBlockSizeAES128];

    ccStatus = CCCrypt( encryptOrDecrypt,
                       kCCAlgorithmAES128,
                       0, //kCCOptionPKCS7Padding,
                       symmetricKey.bytes,
                       kCCKeySizeAES128,
                       iv.bytes,
                       dataIn.bytes,
                       dataIn.length,
                       dataOut.mutableBytes,
                       dataOut.length,
                       &cryptBytes);

    if (ccStatus == kCCSuccess) {
        dataOut.length = cryptBytes;
    }
    else {
        if (error) {
            *error = [NSError errorWithDomain:@"kEncryptionError"
                                         code:ccStatus
                                     userInfo:nil];
        }
        dataOut = nil;
    }
    
    return dataOut;
}

- (NSData *)obfuscateAES:(NSData *)data withKey:(NSString *)key andInitVector:(NSString *) initVector {
    NSMutableData* wdata = [[NSMutableData alloc]initWithData:data];
    NSMutableData* result = [self getHexDataFromString:[NSString stringWithFormat:@"%01X", (128+2)]];
    NSData *keyData      = [self getHexDataFromString:key];
    NSData *ivData       = [self getHexDataFromString:initVector];

    NSError *error;

    int diff = kCCKeySizeAES128 - ([data length] % kCCKeySizeAES128);

    if (diff > 0) {
        unsigned char bytes[diff] ;
        for(int i=0;i<diff;i++)
            bytes[i] = 0;
        NSData *databytes = [[NSData alloc] initWithBytes:bytes length:diff];
        [wdata appendData:databytes];
    }

    NSData *current = [self doCipher:wdata
                                  iv:ivData
                                 key:keyData
                             context:kCCEncrypt
                               error:&error];

    [result appendData:current];

    return result;
}

#pragma mark - Send Methods

- (void)sendCircumstantialResponseWithMessageID:(NSUInteger)messageID type:(ICoAPType)type toAddress:(NSData *)address {
    ICoAPMessage *ackObject = [[ICoAPMessage alloc] init];
    ackObject.isRequest = NO;
    ackObject.type = type;
    ackObject.messageID = messageID;

    NSData *send = nil;

    if (self.isRequestLocal) {
        send = [self encodeDataFromCoAPMessage:ackObject];
    }
    else {
        send = [self obfuscate:[self encodeDataFromCoAPMessage:ackObject] withKey:(char)(64+43)];
    }

    [self.udpSocket sendData:send toAddress:address withTimeout:-1 tag:udpSocketTag];
    udpSocketTag++;
}

- (void)sendRequestWithCoAPMessage:(ICoAPMessage *)cO toHost:(NSString *)host port:(uint)port {
    randomMessageId++;
    randomToken++;
    
    cO.messageID = randomMessageId % 65536;
    
    if ([cO isTokenRequested]) {
        cO.token = randomToken % INT_MAX;
    }
    
    cO.isRequest = YES;
    cO.host = host;
    cO.port = port;
    pendingCoAPMessageInTransmission = cO;
    pendingCoAPMessageInTransmission.timestamp = [[NSDate alloc] init];

    if (cO.usesHttpProxying) {
        [self sendHttpMessageFromCoAPMessage:pendingCoAPMessageInTransmission];
    }
    else {
        if (!self.udpSocket && ![self setupUdpSocket]) {
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"Failed to setup UDP Socket" forKey:NSLocalizedDescriptionKey];
            
            [self sendFailWithErrorToDelegateWithError:[[NSError alloc] initWithDomain:kiCoAPErrorDomain code:IC_UDP_SOCKET_ERROR userInfo:userInfo]];
            return;
        }
        
        [self startSending];
    }
}

- (void)startSending {
    [self resetState];
    
    if (pendingCoAPMessageInTransmission.type == IC_CONFIRMABLE) {
        retransmissionCounter = 0;
        maxWaitTimer = [NSTimer scheduledTimerWithTimeInterval:kMAX_TRANSMIT_WAIT target:self selector:@selector(noResponseExpected) userInfo:nil repeats:NO];
        
        [self performTransmissionCycle];
    }
    else {
        [self sendCoAPMessage];
    }
}

- (void)performTransmissionCycle {
    [self sendCoAPMessage];
    if (retransmissionCounter != 0) {
        [self sendDidRetransmitMessageToDelegateWithCoAPMessage:pendingCoAPMessageInTransmission];
    }
    
    if (retransmissionCounter != kMAX_RETRANSMIT) {
        double timeout = kACK_TIMEOUT * pow(2.0, retransmissionCounter) * (kACK_RANDOM_FACTOR - fmodf((float)random()/RAND_MAX, 0.5));
        sendTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(performTransmissionCycle) userInfo:nil repeats:NO];
        retransmissionCounter++;
    }
}

- (void)sendCoAPMessage {
    NSData *send = [self encodeDataFromCoAPMessage:pendingCoAPMessageInTransmission];

    if (!self.isRequestLocal) {
        send = [self obfuscateAES:[self encodeDataFromCoAPMessage:pendingCoAPMessageInTransmission]
                          withKey:@"386b794233314c4c386b794233313121"
                    andInitVector:@"4430305242334c4c4430305242333131"];
    }

    [self.udpSocket sendData:send toHost:pendingCoAPMessageInTransmission.host port:pendingCoAPMessageInTransmission.port withTimeout:-1 tag:udpSocketTag];
    udpSocketTag++;
}

- (void)closeExchange {
    if (pendingCoAPMessageInTransmission.usesHttpProxying) {
        [task cancel];
    }
    else {
        self.udpSocket.delegate = nil;
        [self.udpSocket close];
        self.udpSocket = nil;
        [sendTimer invalidate];
        [maxWaitTimer invalidate];
    }
    
    recentNotificationDate = nil;
    pendingCoAPMessageInTransmission = nil;
    _isMessageInTransmission = NO;
}

- (void)resetState {
    [sendTimer invalidate];
    [maxWaitTimer invalidate];
    isObserveCancelled = NO;
    observeOptionValue = 0;
    recentNotificationDate = nil;
    _isMessageInTransmission = YES;
}

#pragma mark - HTTP Proxying

- (void)sendHttpMessageFromCoAPMessage:(ICoAPMessage *)coapMessage {
    [self resetState];
    NSString *urlString = [NSString stringWithFormat:@"http://%@:%lu/%@:%lu",coapMessage.httpProxyHost, (unsigned long)coapMessage.httpProxyPort, coapMessage.host, (unsigned long)coapMessage.port];
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:kMAX_TRANSMIT_WAIT];
    
    if (coapMessage.code != IC_GET) {
        [urlRequest setHTTPMethod:[self getHttpMethodForCoAPMessageCode:coapMessage.code]];
    }
    
    for (id key in coapMessage.optionDict) {
        NSMutableArray *values = [coapMessage.optionDict valueForKey:key];
        for (NSString *value in values) {
            [urlRequest addValue:value forHTTPHeaderField:[self getHttpHeaderFieldForCoAPOptionDelta:[key intValue]]];
        }
    }
    
    [urlRequest setHTTPBody:[coapMessage.payload dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:urlRequest
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
    {
        if (error) {
            [self closeExchange];
            NSDictionary *userInfo = [NSDictionary dictionaryWithObject:@"Proxying Failure." forKey:NSLocalizedDescriptionKey];
            [self sendFailWithErrorToDelegateWithError:[[NSError alloc] initWithDomain:kiCoAPErrorDomain code:IC_PROXYING_ERROR userInfo:userInfo]];
            return;
        }
        
        proxyCoAPMessage = [[ICoAPMessage alloc] init];
        proxyCoAPMessage.isRequest = NO;
        
        NSHTTPURLResponse *httpresponse = (NSHTTPURLResponse *)response;
        
        for (NSNumber *optNumber in supportedOptions) {
            NSString *optString = [self getHttpHeaderFieldForCoAPOptionDelta:[optNumber intValue]];
            
            if ([httpresponse.allHeaderFields objectForKey:[NSString stringWithFormat:@"HTTP_%@", optString]]) {
                NSString *valueString = [httpresponse.allHeaderFields objectForKey:[NSString stringWithFormat:@"HTTP_%@", optString]];
                NSArray *valueArray = [valueString componentsSeparatedByString:@","];
                
                [proxyCoAPMessage.optionDict setValue:[NSMutableArray arrayWithArray:valueArray] forKey:[optNumber stringValue]];
            }
        }
        
        proxyCoAPMessage.type = [self getCoapTypeForString:[httpresponse.allHeaderFields objectForKey:kProxyCoAPTypeIndicator]];
        proxyCoAPMessage.code = httpresponse.statusCode;
        proxyCoAPMessage.usesHttpProxying = YES;
        proxyCoAPMessage.payload = [self requiresPayloadStringDecodeForCoAPMessage:proxyCoAPMessage]
                                    ? [NSString stringFromHexString:[NSString stringFromDataWithHex:data]]
                                    : [NSString stringFromDataWithHex:data];
        proxyCoAPMessage.timestamp = [[NSDate alloc] init];
        
        if ([proxyCoAPMessage.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_BLOCK2]] && ![proxyCoAPMessage.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_OBSERVE]]) {
            [self handleBlock2OptionForCoapMessage:proxyCoAPMessage];
        }
        else {
            _isMessageInTransmission = NO;
        }
        
        [self sendDidReceiveMessageToDelegateWithCoAPMessage:proxyCoAPMessage];
    }];
    [task resume];
}

#pragma mark - Mapping Methods for Proxying

- (NSString *)getHttpHeaderFieldForCoAPOptionDelta:(NSUInteger)delta {
    switch (delta) {
        case IC_IF_MATCH:
            return @"IF_MATCH";
        case IC_URI_HOST:
            return @"URI_HOST";
        case IC_ETAG:
            return @"ETAG";
        case IC_IF_NONE_MATCH:
            return @"IF_NONE_MATCH";
        case IC_URI_PORT:
            return @"URI_PORT";
        case IC_LOCATION_PATH:
            return @"LOCATION_PATH";
        case IC_URI_PATH:
            return @"URI_PATH";
        case IC_CONTENT_FORMAT:
            return @"CONTENT_FORMAT";
        case IC_MAX_AGE:
            return @"MAX_AGE";
        case IC_URI_QUERY:
            return @"URI_QUERY";
        case IC_ACCEPT:
            return @"ACCEPT";
        case IC_LOCATION_QUERY:
            return @"LOCATION_QUERY";
        case IC_PROXY_URI:
            return  @"PROXY_URI";
        case IC_PROXY_SCHEME:
            return @"PROXY_SCHEME";
        case IC_BLOCK2:
            return @"BLOCK2";
        case IC_BLOCK1:
            return @"BLOCK1";
        case IC_OBSERVE:
            return @"OBSERVE";
        case IC_SIZE1:
            return @"SIZE1";
        case IC_SIZE2:
            return @"SIZE2";
        case IC_INTROSPECTION:
            return @"INSTROSPECTION";
        default:
            return nil;
    }
}

- (NSString *)getHttpMethodForCoAPMessageCode:(NSUInteger)code {
    switch (code) {
        case IC_POST:
            return @"POST";
        case IC_PUT:
            return @"PUT";
        case IC_DELETE:
            return @"DELETE";
        default:
            return @"GET";
    }
}

- (ICoAPType)getCoapTypeForString:(NSString *)typeString {
    if ([typeString isEqualToString:@"CON"]) {
        return IC_CONFIRMABLE;
    }
    else if ([typeString isEqualToString:@"NON"]) {
        return IC_NON_CONFIRMABLE;
    }
    else if ([typeString isEqualToString:@"RES"]) {
        return IC_RESET;
    }
    else {
        return IC_ACKNOWLEDGMENT;
    }
}

- (BOOL)requiresPayloadStringDecodeForCoAPMessage:(ICoAPMessage *)coapMessage {
    if (![coapMessage.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_CONTENT_FORMAT]]) {
        return YES;
    }
    else if ([coapMessage.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_CONTENT_FORMAT]]) {
        NSMutableArray *values = [coapMessage.optionDict valueForKey:[NSString stringWithFormat:@"%i", IC_CONTENT_FORMAT]];
        if ([[values objectAtIndex:0] intValue] == IC_PLAIN || [[values objectAtIndex:0] intValue] == IC_LINK_FORMAT || [[values objectAtIndex:0] intValue] == IC_XML || [[values objectAtIndex:0] intValue] == IC_JSON) {
            return YES;
        }
    }
    return NO;
}

@end
