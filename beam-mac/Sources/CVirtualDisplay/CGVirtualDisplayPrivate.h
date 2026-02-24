// Private CGVirtualDisplay API declarations
// From reverse-engineering by KhaosT, FluffyDisplay, and others
// These classes live in CoreGraphics.framework but have no public headers

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayMode : NSObject
@property(readonly, nonatomic) CGFloat refreshRate;
@property(readonly, nonatomic) NSUInteger width;
@property(readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(CGFloat)rate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay*);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)desc;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
