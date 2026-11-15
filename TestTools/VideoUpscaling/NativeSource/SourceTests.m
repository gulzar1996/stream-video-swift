#import <XCTest/XCTest.h>

extern int FramesAfterChannelDetach(void);
extern bool AcceptsUnsupportedColorMatrix(void);
extern bool AcceptsHDRTransfer(void);

@interface SourceTests : XCTestCase
@end

@implementation SourceTests
- (void)testUnsupportedColorMatrixPassesThrough {
    XCTAssertFalse(AcceptsUnsupportedColorMatrix());
}
- (void)testHDRTransferPassesThrough {
    XCTAssertFalse(AcceptsHDRTransfer());
}
- (void)testChannelDetachAllowsFutureFrames {
    XCTAssertEqual(FramesAfterChannelDetach(), 2);
}
@end
