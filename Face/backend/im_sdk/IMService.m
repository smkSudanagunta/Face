//
//  IMService.m
//  im
//
//  Created by houxh on 14-6-26.
//  Copyright (c) 2014年 potato. All rights reserved.
//
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#import "IMService.h"
#import "AsyncTCP.h"
#import "Message.h"
#import "util.h"


#define HEARTBEAT (180ull*NSEC_PER_SEC)

@interface IMService()
@property(atomic, copy) NSString *hostIP;
@property(atomic, assign) time_t timestmap;

@property(nonatomic, assign)BOOL stopped;
@property(nonatomic)AsyncTCP *tcp;
@property(nonatomic, strong)dispatch_source_t connectTimer;
@property(nonatomic, strong)dispatch_source_t heartbeatTimer;
@property(nonatomic)int connectFailCount;
@property(nonatomic)int seq;
@property(nonatomic)NSMutableArray *observers;
@property(nonatomic)NSMutableData *data;
@property(nonatomic)int64_t uid;
@property(nonatomic)NSMutableDictionary *peerMessages;
@property(nonatomic)NSMutableDictionary *groupMessages;
@property(nonatomic)NSMutableDictionary *subs;

@property(nonatomic)NSMutableArray *voipObservers;

@property(nonatomic, assign)int udpFD;
@property(nonatomic, strong)dispatch_source_t readSource;
@end

@implementation IMService
+(IMService*)instance {
    static IMService *im;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!im) {
            im = [[IMService alloc] init];
        }
    });
    return im;
}

-(id)init {
    self = [super init];
    if (self) {
        dispatch_queue_t queue = dispatch_get_main_queue();
        self.connectTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,queue);
        dispatch_source_set_event_handler(self.connectTimer, ^{
            [self connect];
        });

        self.heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,queue);
        dispatch_source_set_event_handler(self.heartbeatTimer, ^{
            [self sendHeartbeat];
        });
        self.voipObservers = [NSMutableArray array];
        self.observers = [NSMutableArray array];
        self.subs = [NSMutableDictionary dictionary];
        self.data = [NSMutableData data];
        self.peerMessages = [NSMutableDictionary dictionary];
        self.groupMessages = [NSMutableDictionary dictionary];
        self.connectState = STATE_UNCONNECTED;
        self.stopped = YES;
        
        self.udpFD = -1;

    }
    return self;
}

-(void)handleRead {
    char buf[64*1024];
    struct sockaddr_in addr;
    socklen_t len;
    int n = recvfrom(self.udpFD, buf, 64*1024, 0, (struct sockaddr*)&addr, &len);
    if (n <= 0) {
        NSLog(@"recv udp error:%d, %s", errno, strerror(errno));
        [self closeUDP];
        [self listenVOIP];
        return;
    }

    if (n <= 16) {
        NSLog(@"invalid voip data length");
        return;
    }
    
    VOIPData *vdata = [[VOIPData alloc] init];
    char *p = buf;
    
    vdata.sender = readInt64(p);
    p += 8;
    vdata.receiver = readInt64(p);
    p += 8;
    vdata.type = *p++;
    if (*p == VOIP_RTP) {
        vdata.rtp = YES;
    } else if (*p == VOIP_RTCP) {
        vdata.rtp = NO;
    }
    p++;
    
    vdata.content = [NSData dataWithBytes:p length:n-18];
    id<VOIPObserver> ob = [self.voipObservers lastObject];
    if (ob) {
        [ob onVOIPData:vdata];
    }
}

-(void)listenVOIP {
    if (self.readSource) {
        return;
    }
    
    struct sockaddr_in addr;
    self.udpFD = socket(AF_INET,SOCK_DGRAM,0);
    bzero(&addr,sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr=htonl(INADDR_ANY);
    addr.sin_port=htons(self.voipPort);
    bind(self.udpFD, (struct sockaddr *)&addr,sizeof(addr));
    
    sock_nonblock(self.udpFD, 1);
    
    dispatch_queue_t queue = dispatch_get_main_queue();
    self.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self.udpFD, 0, queue);
    __weak IMService *wself = self;
    dispatch_source_set_event_handler(self.readSource, ^{
        [wself handleRead];
    });
    
    dispatch_resume(self.readSource);
}

