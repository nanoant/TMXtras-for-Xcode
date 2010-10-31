//
//  XcodeMate.m
//  XcodeMate
//
//  Copyright 2009-2010 Ciarán Walsh, Adam Strzelecki. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface XcodeMate : NSObject
@end

@interface NSTextView (XcodeMate)
- (BOOL)XcodeMate_insertForTextView:(NSTextView *)textView opening:(NSString *)opening closing:(NSString *)closing;
- (BOOL)XcodeMate_duplicateSelectionInTextView:(NSTextView *)textView;
@end