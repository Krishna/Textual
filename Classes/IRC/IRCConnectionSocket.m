/* *********************************************************************
                  _____         _               _
                 |_   _|____  _| |_ _   _  __ _| |
                   | |/ _ \ \/ / __| | | |/ _` | |
                   | |  __/>  <| |_| |_| | (_| | |
                   |_|\___/_/\_\\__|\__,_|\__,_|_|

 Copyright (c) 2008 - 2010 Satoshi Nakagawa <psychs AT limechat DOT net>
 Copyright (c) 2010 - 2015 Codeux Software, LLC & respective contributors.
        Please see Acknowledgements.pdf for additional information.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Textual and/or "Codeux Software, LLC", nor the 
      names of its contributors may be used to endorse or promote products 
      derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 SUCH DAMAGE.

 *********************************************************************** */

#import "TextualApplication.h"

#import "IRCConnectionPrivate.h"

@implementation IRCConnection (IRCConnectionSocket)

#pragma mark -
#pragma mark Grand Centeral Dispatch

- (void)destroyDispatchQueue
{
	self.dispatchQueue = NULL;

	self.socketQueue = NULL;
}

- (void)createDispatchQueue
{
	NSString *dispatchID = [NSString stringWithUUID];

	// A socket queue exists regardless of what library is in use.
	// This class reads on data on this queue just so the work is not passed to the main thread.
	NSString *dqname = [@"socketDispatchQueue." stringByAppendingString:dispatchID];

	self.dispatchQueue = dispatch_queue_create([dqname UTF8String], DISPATCH_QUEUE_SERIAL);

	// Create secondary queue incase we are using GCDAsyncSocket
	NSString *sqname = [@"socketReadWriteQueue." stringByAppendingString:dispatchID];

	self.socketQueue = dispatch_queue_create([sqname UTF8String], DISPATCH_QUEUE_SERIAL);
}

#pragma mark -
#pragma mark Open/Close Socket

- (void)openSocket
{
    [self createDispatchQueue];

	self.lastDisconnectWasErroneous = NO;
	
	self.isConnecting = YES;

	self.socketConnection = [GCDAsyncSocket socketWithDelegate:self
												 delegateQueue:self.dispatchQueue
												   socketQueue:self.socketQueue];

	[self.socketConnection setIPv4PreferredOverIPv6:(self.connectionPrefersIPv6 == NO)];

	NSError *connError = nil;

	if ([self.socketConnection connectToHost:self.serverAddress
									  onPort:self.serverPort
								 withTimeout:(-1)
									   error:&connError] == NO)
	{
		[self socketDidDisconnect:self.socketConnection withError:connError];
	}
}

- (void)tearDownQueuedCertificateTrustDialog
{
	[[TXSharedApplication sharedQueuedCertificateTrustPanel] dequeueEntryForSocket:self.socketConnection];
}

- (void)closeSocket
{
	if ( self.socketConnection) {
		[self.socketConnection disconnect];
	}
}

- (void)destroySocket
{
	[self tearDownQueuedCertificateTrustDialog];

	if ( self.socketConnection) {
		[self.socketConnection setDelegate:nil];
		 self.socketConnection = nil;
	}

	[self destroyDispatchQueue];
	
	self.isConnectedWithClientSideCertificate = NO;
	
	self.isConnected = NO;
	self.isConnecting = NO;
}

#pragma mark -
#pragma mark Socket Read & Write

- (NSData *)readLine:(NSMutableData * __autoreleasing *)refString
{
	NSObjectIsEmptyAssertReturn(*refString, nil);
	
	NSInteger messageSubstringIndex = 0;
	NSInteger messageDeleteIndex = 0;

	NSRange _LFRange = [*refString rangeOfData:[NSData lineFeed] options:0 range:NSMakeRange(0, [*refString length])];
	NSRange _CRRange = [*refString rangeOfData:[NSData carriageReturn] options:0 range:NSMakeRange(0, [*refString length])];

	if (_LFRange.location == NSNotFound) {
		/* If we do not have any line end for this fragment and the refString is not
		 empty, then we save the remaining fragment for processing once we have more
		 information. */

		NSObjectIsEmptyAssertReturn(*refString, nil);

		self.bufferOverflowString = *refString;
	
		return nil;
	}

	messageSubstringIndex = _LFRange.location;
	messageDeleteIndex = (_LFRange.location + 1);

	if ((_LFRange.location - 1) == _CRRange.location) {
		messageSubstringIndex -= 1;
	}
	
	NSData *readLine = [*refString subdataWithRange:NSMakeRange(0, messageSubstringIndex)];

	[*refString replaceBytesInRange:NSMakeRange(0, messageDeleteIndex) withBytes:NULL length:0];

	return readLine;
}