-(void)start:(int64_t)uid {
    if (!self.host || !self.port) {
        NSLog(@"should init im server host and port");
        exit(1);
    }
    if (!self.stopped) {
        return;
    }
    NSLog(@"start im service");

    self.uid = uid;
    self.stopped = NO;
    dispatch_time_t w = dispatch_walltime(NULL, 0);
    dispatch_source_set_timer(self.connectTimer, w, DISPATCH_TIME_FOREVER, 0);
    dispatch_resume(self.connectTimer);
    
    w = dispatch_walltime(NULL, HEARTBEAT);
    dispatch_source_set_timer(self.heartbeatTimer, w, HEARTBEAT, HEARTBEAT/2);
    dispatch_resume(self.heartbeatTimer);
    
    [self listenVOIP];
    [self refreshHostIP];
}

-(void)stop {
    if (self.stopped) {
        return;
    }
    
    NSLog(@"stop im service");
    self.stopped = YES;
    dispatch_suspend(self.connectTimer);
    dispatch_suspend(self.heartbeatTimer);
    
    self.connectState = STATE_UNCONNECTED;
    [self publishConnectState:STATE_UNCONNECTED];
    [self close];
    
    [self closeUDP];
}

-(void)closeUDP {
    if (self.readSource) {
        dispatch_source_set_cancel_handler(self.readSource, ^{
            NSLog(@"udp read source canceled");
        });
        dispatch_source_cancel(self.readSource);
        NSLog(@"close udp socket");
        close(self.udpFD);
        self.udpFD = -1;
        self.readSource = nil;
    }
}

-(void)close {
    if (self.tcp) {
        [self.tcp close];
        self.tcp = nil;
    }
}

-(void)startConnectTimer {
    //重连
    int64_t t = 0;
    if (self.connectFailCount > 60) {
        t = 60ull*NSEC_PER_SEC;
    } else {
        t = self.connectFailCount*NSEC_PER_SEC;
    }
    
    dispatch_time_t w = dispatch_walltime(NULL, t);
    dispatch_source_set_timer(self.connectTimer, w, DISPATCH_TIME_FOREVER, 0);
    
    NSLog(@"start connect timer:%lld", t/NSEC_PER_SEC);
}

-(void)handleClose {
    self.connectState = STATE_UNCONNECTED;
    [self publishConnectState:STATE_UNCONNECTED];
    
    for (NSNumber *seq in self.peerMessages) {
        IMMessage *msg = [self.peerMessages objectForKey:seq];
        [self.peerMessageHandler handleMessageFailure:msg.msgLocalID uid:msg.receiver];
        [self publishPeerMessageFailure:msg];
    }
    
    for (NSNumber *seq in self.groupMessages) {
        IMMessage *msg = [self.peerMessages objectForKey:seq];
        [self.groupMessageHandler handleMessageFailure:msg.msgLocalID uid:msg.receiver];
        [self publishGroupMessageFailure:msg];
    }
    [self.peerMessages removeAllObjects];
    [self.groupMessages removeAllObjects];
    [self close];
    [self startConnectTimer];
}

-(void)handleACK:(Message*)msg {
    NSNumber *seq = (NSNumber*)msg.body;
    IMMessage *m = (IMMessage*)[self.peerMessages objectForKey:seq];
    IMMessage *m2 = (IMMessage*)[self.groupMessages objectForKey:seq];
    if (!m && !m2) {
        return;
    }
    if (m) {
        [self.peerMessageHandler handleMessageACK:m.msgLocalID uid:m.receiver];
        [self.peerMessages removeObjectForKey:seq];
        [self publishPeerMessageACK:m.msgLocalID uid:m.receiver];
    } else if (m2) {
        [self.groupMessageHandler handleMessageACK:m2.msgLocalID uid:m2.receiver];
        [self.groupMessages removeObjectForKey:seq];
        [self publishGroupMessageACK:m2.msgLocalID gid:m2.receiver];
    }
}

-(void)handleIMMessage:(Message*)msg {
    IMMessage *im = (IMMessage*)msg.body;
    [self.peerMessageHandler handleMessage:im];
    NSLog(@"sender:%lld receiver:%lld content:%s", im.sender, im.receiver, [im.content UTF8String]);
    
    Message *ack = [[Message alloc] init];
    ack.cmd = MSG_ACK;
    ack.body = [NSNumber numberWithInt:msg.seq];
    [self sendMessage:ack];
    [self publishPeerMessage:im];
}

