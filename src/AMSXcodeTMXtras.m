//
// AMSXcodeTMXtras.m
// AMSXcodeTMXtras
//
// Copyright (c) 2009 Ciarán Walsh, 2010-2014 Adam Strzelecki
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#import "AMSXcodeTMXtras.h"
#import <objc/runtime.h>

#define PLUGIN @"AMSXcodeTMXtras"

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Portions of Xcode interface

@interface DVTSourceCodeLanguage : NSObject
- (NSString *)identifier;
@end

@interface DVTFilePath : NSObject
- (void)_notifyAssociatesOfChange;
@end

@interface XCSourceModel : NSObject
- (BOOL)isInStringConstantAtLocation:(NSUInteger)index;
@end

@interface NSTextStorage (AMSXcodeTMXtras_DVTSourceTextStorage)
- (void)replaceCharactersInRange:(NSRange)range
                      withString:(NSString *)string
                 withUndoManager:(id)undoManager;
- (NSRange)lineRangeForCharacterRange:(NSRange)range;
- (NSRange)characterRangeForLineRange:(NSRange)range;
- (void)indentCharacterRange:(NSRange)range undoManager:(id)undoManager;
- (DVTSourceCodeLanguage *)language;
- (XCSourceModel *)sourceModel;
@end

@interface NSDocument (AMSXcodeTMXtras_IDESourceCodeDocument)
- (NSUndoManager *)undoManager;
- (NSTextStorage *)textStorage;
- (void)_respondToFileChangeOnDiskWithFilePath:(DVTFilePath *)filePath;
- (DVTFilePath *)filePath;
- (void)ide_revertDocumentToSaved:(id)sender;
@end

@interface NSTextView (AMSXcodeTMXtras_DVTSourceTextView)
- (BOOL)isInlineCompleting;
@end

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Default settings

static NSSet *SupportedLanguages = nil;
static NSDictionary *WhitespaceAttributes = nil;
static NSString *OpeningsClosings = @"\"\"''()[]";

static NSString *SpaceGlyph = nil;
static NSString *TabGlyph = nil;
static NSString *ReturnGlyph = nil;

static NSString *DefaultSpaceGlyph /*******/ = nil;       // @"\u2022"
static NSString *DefaultTabGlyph /*********/ = @"\u254E"; // @"\u25B8";
static NSString *DefaultReturnGlyph /******/ = @"\u00AC";

static CGFloat WhitespaceGray = 0.6;
static CGFloat WhitespaceAlpha = 0.25;

#define kBracketsLocation 4

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Draw invisibles

@implementation NSLayoutManager (AMSXcodeTMXtras)

- (void)AMSXcodeTMXtras_drawGlyphsForGlyphRange:(NSRange)glyphRange
                                        atPoint:(NSPoint)containerOrigin
{
  NSString *docContents = [[self textStorage] string];
  // Loop thru current range, drawing glyphs
  for (int i = glyphRange.location; i < NSMaxRange(glyphRange); i++) {
    NSString *glyph;
    // Look for special chars
    switch ([docContents characterAtIndex:i]) {
    case ' ':
      if (SpaceGlyph.length == 1) {
        glyph = SpaceGlyph;
        break;
      }
      continue;
    // Tab
    case '\t':
      if (TabGlyph.length == 1) {
        glyph = TabGlyph;
        break;
      }
      continue;
    // EOL
    case 0x2028:
    case 0x2029:
    case '\n':
    case '\r':
      if (ReturnGlyph.length == 1) {
        glyph = ReturnGlyph;
        break;
      }
      continue;
    // Nothing
    default:
      continue;
    }
    // Should we draw?
    NSPoint glyphPoint = [self locationForGlyphAtIndex:i];
    NSRect glyphRect =
        [self lineFragmentUsedRectForGlyphAtIndex:i effectiveRange:NULL];
    glyphPoint.x -= glyphRect.origin.x;
    glyphPoint.y = glyphRect.origin.y;
    [glyph drawAtPoint:glyphPoint withAttributes:WhitespaceAttributes];
  }
  [self AMSXcodeTMXtras_drawGlyphsForGlyphRange:glyphRange
                                        atPoint:containerOrigin];
}

@end

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Bracket marching & duplication

static BOOL DuplicateSelectionInTextView(NSTextView *textView)
{
  NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
  if (selectedRange.length > 0) {
    NSString *selection =
        [textView.textStorage.string substringWithRange:selectedRange];
    [textView.undoManager beginUndoGrouping];
    [[textView.undoManager prepareWithInvocationTarget:textView]
        replaceCharactersInRange:selectedRange
                      withString:@""];
    [textView.undoManager endUndoGrouping];
    [textView replaceCharactersInRange:NSMakeRange(selectedRange.location, 0)
                            withString:selection];
  } else {
    NSUInteger start, end, contentsEnd;
    [[[textView textStorage] string] getParagraphStart:&start
                                                   end:&end
                                           contentsEnd:&contentsEnd
                                              forRange:selectedRange];
    NSRange paragraphRange = NSMakeRange(start, end - start);
    NSString *paragraph =
        [[[textView textStorage] string] substringWithRange:paragraphRange];
    [textView.undoManager beginUndoGrouping];
    [[textView.undoManager prepareWithInvocationTarget:textView]
        replaceCharactersInRange:paragraphRange
                      withString:@""];
    [textView.undoManager endUndoGrouping];
    [textView replaceCharactersInRange:NSMakeRange(start, 0)
                            withString:paragraph];
  }

  return YES;
}