- (void)write:(NSData *)data
{
	if (self.isConnected) {
		[self.socketConnection writeData:data withTimeout:(-1) tag:0];

		[self.socketConnection readDataWithTimeout:(-1)	tag:0];
	}
}

#pragma mark -
#pragma mark Primary Socket Delegate

- (NSArray *)clientSideCertificateForAuthentication
{
	NSData *localCertData = [[[self associatedClient] config] identityClientSideCertificate];

	id returnValue = nil;

	if (localCertData) {
		SecKeychainItemRef cert;

		CFDataRef rawCertData = (__bridge CFDataRef)(localCertData);

		OSStatus status = SecKeychainItemCopyFromPersistentReference(rawCertData, &cert);

		if (status == noErr) {
			SecIdentityRef identity;

			status = SecIdentityCreateWithCertificate(NULL, (SecCertificateRef)cert, &identity);

			if (status == noErr) {
				returnValue = @[(__bridge id)identity, (__bridge id)cert];

				CFRelease(identity);
			} else {
				LogToConsole(@"User supplied client-side certificate produced an error trying to read it: %i (#2)", status);
			}

			CFRelease(cert);
		}else {
			LogToConsole(@"User supplied client-side certificate produced an error trying to read it: %i (#1)", status);
		}
	}

	return returnValue;
}

- (NSString *)connectedAddress
{
	return [self.socketConnection connectedHost];
}

- (BOOL)onSocketWillConnect:(id)sock
{
	if (self.proxyType == IRCConnectionSocketSystemSocksProxyType) {
		[self.socketConnection useSystemSocksProxy];
	} else if (self.proxyType == IRCConnectionSocketSocks4ProxyType ||
			   self.proxyType == IRCConnectionSocketSocks5ProxyType)
	{
		[self.socketConnection useSocksProxyVersion:self.proxyType
											address:self.proxyAddress
											   port:self.proxyPort
										   username:self.proxyUsername
										   password:self.proxyPassword];
	}

	if (self.connectionPrefersSecuredConnection) {
		NSArray *localCertData = [self clientSideCertificateForAuthentication];

		[self.socketConnection useSSLWithHost:self.serverAddress clientSideCertificate:localCertData];
	}

	return YES;
}

- (void)socket:(id)sock didReceiveTrust:(SecTrustRef)trust completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
	if (self.connectionShouldValidateCertificateChain == NO) {
		completionHandler(YES);
	} else {
		SecTrustResultType result;
		
		OSStatus trustEvalStatus = SecTrustEvaluate(trust, &result);
		
		if (trustEvalStatus == errSecSuccess)
		{
			if (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed) {
				completionHandler(YES);
			} else if (result == kSecTrustResultRecoverableTrustFailure) {
				[[TXSharedApplication sharedQueuedCertificateTrustPanel] enqueue:trust withCompletionBlock:completionHandler forSocket:self.socketConnection];
			} else {
				completionHandler(NO);
			}
		}
		else
		{
			completionHandler(NO);
		}
	}
}
	
- (void)onSocket:(id)sock didConnectToHost:(NSString *)ahost port:(UInt16)aport
{
	[self.socketConnection readDataWithTimeout:(-1) tag:0];

	self.isConnecting = NO;
	self.isConnected = YES;

	[self tcpClientDidConnect];
}

- (void)socket:(id)sock didConnectToHost:(NSString *)ahost port:(UInt16)aport
{
	XRPerformBlockSynchronouslyOnMainQueue(^{
		[self onSocketWillConnect:sock];

		[self onSocket:sock didConnectToHost:ahost port:aport];
	});
}