-(void)handleGroupIMMessage:(Message*)msg {
    IMMessage *im = (IMMessage*)msg.body;
    [self.groupMessageHandler handleMessage:im];
    NSLog(@"sender:%lld receiver:%lld content:%s", im.sender, im.receiver, [im.content UTF8String]);
    Message *ack = [[Message alloc] init];
    ack.cmd = MSG_ACK;
    ack.body = [NSNumber numberWithInt:msg.seq];
    [self sendMessage:ack];
    [self publishGroupMessage:im];
}

-(void)handleAuthStatus:(Message*)msg {
    int status = [(NSNumber*)msg.body intValue];
    NSLog(@"auth status:%d", status);
    if (status == 0 && [self.subs count]) {
        MessageSubsribe *sub = [[MessageSubsribe alloc] init];
        sub.uids = [self.subs allKeys];
        [self sendSubscribe:sub];
    }
}

-(void)handleInputing:(Message*)msg {
    MessageInputing *inputing = (MessageInputing*)msg.body;
    for (id<MessageObserver> ob in self.observers) {
        [ob onPeerInputing:inputing.sender];
    }
}

-(void)handlePeerACK:(Message*)msg {
    MessagePeerACK *ack = (MessagePeerACK*)msg.body;
    [self.peerMessageHandler handleMessageRemoteACK:ack.msgLocalID uid:ack.sender];
    
    for (id<MessageObserver> ob in self.observers) {
        [ob onPeerMessageRemoteACK:ack.msgLocalID uid:ack.sender];
    }
}

-(void)handleOnlineState:(Message*)msg {
    MessageOnlineState *state = (MessageOnlineState*)msg.body;
    NSNumber *key = [NSNumber numberWithLongLong:state.sender];
    if ([self.subs objectForKey:key]) {
        NSNumber *on = [NSNumber numberWithBool:state.online];
        [self.subs setObject:on forKey:key];
    }
    for (id<MessageObserver> ob in self.observers) {
        [ob onOnlineState:state.sender state:state.online];
    }
}

-(void)handleVOIPControl:(Message*)msg {
    VOIPControl *ctl = (VOIPControl*)msg.body;
    id<VOIPObserver> ob = [self.voipObservers lastObject];
    if (ob) {
        [ob onVOIPControl:ctl];
    }
}

-(void)publishPeerMessage:(IMMessage*)msg {
    for (id<MessageObserver> ob in self.observers) {
        [ob onPeerMessage:msg];
    }
}

-(void)publishPeerMessageACK:(int)msgLocalID uid:(int64_t)uid {
    for (id<MessageObserver> ob in self.observers) {
        [ob onPeerMessageACK:msgLocalID uid:uid];
    }
}

-(void)publishPeerMessageFailure:(IMMessage*)msg {
    for (id<MessageObserver> ob in self.observers) {
        [ob onPeerMessageFailure:msg.msgLocalID uid:msg.receiver];
    }
}

-(void)publishGroupMessage:(IMMessage*)msg {
    for (id<MessageObserver> ob in self.observers) {
        [ob onGroupMessage:msg];
    }
}

-(void)publishGroupMessageACK:(int)msgLocalID gid:(int64_t)gid {
    for (id<MessageObserver> ob in self.observers) {
        [ob onGroupMessageACK:msgLocalID gid:gid];
    }
}

-(void)publishGroupMessageFailure:(IMMessage*)msg {
    for (id<MessageObserver> ob in self.observers) {
        [ob onGroupMessageFailure:msg.msgLocalID gid:msg.receiver];
    }
}

-(void)publishConnectState:(int)state {
    for (id<MessageObserver> ob in self.observers) {
        [ob onConnectState:state];
    }
}

-(void)handleMessage:(Message*)msg {
    if (msg.cmd == MSG_AUTH_STATUS) {
        [self handleAuthStatus:msg];
    } else if (msg.cmd == MSG_ACK) {
        [self handleACK:msg];
    } else if (msg.cmd == MSG_IM) {
        [self handleIMMessage:msg];
    } else if (msg.cmd == MSG_GROUP_IM) {
        [self handleGroupIMMessage:msg];
    } else if (msg.cmd == MSG_INPUTING) {
        [self handleInputing:msg];
    } else if (msg.cmd == MSG_PEER_ACK) {
        [self handlePeerACK:msg];
    } else if (msg.cmd == MSG_ONLINE_STATE) {
        [self handleOnlineState:msg];
    } else if (msg.cmd == MSG_VOIP_CONTROL) {
        [self handleVOIPControl:msg];
    }
}

