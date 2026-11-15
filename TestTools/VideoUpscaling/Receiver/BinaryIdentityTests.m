#import <XCTest/XCTest.h>
#import <StreamWebRTC/StreamWebRTC.h>
#import <dlfcn.h>
#import <mach-o/loader.h>

@interface BinaryIdentityTests : XCTestCase
@end

@implementation BinaryIdentityTests
- (void)testLoadedFrameworkExportsCustomAPIAndRecordsIdentity {
    XCTAssertTrue([RTCRtpReceiver instancesRespondToSelector:
        @selector(setVideoUpscalingConfiguration:statusHandler:)]);
    Dl_info image;
    XCTAssertNotEqual(dladdr((__bridge const void *)RTCPeerConnectionFactory.class, &image), 0);
    const struct mach_header *header = image.dli_fbase;
    XCTAssertEqual(header->magic, MH_MAGIC_64);
    NSString *identity = nil;
    const uint8_t *position = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        const struct load_command *command = (const struct load_command *)position;
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            identity = [[NSUUID alloc] initWithUUIDBytes:uuid->uuid].UUIDString;
        }
        position += command->cmdsize;
    }
    XCTAssertNotNil(identity);
    if (identity) {
        XCTAttachment *attachment = [XCTAttachment attachmentWithString:identity];
        attachment.name = @"StreamWebRTC loaded UUID";
        attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
        [self addAttachment:attachment];
    }
}
@end
