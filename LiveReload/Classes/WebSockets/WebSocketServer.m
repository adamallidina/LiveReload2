#import "WebSocketServer.h"
#include "libwebsockets.h"
#include "private-libwebsockets.h"

#import "RegexKitLite.h"
#import <CommonCrypto/CommonDigest.h>


enum {
    PROTOCOL_HTTP = 0,
    PROTOCOL_WEB_SOCKET = 1
};


static NSString *SHA1OfString(NSString *input) {
    const char *cstr = [input cStringUsingEncoding:NSUTF8StringEncoding];
    NSData *data = [NSData dataWithBytes:cstr length:input.length];

    uint8_t digest[CC_SHA1_DIGEST_LENGTH];

    CC_SHA1(data.bytes, data.length, digest);

    NSMutableString* output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];

    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++)
        [output appendFormat:@"%02x", digest[i]];

    return output;
}

static NSString *CreateUUID() {
    CFUUIDRef uuidObj = CFUUIDCreate(nil);
    NSString *uuidString = (NSString *) CFUUIDCreateString(nil, uuidObj);
    CFRelease(uuidObj);
    return [uuidString autorelease];
}

static NSString *MimeTypeForFile(NSString *file) {
    NSString *ext = [file pathExtension];
    if ([ext isEqualToString:@"css"])
        return @"text/css";
    if ([ext isEqualToString:@"png"])
        return @"image/png";
    if ([ext isEqualToString:@"gif"])
        return @"image/gif";
    if ([ext isEqualToString:@"jpg"])
        return @"image/jpg";
    return @"application/octet-stream";
}


// from https://github.com/samsoffes/sstoolkit