-(BOOL)handleData:(NSData*)data {
    [self.data appendData:data];
    int pos = 0;
    const uint8_t *p = [self.data bytes];
    while (YES) {
        if (self.data.length < pos + 4) {
            break;
        }
        int len = readInt32(p+pos);
        if (self.data.length < 4 + 8 + pos + len) {
            break;
        }
        NSData *tmp = [NSData dataWithBytes:p+4+pos length:len + 8];
        Message *msg = [[Message alloc] init];
        if (![msg unpack:tmp]) {
            NSLog(@"unpack message fail");
            return NO;
        }
        [self handleMessage:msg];
        pos += 4+8+len;
    }
    self.data = [NSMutableData dataWithBytes:p+pos length:self.data.length - pos];
    return YES;
}

-(void)onRead:(NSData*)data error:(int)err {
    if (err) {
        NSLog(@"tcp read err");
        [self handleClose];
        return;
    } else if (!data) {
        NSLog(@"tcp closed");
        [self handleClose];
        return;
    } else {
        BOOL r = [self handleData:data];
        if (!r) {
            [self handleClose];
        }
    }
}

-(NSString*)resolveIP:(NSString*)host {
    struct addrinfo hints;
    struct addrinfo *result, *rp;
    int s;
    
    char buf[32];
    snprintf(buf, 32, "%d", 0);
    
    memset(&hints, 0, sizeof(struct addrinfo));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    hints.ai_flags = 0;
    
    s = getaddrinfo([host UTF8String], buf, &hints, &result);
    if (s != 0) {
        return nil;
    }
    NSString *ip = nil;
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        struct sockaddr_in *addr = (struct sockaddr_in*)rp->ai_addr;
        const char *str = inet_ntoa(addr->sin_addr);
        ip = [NSString stringWithUTF8String:str];
        break;
    }
    
    freeaddrinfo(result);
    return ip;
}

-(void)refreshHostIP {
    NSLog(@"refresh host ip...");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *ip = [self resolveIP:self.host];
        if ([ip length] > 0) {
            self.hostIP = ip;
            self.timestmap = time(NULL);
        }
    });
}

-(void)connect {
    if (self.tcp) {
        NSLog(@"tcp already connected");
        return;
    }
    if (self.stopped) {
        NSLog(@"im service already stopped");
        return;
    }
    
    NSString *host = self.hostIP;
    if (host.length == 0) {
        [self refreshHostIP];
        self.connectFailCount = self.connectFailCount + 1;
        [self startConnectTimer];
        return;
    }
    time_t now = time(NULL);
    if (now - self.timestmap > 5*60) {
        [self refreshHostIP];
    }
    
    self.connectState = STATE_CONNECTING;
    [self publishConnectState:STATE_CONNECTING];
    self.tcp = [[AsyncTCP alloc] init];
    BOOL r = [self.tcp connect:self.host port:self.port cb:^(AsyncTCP *tcp, int err) {
        if (err) {
            NSLog(@"tcp connect err");
            [self close];
            self.connectFailCount = self.connectFailCount + 1;
            self.connectState = STATE_CONNECTFAIL;
            [self publishConnectState:STATE_CONNECTFAIL];
            
            [self startConnectTimer];
            return;
        } else {
            NSLog(@"tcp connected");
            self.connectFailCount = 0;
            self.connectState = STATE_CONNECTED;
            [self publishConnectState:STATE_CONNECTED];
            [self sendAuth];
            [self.tcp startRead:^(AsyncTCP *tcp, NSData *data, int err) {
                [self onRead:data error:err];
            }];
        }
    }];
    if (!r) {
        NSLog(@"tcp connect err");
        self.tcp = nil;
        self.connectFailCount = self.connectFailCount + 1;
        self.connectState = STATE_CONNECTFAIL;
        [self publishConnectState:STATE_CONNECTFAIL];
        
        [self startConnectTimer];
    }
}

-(void)addMessageObserver:(id<MessageObserver>)ob {
    [self.observers addObject:ob];
}
-(void)removeMessageObserver:(id<MessageObserver>)ob {
    [self.observers removeObject:ob];
}

-(void)sendPeerMessage:(IMMessage *)im {
    Message *m = [[Message alloc] init];
    m.cmd = MSG_IM;
    m.body = im;
    BOOL r = [self sendMessage:m];

    if (!r) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.peerMessageHandler handleMessageFailure:im.msgLocalID uid:im.receiver];
            [self publishPeerMessageFailure:im];
        });
    } else {
        [self.peerMessages setObject:im forKey:[NSNumber numberWithInt:m.seq]];
    }
}