@implementation NSTextView (AMSXcodeTMXtras)

- (void)AMSXcodeTMXtras_changeColor:(id)sender
{
  if (![sender isKindOfClass:[NSColorPanel class]]) {
    [self AMSXcodeTMXtras_changeColor:sender];
  }
}

- (void)AMSXcodeTMXtras_keyDown:(NSEvent *)event
{
  BOOL didInsert = NO;
  if ([event.charactersIgnoringModifiers isEqualToString:@"D"] &&
      ([event modifierFlags] & NSControlKeyMask)) {
    didInsert = DuplicateSelectionInTextView(self);
  } else {
    NSRange range = [OpeningsClosings rangeOfString:event.characters];
    if (range.length == 1 && range.location % 2 == 0) {
      NSTextStorage *textStorage = [self textStorage];
      if ([textStorage respondsToSelector:@selector(language)]) {
        NSString *language = [[textStorage language] identifier];
        if ([SupportedLanguages containsObject:language]) {
          NSRange selectedRange =
              [[[self selectedRanges] lastObject] rangeValue];
          if (![[[self textStorage] sourceModel]
                  isInStringConstantAtLocation:selectedRange.location] ||
              range.location >= kBracketsLocation) {
            // ensure we insert brackets closing only when next character is
            // whitespace
            BOOL nextBracketSame = NO;
            if (!selectedRange.length) {
              NSString *string = [[self textStorage] string];
              NSString *nextCharacter = nil;
              if (string.length) {
                nextCharacter = [string
                    substringWithRange:NSMakeRange(selectedRange.location, 1)];
              }
              if ([nextCharacter
                      isEqualToString:[OpeningsClosings
                                          substringWithRange:range]]) {
                nextBracketSame = YES;
              }
            }
            if (!nextBracketSame) {
              range.location++;
              NSString *closing = [OpeningsClosings substringWithRange:range];
              didInsert =
                  [self AMSXcodeTMXtras_insertForTextView:self
                                                  opening:event.characters
                                                  closing:closing];
            }
          }
        }
      }
    }
  }

  if (!didInsert) [self AMSXcodeTMXtras_keyDown:event];
}

- (void)AMSXcodeTMXtras_deleteBackward:(NSEvent *)event
{
  NSRange selectedRange = [[[self selectedRanges] lastObject] rangeValue];
  if (selectedRange.length == 0) {
    NSRange checkRange = NSMakeRange(selectedRange.location - 1, 2);
    @try
    {
      NSString *substring =
          [[[self textStorage] string] substringWithRange:checkRange];
      NSRange range = [OpeningsClosings rangeOfString:substring];
      if (range.length == 2 && range.location % 2 == 0) {
        NSTextStorage *textStorage = [self textStorage];
        if ([textStorage respondsToSelector:@selector(language)]) {
          NSString *language = [[textStorage language] identifier];
          if ([SupportedLanguages containsObject:language]) {
            [self moveForward:event];
            [self AMSXcodeTMXtras_deleteBackward:event];
          }
        }
      }
    }
    @catch (NSException *e)
    {
      if (![e.name isEqualToString:NSRangeException]) {
        [e raise];
      }
    }
  }
  [self AMSXcodeTMXtras_deleteBackward:event];
}

static NSUInteger TextViewLineIndex(NSTextView *textView)
{
  NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];
  NSUInteger res = selectedRange.location;
  NSString *substring =
      [[[textView textStorage] string] substringToIndex:selectedRange.location];
  NSUInteger newline =
      [substring rangeOfString:@"\n" options:NSBackwardsSearch].location;
  if (newline != NSNotFound) res -= newline + 1;
  return res;
}

- (BOOL)AMSXcodeTMXtras_insertForTextView:(NSTextView *)textView
                                  opening:(NSString *)opening
                                  closing:(NSString *)closing
{
  NSRange selectedRange = [[[textView selectedRanges] lastObject] rangeValue];

  [textView.undoManager beginUndoGrouping];

  if (selectedRange.length > 0) {
    NSString *selectedText =
        [textView.textStorage.string substringWithRange:selectedRange];
    // NOTE: If we are in the placeholder, replace it
    if ([selectedText hasPrefix:@"<#"] && [selectedText hasSuffix:@"#>"]) {
      [textView insertText:opening];
      [textView insertText:closing];
      [textView moveBackward:self];
    } else {
      [textView insertText:opening];
      [textView insertText:selectedText];
      [textView insertText:closing];
    }
  } else {
    [textView insertText:opening];
    [textView insertText:closing];
    [textView moveBackward:self];
  }

  [textView.undoManager endUndoGrouping];

  return YES;
}

@end

