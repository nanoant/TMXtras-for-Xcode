//
//  BracketMatcher.mm
//  XcodeBracketMatcher
//
//  Created by Ciarán Walsh on 02/04/2009.
//  Copyright 2009 __MyCompanyName__. All rights reserved.
//

#import "BracketMatcher.h"
#import "JRSwizzle.h"

static BracketMatcher* SharedInstance;

@interface NSObject (DevToolsInterfaceAdditions)
// XCTextStorageAdditions
- (id)language;

// XCSourceModel
- (id)sourceModel;
- (BOOL)isInStringConstantAtLocation:(NSUInteger)index;

// XCSourceCodeTextView
- (BOOL)isInlineCompleting;
- (id)codeAssistant;

// DVTSourceCodeLanguage
- (id)identifier;
@end

static NSSet* BracketedLanguages;
static NSDictionary* WhitespaceAttributes;
static NSString* OpeningsClosings = @"\"\"''()[]";

@implementation NSLayoutManager (BracketMatching)
- (void)BracketMatching_drawGlyphsForGlyphRange:(NSRange)glyphRange atPoint:(NSPoint)containerOrigin
{
	NSString *docContents = [[self textStorage] string];
	// Loop thru current range, drawing glyphs
	for(int i = glyphRange.location; i < NSMaxRange(glyphRange); i++) {
		NSString *glyph;
		// Look for special chars
		switch ([docContents characterAtIndex:i]) {
		/* Space
		case ' ':
			glyph = @"\u2022";
			break;
		*/
		// Tab
		case '\t':
			glyph = @"\u25B8";
			break;
		// EOL
		case 0x2028:
		case 0x2029:
		case '\n':
		case '\r':
			glyph = @"\u00AC";
			break;
		// Nothing
		default:
			continue;
		}
		// Should we draw?
		NSPoint glyphPoint = [self locationForGlyphAtIndex:i];
		NSRect glyphRect = [self lineFragmentUsedRectForGlyphAtIndex:i effectiveRange:NULL];
		glyphPoint.x -= glyphRect.origin.x;
		glyphPoint.y = glyphRect.origin.y;
		[glyph drawAtPoint:glyphPoint withAttributes:WhitespaceAttributes];
	}
	[self BracketMatching_drawGlyphsForGlyphRange:glyphRange atPoint:containerOrigin];
}
@end

@implementation NSTextView (BracketMatching)
- (void)BracketMatching_keyDown:(NSEvent*)event
{
	BOOL didInsert = NO;
	if([event.charactersIgnoringModifiers isEqualToString:@"D"] &&
	   ([event modifierFlags] & NSControlKeyMask)) {
		didInsert = [[BracketMatcher sharedInstance] duplicateSelectionInTextView:self];
	} else if([event.characters isEqualToString:@"]"] &&
			  [[[self textStorage] language] isKindOfClass:[NSString class]] /* < Xcode 4 */) {
		NSString* language = [[self textStorage] language];
		if(![language isKindOfClass:[NSString class]]) {
			language = [language identifier];
		}
		if([BracketedLanguages containsObject:language])
			didInsert = [[BracketMatcher sharedInstance] insertBracketForTextView:self];
	} else {
		NSRange range = [OpeningsClosings rangeOfString:event.characters];
		if(range.length == 1 && range.location % 2 == 0) {
			NSString* language = [[self textStorage] language];
			if(![language isKindOfClass:[NSString class]]) {
				language = [language identifier];
			}
			if([BracketedLanguages containsObject:language]) {
				NSRange selectedRange = [[[self selectedRanges] lastObject] rangeValue];
				if(![[[self textStorage] sourceModel] isInStringConstantAtLocation:selectedRange.location]) {
					range.location ++;
					NSString* closing = [OpeningsClosings substringWithRange:range];
					didInsert = [[BracketMatcher sharedInstance] insertForTextView:self opening:event.characters closing:closing];
				}
			}
		}
	}

	if(!didInsert)
		[self BracketMatching_keyDown:event];
}