- (void)onSocketDidDisconnect:(id)sock withError:(NSError *)error
{
	[self closeSocket];
	[self destroySocket];
	
	if (error) {
		self.lastDisconnectWasErroneous = YES;
	}

	[self tcpClientDidDisconnect:error];
}

- (void)socketDidDisconnect:(id)sock withError:(NSError *)error
{
	if (error == nil || [error code] == errSSLClosedGraceful) {
		[self onSocketDidDisconnect:sock withError:nil];
	} else {
		if ([GCDAsyncSocket badSSLCertificateErrorFound:error]) {
			[self tcpClientDidReceivedAnInsecureCertificate];
		} else {
			NSString *errorMessage = nil;

			if (error) {
				if ([[error domain] isEqualToString:NSPOSIXErrorDomain]) {
					errorMessage = [GCDAsyncSocket posixErrorStringFromError:[error code]];
				}

				if (NSObjectIsEmpty(errorMessage)) {
					errorMessage = [error localizedDescription];
				}
			}

			[self tcpClientDidError:errorMessage];
		}

		[self onSocketDidDisconnect:sock withError:error];
	}
}

- (void)completeReadForData:(NSData *)data
{
	NSMutableData *readBuffer = nil;

	BOOL hasOverflowPrefix = ([self.bufferOverflowString length] > 0);

	if (hasOverflowPrefix) {
		readBuffer = [self.bufferOverflowString mutableCopy];

		self.bufferOverflowString = nil; // Destroy old overflow;

		[readBuffer appendBytes:[data bytes] length:[data length]];
	} else {
		readBuffer = [data mutableCopy];
	}

	while (1 == 1) {
		NSData *rdata = [self readLine:&readBuffer];

		if (rdata == nil) {
			break;
		}

		NSString *sdata = [self convertFromCommonEncoding:rdata];

		if (sdata == nil) {
			break;
		}

		XRPerformBlockSynchronouslyOnMainQueue(^{
			[self tcpClientDidReceiveData:sdata];
		});
	}
}

- (void)socket:(id)sock didReadData:(NSData *)data withTag:(long)tag
{
	[self completeReadForData:data];

	[self.socketConnection readDataWithTimeout:(-1) tag:0];
}

- (void)socket:(id)sock didWriteDataWithTag:(long)tag
{
	[self tcpClientDidSendData];
}

- (void)socketDidSecure:(id)sock
{
	[self tcpClientDidSecureConnection];
}

#pragma mark -
#pragma mark SSL Certificate Trust Message

- (NSString *)localizedSecureConnectionProtocolString
{
	return [self localizedSecureConnectionProtocolString:YES];
}

- (NSString *)localizedSecureConnectionProtocolString:(BOOL)plainText
{
	NSString *protocol = [self.socketConnection sslNegotiatedProtocolString];

	NSString *cipher = [self.socketConnection sslNegotiatedCipherSuiteString];

	if (plainText) {
		return BLS(1250, protocol, cipher);
	} else {
		return BLS(1248, protocol, cipher);
	}
}

- (void)openSSLCertificateTrustDialog
{
	SecTrustRef trust = [self.socketConnection sslCertificateTrustInformation];

	PointerIsEmptyAssert(trust);

	NSString *protocolString = [self localizedSecureConnectionProtocolString:YES];

	NSString *policyName = [self.socketConnection sslCertificateTrustPolicyName];

	SFCertificateTrustPanel *panel = [SFCertificateTrustPanel new];

	[panel setDefaultButtonTitle:BLS(1011)];
	[panel setAlternateButtonTitle:nil];

	if (protocolString == nil) {
		[panel setInformativeText:TXTLS(@"BasicLanguage[1247][2]", policyName)];
	} else {
		[panel setInformativeText:TXTLS(@"BasicLanguage[1247][3]", policyName, protocolString)];
	}

	[panel beginSheetForWindow:[NSApp mainWindow]
				 modalDelegate:nil
				didEndSelector:NULL
				   contextInfo:NULL
						 trust:trust
					   message:TXTLS(@"BasicLanguage[1247][1]", policyName)];
}

@end
