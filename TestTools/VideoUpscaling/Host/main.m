#import <UIKit/UIKit.h>

@interface UpscalingSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation UpscalingSceneDelegate
- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UIViewController alloc] init];
    [self.window makeKeyAndVisible];
}
@end

@interface UpscalingAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation UpscalingAppDelegate
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(
            argc, argv, nil, NSStringFromClass(UpscalingAppDelegate.class));
    }
}