-(BOOL)sendGroupMessage:(IMMessage *)im {
    Message *m = [[Message alloc] init];
    m.cmd = MSG_GROUP_IM;
    m.body = im;
    BOOL r = [self sendMessage:m];
    
    if (!r) return r;
    [self.groupMessages setObject:im forKey:[NSNumber numberWithInt:m.seq]];
    return r;
}

-(BOOL)sendMessage:(Message *)msg {
    if (!self.tcp || self.connectState != STATE_CONNECTED) return NO;
    self.seq = self.seq + 1;
    msg.seq = self.seq;

    NSMutableData *data = [NSMutableData data];
    NSData *p = [msg pack];
    if (!p) {
        NSLog(@"message pack error");
        return NO;
    }
    char b[4];
    writeInt32(p.length-8, b);
    [data appendBytes:(void*)b length:4];
    [data appendData:p];
    [self.tcp write:data];
    return YES;
}

-(void)sendHeartbeat {
    NSLog(@"send heartbeat");
    Message *msg = [[Message alloc] init];
    msg.cmd = MSG_HEARTBEAT;
    [self sendMessage:msg];
}

-(void)sendAuth {
    NSLog(@"send auth");
    Message *msg = [[Message alloc] init];
    msg.cmd = MSG_AUTH;
    msg.body = [NSNumber numberWithLongLong:self.uid];
    [self sendMessage:msg];
}

//正在输入
-(void)sendInputing:(MessageInputing*)inputing {
    Message *msg = [[Message alloc] init];
    msg.cmd = MSG_INPUTING;
    msg.body = inputing;
    [self sendMessage:msg];
}

-(void)sendSubscribe:(MessageSubsribe*)sub {
    Message *msg = [[Message alloc] init];
    msg.cmd = MSG_SUBSCRIBE_ONLINE_STATE;
    msg.body = sub;
    [self sendMessage:msg];
}

//订阅用户在线状态通知消息
-(void)subscribeState:(int64_t)uid {
    NSNumber *n = [NSNumber numberWithLongLong:uid];
    if (![self.subs objectForKey:n]) {
        [self.subs setObject:[NSNumber numberWithBool:NO] forKey:n];
        MessageSubsribe *sub = [[MessageSubsribe alloc] init];
        sub.uids = [NSArray arrayWithObject:n];
        [self sendSubscribe:sub];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL online = [[self.subs objectForKey:n] boolValue];
            for (id<MessageObserver> ob in self.observers) {
                [ob onOnlineState:uid state:online];
            }
        });
    }
}

-(void)unsubscribeState:(int64_t)uid {
    NSNumber *n = [NSNumber numberWithLongLong:uid];
    [self.subs removeObjectForKey:n];
}

-(void)pushVOIPObserver:(id<VOIPObserver>)ob {
    [self.voipObservers addObject:ob];
}

-(void)popVOIPObserver:(id<VOIPObserver>)ob {
    int count = [self.voipObservers count];
    if (count == 0) {
        return;
    }
    id<VOIPObserver> top = [self.voipObservers objectAtIndex:count-1];
    if (top == ob) {
        [self.voipObservers removeObject:top];
    }
}

-(BOOL)sendVOIPControl:(VOIPControl*)ctl {
    Message *m = [[Message alloc] init];
    m.cmd = MSG_VOIP_CONTROL;
    m.body = ctl;
    return [self sendMessage:m];
}

-(BOOL)sendVOIPData:(VOIPData*)data {
    if (self.hostIP.length == 0) {
        [self refreshHostIP];
        return NO;
    }
    if (data.content.length > 60*1024) {
        return NO;
    }
    
    char buff[64*1024];
    char *p = buff;
    writeInt64(data.sender, p);
    p += 8;
    writeInt64(data.receiver, p);
    p += 8;
    
    *p++ = data.type;
    if (data.isRTP) {
        *p++ = VOIP_RTP;
    } else {
        *p++ = VOIP_RTCP;
    }

    const void *src = [data.content bytes];
    int len = [data.content length];
    
    memcpy(p, src, len);

    struct sockaddr_in addr;
    bzero(&addr, sizeof(addr));
    
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr=inet_addr([self.hostIP UTF8String]);
    addr.sin_port=htons(self.voipPort);
    
    int r = sendto(self.udpFD, buff, len + 18, 0, (struct sockaddr*)&addr, sizeof(addr));
    if (r == -1) {
        NSLog(@"send voip data error:%s", strerror(errno));
    }
    return YES;
}

@end