static NSString *UnescapeURLString(NSString *escapedString) {
    NSString *deplussed = [escapedString stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [deplussed stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static NSDictionary *DecodeURLQueryString(NSString *encodedString) {
    if (!encodedString) {
        return nil;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *pairs = [encodedString componentsSeparatedByString:@"&"];

    for (NSString *kvp in pairs) {
        if ([kvp length] == 0) {
            continue;
        }

        NSRange pos = [kvp rangeOfString:@"="];
        NSString *key;
        NSString *val;

        if (pos.location == NSNotFound) {
            key = UnescapeURLString(kvp);
            val = @"";
        } else {
            key = UnescapeURLString([kvp substringToIndex:pos.location]);
            val = UnescapeURLString([kvp substringFromIndex:pos.location + pos.length]);
        }

        if (!key || !val) {
            continue; // I'm sure this will bite my arse one day
        }

        [result setObject:val forKey:key];
    }
    return result;
}


@interface WebSocketServer ()

- (void)connected:(WebSocketConnection *)connection;

- (NSString *)localPathForUrlPath:(NSString *)urlPath;

@end

@interface WebSocketConnection ()

- (id)initWithWebSocketServer:(WebSocketServer *)aServer socket:(struct libwebsocket *)aWsi;

- (void)received:(NSString *)message;
- (void)closed;

@end



#define MAX_POLL_ELEMENTS 100
struct pollfd pollfds[100];
int count_pollfds = 0;


static WebSocketServer *lastWebSocketServer;


struct WebSocketServer_http_per_session_data {
    WebSocketConnection *connection;
};

struct WebSocketServer_per_session_data {
    WebSocketConnection *connection;
};

static int WebSocketServer_http_callback(struct libwebsocket_context * this,
                                    struct libwebsocket *wsi,
                                    enum libwebsocket_callback_reasons reason,
                                    void *user, void *in, size_t len) {
    //struct WebSocketServer_http_per_session_data *pss = user;
    char client_name[128];
    char client_ip[128];
    char buf[1024];
    NSString *path;

    switch (reason) {
        case LWS_CALLBACK_HTTP:
            fprintf(stderr, "serving HTTP URI %s\n", (char *)in);

            if (in && strncmp(in, "/livereload.js", strlen("/livereload.js")) == 0) {
                path = [[NSBundle mainBundle] pathForResource:@"livereload.js" ofType:nil];
                NSCAssert(path != nil, @"File 'livereload.js' not found inside the bundle");
                libwebsockets_serve_http_file(wsi, [path fileSystemRepresentation], "text/javascript");
            } else {
                @autoreleasepool {
                    // btw we're running in a fucking background thread here (man isn't Node.js nice?)
                    const char *pathUTF = (const char *)in;
                    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:pathUTF]];
                    NSString *urlPath = url.path;
                    NSDictionary *query = DecodeURLQueryString(url.query);
                    NSString *localPath = [lastWebSocketServer localPathForUrlPath:urlPath];
                    if (localPath && [[NSFileManager defaultManager] fileExistsAtPath:localPath] && [[localPath pathExtension] isEqualToString:@"css"]) {
                        const char *mime = [MimeTypeForFile(localPath) UTF8String];
                        NSString *originalUrl = [query objectForKey:@"url"];
                        if (originalUrl.length == 0) {
                            libwebsockets_serve_http_file(wsi, [localPath fileSystemRepresentation], mime);
                        } else {
                            NSURL *originalUrlObj = [NSURL URLWithString:originalUrl];
                            NSString *content = [NSString stringWithContentsOfFile:localPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
                            content = [content stringByReplacingOccurrencesOfRegex:@"(url\\s*\\(\\s*?['\"]?)([^)'\"]*)(['\"]?\\s*?\\))" usingBlock:^NSString *(NSInteger captureCount, NSString *const *capturedStrings, const NSRange *capturedRanges, volatile BOOL *const stop) {
                                NSString *prefix = capturedStrings[1], *mid = [capturedStrings[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]], *suffix = capturedStrings[3];
                                mid = [[NSURL URLWithString:mid relativeToURL:originalUrlObj] absoluteString];
                                return [NSString stringWithFormat:@"%@%@%@", prefix, mid, suffix];
                            }];
                            const char *contentUTF = [content UTF8String];
                            sprintf(buf, "HTTP/1.0 200 OK\x0d\x0a" "Server: libwebsockets\x0d\x0a" "Content-Type: %s\x0d\x0a" "Content-Length: %d\x0d\x0a" "\x0d\x0a", mime, (int) strlen(contentUTF));
                            libwebsocket_write(wsi, (unsigned char *)buf, strlen(buf), LWS_WRITE_HTTP);
                            libwebsocket_write(wsi, (unsigned char *)contentUTF, strlen(contentUTF), LWS_WRITE_HTTP);
                        }
                    } else {
                        sprintf(buf, "HTTP/1.0 404 Not Found\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a");
                        libwebsocket_write(wsi, (unsigned char *)buf, strlen(buf), LWS_WRITE_HTTP);
                    }
                }
            }
        down:
            shutdown(wsi->sock, SHUT_RDWR);
            break;

            /*
             * callback for confirming to continue with client IP appear in
             * protocol 0 callback since no websocket protocol has been agreed
             * yet.  You can just ignore this if you won't filter on client IP
             * since the default uhandled callback return is 0 meaning let the
             * connection continue.
             */

        case LWS_CALLBACK_FILTER_NETWORK_CONNECTION:

            libwebsockets_get_peer_addresses((int)(long)user, client_name,
                                             sizeof(client_name), client_ip, sizeof(client_ip));

            fprintf(stderr, "Received network connect from %s (%s)\n",
                    client_name, client_ip);

            /* if we returned non-zero from here, we kill the connection */
            break;

        default:
            break;
    }

    return 0;
}

static int WebSocketServer_callback(struct libwebsocket_context * this,
                                    struct libwebsocket *wsi,
                                    enum libwebsocket_callback_reasons reason,
                                    void *user, void *in, size_t len) {
    int n;
    struct WebSocketServer_per_session_data *pss = user;
    NSString *message;

    switch (reason) {

        case LWS_CALLBACK_ESTABLISHED:
            pss->connection = [[WebSocketConnection alloc] initWithWebSocketServer:lastWebSocketServer socket:wsi];
            [lastWebSocketServer performSelectorOnMainThread:@selector(connected:) withObject:pss->connection waitUntilDone:NO];
            break;

        case LWS_CALLBACK_BROADCAST:
            n = libwebsocket_write(wsi, in, len, LWS_WRITE_TEXT);
            if (n < 0) {
                fprintf(stderr, "ERROR writing to socket");
                return 1;
            }
            break;

        case LWS_CALLBACK_RECEIVE:
            message = [[[NSString alloc] initWithBytes:in length:len encoding:NSUTF8StringEncoding] autorelease];
            [pss->connection performSelectorOnMainThread:@selector(received:) withObject:message waitUntilDone:NO];
            break;

        case LWS_CALLBACK_CLOSED:
            [pss->connection performSelectorOnMainThread:@selector(closed) withObject:nil waitUntilDone:NO];
            [pss->connection release];
            pss->connection = nil;

//        case LWS_CALLBACK_ADD_POLL_FD:
//            pollfds[count_pollfds].fd = (int)(long)user;
//            pollfds[count_pollfds].events = (int)len;
//            pollfds[count_pollfds++].revents = 0;
//            break;
//
//        case LWS_CALLBACK_DEL_POLL_FD:
//            for (n = 0; n < count_pollfds; n++)
//                if (pollfds[n].fd == (int)(long)user)
//                    while (n < count_pollfds) {
//                        pollfds[n] = pollfds[n + 1];
//                        n++;
//                    }
//            count_pollfds--;
//            break;
//
//        case LWS_CALLBACK_SET_MODE_POLL_FD:
//            for (n = 0; n < count_pollfds; n++)
//                if (pollfds[n].fd == (int)(long)user)
//                    pollfds[n].events |= (int)(long)len;
//            break;
//
//        case LWS_CALLBACK_CLEAR_MODE_POLL_FD:
//            for (n = 0; n < count_pollfds; n++)
//                if (pollfds[n].fd == (int)(long)user)
//                    pollfds[n].events &= ~(int)(long)len;
//            break;

        default:
            break;
    }

    return 0;
}



static struct libwebsocket_protocols protocols[] = {
    // my understanding is that protocol 0 is always used for HTTP;
    // the "http-only" string is designed to never match any incoming
    // web socket extension/procotol ID (the terminology is still beyond me),
    // so that this protocol is never used for web sockets
    { "http-only", WebSocketServer_http_callback, sizeof(struct WebSocketServer_http_per_session_data) },
    // my understanding is that NULL here means this entry matches any web sockets request
    { NULL, WebSocketServer_callback, sizeof(struct WebSocketServer_per_session_data) },
    { NULL, NULL, 0 }
};



@implementation WebSocketServer

@synthesize port;
@synthesize delegate;

- (id)init {
    self = [super init];
    if (self) {
        // all override URLs are digitally signed using this salt as a key;
        // otherwise we'd give read access to any file on the user's file system
        _salt = [CreateUUID() copy];
    }
    return self;
}

- (NSString *)urlPathForServingLocalPath:(NSString *)localPath {
    NSString *signature = SHA1OfString([_salt stringByAppendingString:localPath]);
    return [NSString stringWithFormat:@"/%@%@", signature, localPath];
}

- (NSString *)localPathForUrlPath:(NSString *)urlPath {
    if (urlPath.length == 0 || [urlPath characterAtIndex:0] != '/')
        return nil;
    NSRange range = [urlPath rangeOfString:@"/" options:0 range:NSMakeRange(1, urlPath.length - 1)];
    if (range.location == NSNotFound)
        return nil;

    NSString *signature = [urlPath substringWithRange:NSMakeRange(1, range.location - 1)];
    NSString *localPath = [urlPath substringFromIndex:range.location];

    NSString *correctSignature = SHA1OfString([_salt stringByAppendingString:localPath]);
    if (![correctSignature isEqualToString:signature])
        return nil;

    return localPath;
}

- (void)connect {
    [lastWebSocketServer release];
    lastWebSocketServer = [self retain];

    [self performSelectorInBackground:@selector(runInBackgroundThread) withObject:nil];
}

- (void)broadcast:(NSString *)message {
    NSLog(@"Broadcasting: %@", message);
    NSUInteger len = 0;
    NSUInteger cb = [message maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    unsigned char *data = malloc(LWS_SEND_BUFFER_PRE_PADDING + cb +LWS_SEND_BUFFER_POST_PADDING);
    unsigned char *buf = data + LWS_SEND_BUFFER_PRE_PADDING;
    [message getBytes:buf maxLength:cb usedLength:&len encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, [message length]) remainingRange:NULL];

    // NOTE: this call is a multithreaded race condition, but we cross our fingers and hope for the best :P
    libwebsockets_broadcast(&protocols[PROTOCOL_WEB_SOCKET], buf, len);

    free(data);
}

- (void)connected:(WebSocketConnection *)connection {
    [self.delegate webSocketServer:self didAcceptConnection:connection];
}

- (NSInteger)countOfConnections {
    NSInteger result = 0;
    for (int n = 0; n < FD_HASHTABLE_MODULUS; n++) {
        for (int m = 0; m < context->fd_hashtable[n].length; m++) {
            struct libwebsocket *wsi = context->fd_hashtable[n].wsi[m];
            if (wsi->mode != LWS_CONNMODE_WS_SERVING)
                continue;
            ++result;
        }
    }
    return result;
}

- (void)runInBackgroundThread {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int opts = 0;
    context = libwebsocket_create_context(port, NULL, protocols,                                          libwebsocket_internal_extensions, NULL, NULL, -1, -1, opts);
    if (context == NULL) {
        NSLog(@"libwebsocket init failed");
        if ([delegate respondsToSelector:@selector(webSocketServerDidFailToInitialize:)]) {
            [(id)delegate performSelectorOnMainThread:@selector(webSocketServerDidFailToInitialize:) withObject:self waitUntilDone:NO];
        }
        return;
    }

    while (0 == libwebsocket_service(context, 1000*60*60*24))
        ;

//    while (1) {
//        int n = poll(pollfds, count_pollfds, 25);
//        if (n < 0)
//            goto done;
//
//        if (n)
//            for (n = 0; n < count_pollfds; n++) {
//                if (pollfds[n].revents) {
//                    libwebsocket_service_fd(context,
//                                            &pollfds[n]);
//                }
//            }
//    }

done:
    libwebsocket_context_destroy(context);
    [pool drain];
}

@end


@implementation WebSocketConnection

@synthesize server;
@synthesize delegate;

- (id)initWithWebSocketServer:(WebSocketServer *)aServer socket:(struct libwebsocket *)aWsi {
    if ((self = [super init])) {
        server = aServer;
        wsi = aWsi;
    }
    return self;
}

- (void)received:(NSString *)message {
    [self.delegate webSocketConnection:self didReceiveMessage:message];
}

- (void)closed {
    [self.delegate webSocketConnectionDidClose:self];
}

- (void)send:(NSString *)message {
    NSLog(@"Sending: %@", message);
    NSUInteger len = 0;
    NSUInteger cb = [message maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    unsigned char *data = malloc(LWS_SEND_BUFFER_PRE_PADDING + cb +LWS_SEND_BUFFER_POST_PADDING);
    unsigned char *buf = data + LWS_SEND_BUFFER_PRE_PADDING;
    [message getBytes:buf maxLength:cb usedLength:&len encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, [message length]) remainingRange:NULL];

    // NOTE: this call is a multithreaded race condition, but we cross our fingers and hope for the best :P
    libwebsocket_write(wsi, buf, len, LWS_WRITE_TEXT);

    free(data);
}

@end