- (void)BracketMatching_deleteBackward:(NSEvent*)event
{
	NSTextView *textView = self;
	NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
	if(selectedRange.length == 0) {
		NSRange checkRange = NSMakeRange(selectedRange.location - 1, 2);
		@try {
			NSString* substring = [[[textView textStorage] string] substringWithRange:checkRange];
			NSRange range = [OpeningsClosings rangeOfString:substring];
			if(range.length == 2 && range.location % 2 == 0) {
				NSString* language = [[self textStorage] language];
				if(![language isKindOfClass:[NSString class]]) {
					language = [language identifier];
				}
				if([BracketedLanguages containsObject:language]) {
					[textView moveForward:event];
					[textView BracketMatching_deleteBackward:event];
				}
			}
		} @catch(NSException *e) {
			if(![e.name isEqualToString:NSRangeException]) {
				[e raise];
			}
		}
	}
	[self BracketMatching_deleteBackward:event];
}

@end

@implementation BracketMatcher

+ (void)pluginDidLoad:(NSBundle *)bundle
{
	if(![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.Xcode"]) {
		if(![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.dt.Xcode"]) {
			NSLog(@"BracketMatcher unknown bundle identifier: %@", [[NSBundle mainBundle] bundleIdentifier]);
			return;
		}
		NSError *error = nil;
		if(![NSClassFromString(@"DVTSourceTextView") jr_swizzleMethod:@selector(keyDown:) withMethod:@selector(BracketMatching_keyDown:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[DVTSourceTextView keyDown:]', %@", [error localizedDescription]);
		}
		error = nil;
		if(![NSClassFromString(@"DVTSourceTextView") jr_swizzleMethod:@selector(deleteBackward:) withMethod:@selector(BracketMatching_deleteBackward:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[DVTSourceTextView deleteBackward:]', %@", [error localizedDescription]);
		}
		error = nil;
		if(![NSClassFromString(@"DVTLayoutManager") jr_swizzleMethod:@selector(drawGlyphsForGlyphRange:atPoint:) withMethod:@selector(BracketMatching_drawGlyphsForGlyphRange:atPoint:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[DVTLayoutManager drawGlyphsForGlyphRange:atPoint:]', %@", [error localizedDescription]);
		}
	} else {
		NSError *error = nil;
		if(![NSClassFromString(@"XCSourceCodeTextView") jr_swizzleMethod:@selector(keyDown:) withMethod:@selector(BracketMatching_keyDown:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[XCSourceCodeTextView keyDown:]', %@", [error localizedDescription]);
		}
		error = nil;
		if(![NSClassFromString(@"XCSourceCodeTextView") jr_swizzleMethod:@selector(deleteBackward:) withMethod:@selector(BracketMatching_deleteBackward:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[XCSourceCodeTextView deleteBackward:]', %@", [error localizedDescription]);
		}
		error = nil;
		if(![NSClassFromString(@"XCLayoutManager") jr_swizzleMethod:@selector(drawGlyphsForGlyphRange:atPoint:) withMethod:@selector(BracketMatching_drawGlyphsForGlyphRange:atPoint:) error:&error]) {
			NSLog(@"BracketMatcher failed to swizzle `-[XCLayoutManager drawGlyphsForGlyphRange:atPoint:]', %@", [error localizedDescription]);
		}
	}

	BracketedLanguages = [[NSSet alloc] initWithObjects:
						  @"xcode.lang.c", // Xcode 3
						  @"xcode.lang.cpp",
						  @"xcode.lang.objcpp",
						  @"xcode.lang.objc",
						  @"xcode.lang.objj",
						  @"Xcode.SourceCodeLanguage.C", // Xcode 4
						  @"Xcode.SourceCodeLanguage.C++",
						  @"Xcode.SourceCodeLanguage.Objective-C",
						  @"Xcode.SourceCodeLanguage.Objective-C++",
						  @"Xcode.SourceCodeLanguage.Objective-J",
						  nil];
	WhitespaceAttributes = [[NSDictionary alloc] initWithObjectsAndKeys:[NSColor colorWithDeviceRed:0.9f green:0.9f blue:0.9f alpha:1.0f], NSForegroundColorAttributeName, nil];

	NSLog(@"BracketMatcher loaded.");
}

+ (BracketMatcher*)sharedInstance
{
	return SharedInstance ?: [[self new] autorelease];
}

- (id)init
{
	if(SharedInstance)
		[self release];
	else
		self = SharedInstance = [[super init] retain];
	return SharedInstance;
}

- (NSString*)processLine:(NSString*)line insertionPoint:(NSUInteger)insertionPoint
{
	NSTask* task = [[NSTask new] autorelease];
	[task setLaunchPath:[[NSBundle bundleForClass:[self class]] pathForResource:@"parser" ofType:@"rb"]];
	[task setEnvironment:[NSDictionary dictionaryWithObjectsAndKeys:line, @"TM_CURRENT_LINE", [NSString stringWithFormat:@"%d", insertionPoint], @"TM_LINE_INDEX", nil]];
	[task setStandardOutput:[NSPipe pipe]];
	[task launch];
	[task waitUntilExit];

	NSFileHandle* fileHandle = [[task standardOutput] fileHandleForReading];
	NSData* data             = [fileHandle readDataToEndOfFile];
	if([task terminationStatus] != 0)
		return nil;
	return [[[NSString alloc] initWithBytes:[data bytes] length:[data length] encoding:NSUTF8StringEncoding] autorelease];
}

NSUInteger TextViewLineIndex (NSTextView* textView)
{
	NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
	NSUInteger res        = selectedRange.location;
	NSString* substring   = [[[textView textStorage] string] substringToIndex:selectedRange.location];
	NSUInteger newline    = [substring rangeOfString:@"\n" options:NSBackwardsSearch].location;
	if(newline != NSNotFound)
		res -= newline + 1;
	return res;
}

- (BOOL)insertBracketForTextView:(NSTextView*)textView
{
	if(![[textView selectedRanges] count])
		return NO;

	NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
	if(selectedRange.length > 0)
	{
		NSString* selectedText = [textView.textStorage.string substringWithRange:selectedRange];
		[textView insertText:@"["];
		[textView insertText:selectedText];
		[textView insertText:@"]"];
		return YES;
	}

	NSRange lineRange = [textView.textStorage.string lineRangeForRange:selectedRange];
	lineRange.length -= 1;
	NSString* lineText            = [textView.textStorage.string substringWithRange:lineRange];
	NSMutableString* resultString = [[self processLine:lineText insertionPoint:TextViewLineIndex(textView)] mutableCopy];

	if(!resultString || [resultString isEqualToString:lineText])
		return NO;

	NSRange caretOffset = [resultString rangeOfString:@"$$caret$$"];
	[resultString replaceCharactersInRange:caretOffset withString:@""];

	[textView.undoManager beginUndoGrouping];
	[[textView.undoManager prepareWithInvocationTarget:textView] setSelectedRange:selectedRange];
	[[textView.undoManager prepareWithInvocationTarget:textView] replaceCharactersInRange:NSMakeRange(lineRange.location, [resultString length]) withString:lineText];
	[textView.undoManager endUndoGrouping];

	[textView replaceCharactersInRange:lineRange withString:resultString];
	[textView setSelectedRange:NSMakeRange(lineRange.location + caretOffset.location, 0)];

	return YES;
}

- (BOOL)insertForTextView:(NSTextView*)textView opening:(NSString *)opening closing:(NSString *)closing
{
	NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];

	if(selectedRange.length > 0)
	{
		NSString* selectedText = [textView.textStorage.string substringWithRange:selectedRange];
		[textView insertText:opening];
		[textView insertText:selectedText];
		[textView insertText:closing];
	} else {
		[textView insertText:opening];
		[textView insertText:closing];
		[textView moveBackward:self];
	}

	return YES;
}

- (BOOL)duplicateSelectionInTextView:(NSTextView*)textView
{
	NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
	if(selectedRange.length > 0) {
		NSString* selection = [textView.textStorage.string substringWithRange:selectedRange];
		[textView.undoManager beginUndoGrouping];
		[[textView.undoManager prepareWithInvocationTarget:textView] replaceCharactersInRange:selectedRange withString:@""];
		[textView.undoManager endUndoGrouping];
		[textView replaceCharactersInRange:NSMakeRange(selectedRange.location, 0) withString:selection];
	} else {
		NSUInteger start, end, contentsEnd;
		[[[textView textStorage] string] getParagraphStart:&start end:&end contentsEnd:&contentsEnd forRange:selectedRange];
		NSRange paragraphRange = NSMakeRange(start, end - start);
		NSString* paragraph = [[[textView textStorage] string] substringWithRange:paragraphRange];
		[textView.undoManager beginUndoGrouping];
		[[textView.undoManager prepareWithInvocationTarget:textView] replaceCharactersInRange:paragraphRange withString:@""];
		[textView.undoManager endUndoGrouping];
		[textView replaceCharactersInRange:NSMakeRange(start, 0) withString:paragraph];
	}

	return YES;
}
@end