////////////////////////////////////////////////////////////////////////////////

#pragma mark - Plugin startup

static BOOL Swizzle(Class class, SEL original, SEL replacement)
{
  if (!class) return NO;
  Method originalMethod = class_getInstanceMethod(class, original);
  if (!originalMethod) {
    NSLog(PLUGIN @" error: original method -[%@ %@] not found",
          NSStringFromClass(class), NSStringFromSelector(original));
    return NO;
  }
  Method replacementMethod = class_getInstanceMethod(class, replacement);
  if (!replacementMethod) {
    NSLog(PLUGIN @" error: replacement method -[%@ %@] not found",
          NSStringFromClass(class), NSStringFromSelector(replacement));
    return NO;
  }
  method_exchangeImplementations(originalMethod, replacementMethod);
  return YES;
}

@implementation AMSXcodeTMXtras

+ (void)pluginDidLoad:(NSBundle *)bundle
{
  NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];

  // Xcode 4 support
  if (![bundleIdentifier isEqualToString:@"com.apple.dt.Xcode"]) {
    if (bundleIdentifier.length) {
      // complain only when there's bundle identifier
      NSLog(PLUGIN @" unknown bundle identifier: %@", bundleIdentifier);
    }
    return;
  }
  Swizzle(NSClassFromString(@"DVTSourceTextView"), //
          @selector(changeColor:),                 //
          @selector(AMSXcodeTMXtras_changeColor:));
  Swizzle(NSClassFromString(@"DVTSourceTextView"), //
          @selector(keyDown:),                     //
          @selector(AMSXcodeTMXtras_keyDown:));
  Swizzle(NSClassFromString(@"DVTSourceTextView"), //
          @selector(deleteBackward:),
          @selector(AMSXcodeTMXtras_deleteBackward:));
  Swizzle(NSClassFromString(@"DVTLayoutManager"),
          @selector(drawGlyphsForGlyphRange:atPoint:),
          @selector(AMSXcodeTMXtras_drawGlyphsForGlyphRange:atPoint:));

  SupportedLanguages = [[NSSet alloc]
      initWithObjects:@"Xcode.SourceCodeLanguage.C", // Xcode 4
                      @"Xcode.SourceCodeLanguage.C++",
                      @"Xcode.SourceCodeLanguage.C-Plus-Plus",
                      @"Xcode.SourceCodeLanguage.Objective-C",
                      @"Xcode.SourceCodeLanguage.Objective-C++",
                      @"Xcode.SourceCodeLanguage.Objective-C-Plus-Plus",
                      @"Xcode.SourceCodeLanguage.Objective-J",
                      @"Xcode.SourceCodeLanguage.JavaScript", nil];
#if DEBUG
  NSLog(PLUGIN @" %@ loaded.",
        [[NSBundle mainBundle]
            objectForInfoDictionaryKey:(NSString *)kCFBundleVersionKey]);
#endif

  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  [self userDefaultsDidChange:
            [NSNotification
                notificationWithName:NSUserDefaultsDidChangeNotification
                              object:userDefaults]];

  NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
  [center addObserver:self
             selector:@selector(userDefaultsDidChange:)
                 name:NSUserDefaultsDidChangeNotification
               object:userDefaults];
}

#define LOAD_DEFAULT(clazz, name)                                              \
  if ((ovalue = [userDefaults objectForKey:@"AMS" @ #name]) &&                 \
      [ovalue isKindOfClass:[clazz class]]) {                                  \
    if (!name || ![name isEqual:ovalue]) {                                     \
      [name release];                                                          \
      name = [ovalue copy];                                                    \
    }                                                                          \
  } else if (![name isEqual:Default##name]) {                                  \
    [name release];                                                            \
    name = [Default##name copy];                                               \
  }

#define LOAD_DOUBLE_DEFAULT(name, modified)                                    \
  if ((dvalue = [userDefaults doubleForKey:@"AMS" @ #name]) &&                 \
      dvalue != WhitespaceAlpha) {                                             \
    name = dvalue;                                                             \
    modified = YES;                                                            \
  }

+ (void)userDefaultsDidChange:(NSNotification *)notification
{
  NSUserDefaults *userDefaults = (NSUserDefaults *)[notification object];

  NSString *ovalue;
  LOAD_DEFAULT(NSString, SpaceGlyph);
  LOAD_DEFAULT(NSString, TabGlyph);
  LOAD_DEFAULT(NSString, ReturnGlyph);

  BOOL whitespaceModified = NO;
  double dvalue;
  LOAD_DOUBLE_DEFAULT(WhitespaceGray, whitespaceModified);
  LOAD_DOUBLE_DEFAULT(WhitespaceAlpha, whitespaceModified);

  if (whitespaceModified || !WhitespaceAttributes) {
    [WhitespaceAttributes release];
    WhitespaceAttributes = [[NSDictionary alloc]
        initWithObjectsAndKeys:[NSColor colorWithDeviceWhite:WhitespaceGray
                                                       alpha:WhitespaceAlpha],
                               NSForegroundColorAttributeName, nil];
  }
}

@end
