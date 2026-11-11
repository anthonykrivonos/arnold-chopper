// Cocoa editor for Chipmunk Soul. Every class here is prefixed so it can't collide with classes
// from other plug-ins loaded into the same host process.

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "Shared.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace cs;

// -------------------------------------------------------------------------------------------------
#pragma mark - Theme

// Dark theme: near-black window, charcoal panels with rounded corners, a warm orange-to-pink accent.

static NSColor* CSColor(uint32_t rgb, CGFloat alpha = 1.0)
{
	return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
							   green:((rgb >> 8) & 0xff) / 255.0
								blue:(rgb & 0xff) / 255.0
							   alpha:alpha];
}

static NSColor* kPage() { return CSColor(0x0b0c0f); }
static NSColor* kSurface() { return CSColor(0x15171c); }
static NSColor* kRaised() { return CSColor(0x1f2229); }
static NSColor* kRaisedHover() { return CSColor(0x2a2e37); }
static NSColor* kInk() { return CSColor(0xeef0f4); }
static NSColor* kMuted() { return CSColor(0x8b909c); }
static NSColor* kRule() { return CSColor(0xffffff, 0.07); }
static NSColor* kAccent() { return CSColor(0xff7a45); }
static NSColor* kAccentEnd() { return CSColor(0xff4f8b); }
static NSColor* kAccentSoft() { return CSColor(0xff7a45, 0.16); }
static NSColor* kError() { return CSColor(0xff6b6b); }

static NSGradient* AccentGradient() { return [[NSGradient alloc] initWithStartingColor:kAccent() endingColor:kAccentEnd()]; }

static NSColor* SliceColor(int i)
{
	static const uint32_t palette[] = { 0xff7a45, 0xffc145, 0x3ddc97, 0x4cc9f0, 0x9d7bff, 0xff5c8a };
	return CSColor(palette[i % 6]);
}

static NSFont* CSBody(CGFloat size, NSFontWeight weight = NSFontWeightRegular)
{
	return [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
}

// Apple's New York serif for the title and headings.
static NSFont* CSDisplay(CGFloat size, NSFontWeight weight = NSFontWeightSemibold)
{
	NSFontDescriptor* d = [[NSFont systemFontOfSize:size weight:weight].fontDescriptor
		fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
	return [NSFont fontWithDescriptor:d size:size] ?: [NSFont fontWithName:@"Georgia-Bold" size:size];
}

static NSColor* GroupColor(int group)
{
	static const uint32_t colors[] = { 0x000000, 0xff5c8a, 0x4cc9f0, 0x3ddc97, 0xffc145 };
	return CSColor(colors[std::clamp(group, 0, kMuteGroups)]);
}

static NSString* GroupName(int group) { return group > 0 ? [NSString stringWithFormat:@"%c", 'A' + group - 1] : @"Off"; }

static NSBezierPath* Rounded(NSRect r, CGFloat radius) { return [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius]; }

static void FillRounded(NSRect r, CGFloat radius, NSColor* color)
{
	[color setFill];
	[Rounded(r, radius) fill];
}

static void StrokeRounded(NSRect r, CGFloat radius, NSColor* color)
{
	[color setStroke];
	NSBezierPath* path = Rounded(NSInsetRect(r, 0.5, 0.5), radius);
	path.lineWidth = 1;
	[path stroke];
}

static NSString* NoteName(int note)
{
	static NSString* names[] = { @"C", @"C#", @"D", @"D#", @"E", @"F", @"F#", @"G", @"G#", @"A", @"A#", @"B" };
	return [NSString stringWithFormat:@"%@%d", names[note % 12], note / 12 - 2];  // GarageBand: 60 = C3
}

static bool IsBlackKey(int note)
{
	const int n = note % 12;
	return n == 1 || n == 3 || n == 6 || n == 8 || n == 10;
}

// Laptop keys -> slices, laid out like a piano exactly as in GarageBand's Musical Typing:
// A S D F G H J K L ; ' are white keys, W E T Y U O P are black keys. Shift must be held so plain
// keys keep working as GarageBand shortcuts. Shift+Z / Shift+X move the keys down / up 12 slices.
// Physical key codes (ANSI positions), so it works on any keyboard layout.
static const struct {
	unsigned short keyCode;
	NSString* label;
} kPadKeys[] = {
	{ 0, @"A" },  { 13, @"W" }, { 1, @"S" },  { 14, @"E" }, { 2, @"D" },  { 3, @"F" },
	{ 17, @"T" }, { 5, @"G" },  { 16, @"Y" }, { 4, @"H" },  { 32, @"U" }, { 38, @"J" },
	{ 40, @"K" }, { 31, @"O" }, { 37, @"L" }, { 35, @"P" }, { 41, @";" }, { 39, @"'" },
};
static const int kNumPadKeys = int(sizeof(kPadKeys) / sizeof(kPadKeys[0]));
static const unsigned short kOctaveDownKey = 6, kOctaveUpKey = 7;  // Z, X

static NSDictionary* TextAttrs(CGFloat size, NSColor* color, NSFontWeight weight = NSFontWeightRegular)
{
	return @{ NSFontAttributeName : CSBody(size, weight), NSForegroundColorAttributeName : color };
}

static void DrawCentered(NSString* s, NSRect r, NSDictionary* attrs)
{
	NSSize size = [s sizeWithAttributes:attrs];
	[s drawAtPoint:NSMakePoint(NSMidX(r) - size.width / 2, NSMidY(r) - size.height / 2) withAttributes:attrs];
}

static void WithGlow(NSColor* color, CGFloat blur, void (^draw)(void))
{
	[NSGraphicsContext saveGraphicsState];
	NSShadow* glow = [NSShadow new];
	glow.shadowColor = color;
	glow.shadowBlurRadius = blur;
	glow.shadowOffset = NSZeroSize;
	[glow set];
	draw();
	[NSGraphicsContext restoreGraphicsState];
}

// -------------------------------------------------------------------------------------------------
#pragma mark - Knob

typedef NS_ENUM(NSInteger, CSKnobCurve) { CSKnobLinear, CSKnobLog, CSKnobSqrt };

@interface ChipmunkSoulKnob_v1 : NSControl
@property (nonatomic) float minValue, maxValue, defaultValue, value;
@property (nonatomic) CSKnobCurve curve;
@property (nonatomic) BOOL integerSteps;
@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy) NSString* (^valueText)(float);
@property (nonatomic, copy) void (^onChange)(float value);
@property (nonatomic, copy) void (^onGesture)(BOOL begin);
@end

@implementation ChipmunkSoulKnob_v1 {
	float _dragNorm;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (float)norm
{
	const float v = std::clamp(_value, _minValue, _maxValue);
	switch (_curve) {
	case CSKnobLog: return std::log(v / _minValue) / std::log(_maxValue / _minValue);
	case CSKnobSqrt: return std::sqrt((v - _minValue) / (_maxValue - _minValue));
	default: return (v - _minValue) / (_maxValue - _minValue);
	}
}

- (float)valueForNorm:(float)n
{
	n = std::clamp(n, 0.f, 1.f);
	float v;
	switch (_curve) {
	case CSKnobLog: v = _minValue * std::pow(_maxValue / _minValue, n); break;
	case CSKnobSqrt: v = _minValue + n * n * (_maxValue - _minValue); break;
	default: v = _minValue + n * (_maxValue - _minValue); break;
	}
	return _integerSteps ? std::round(v) : v;
}

- (void)setValue:(float)value
{
	_value = value;
	self.needsDisplay = YES;
}

- (void)commit:(float)v
{
	if (v == _value) {
		return;
	}
	self.value = v;
	if (_onChange) {
		_onChange(v);
	}
}

- (void)drawRect:(NSRect)dirty
{
	const NSRect b = self.bounds;
	const CGFloat d = std::min(b.size.width, b.size.height - 34) - 14;
	const NSPoint c = NSMakePoint(NSMidX(b), 6 + d / 2);
	const CGFloat sweep = 270;

	// The view is flipped, so increasing angles run clockwise on screen: 135° is 7:30, 405° is 4:30.
	NSBezierPath* track = [NSBezierPath bezierPath];
	[track appendBezierPathWithArcWithCenter:c radius:d / 2 startAngle:135 endAngle:45 clockwise:NO];
	track.lineWidth = 4;
	track.lineCapStyle = NSLineCapStyleRound;
	[kRaisedHover() setStroke];
	[track stroke];

	const float n = [self norm];
	if (n > 0.001f) {
		NSBezierPath* arc = [NSBezierPath bezierPath];
		[arc appendBezierPathWithArcWithCenter:c radius:d / 2 startAngle:135 endAngle:135 + sweep * n clockwise:NO];
		arc.lineWidth = 4;
		arc.lineCapStyle = NSLineCapStyleRound;
		WithGlow(CSColor(0xff7a45, 0.6), 6, ^{
			[[kAccent() blendedColorWithFraction:n ofColor:kAccentEnd()] setStroke];
			[arc stroke];
		});
	}

	const NSRect capRect = NSInsetRect(NSMakeRect(c.x - d / 2, c.y - d / 2, d, d), 9, 9);
	NSBezierPath* cap = [NSBezierPath bezierPathWithOvalInRect:capRect];
	[[[NSGradient alloc] initWithStartingColor:CSColor(0x30343d) endingColor:CSColor(0x1a1c22)] drawInBezierPath:cap angle:90];
	[kRule() setStroke];
	[cap stroke];
	const CGFloat angle = (135 + sweep * n) * M_PI / 180.0;
	const CGFloat inner = capRect.size.width / 2;
	NSBezierPath* pointer = [NSBezierPath bezierPath];
	[pointer moveToPoint:NSMakePoint(c.x + std::cos(angle) * (inner - 11), c.y + std::sin(angle) * (inner - 11))];
	[pointer lineToPoint:NSMakePoint(c.x + std::cos(angle) * (inner - 3), c.y + std::sin(angle) * (inner - 3))];
	pointer.lineWidth = 2.5;
	pointer.lineCapStyle = NSLineCapStyleRound;
	[kInk() setStroke];
	[pointer stroke];

	NSString* text = _valueText ? _valueText(_value) : [NSString stringWithFormat:@"%.1f", _value];
	DrawCentered(text, NSMakeRect(0, b.size.height - 34, b.size.width, 16), TextAttrs(12, kInk(), NSFontWeightSemibold));
	DrawCentered(_title, NSMakeRect(0, b.size.height - 17, b.size.width, 15), TextAttrs(11, kMuted(), NSFontWeightMedium));
}

- (void)mouseDown:(NSEvent*)event
{
	if (event.clickCount == 2) {
		[self commit:_defaultValue];
		return;
	}
	_dragNorm = [self norm];
	if (_onGesture) {
		_onGesture(YES);
	}
	while (true) {
		event = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if (event.type == NSEventTypeLeftMouseUp) {
			break;
		}
		const BOOL fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
		_dragNorm = std::clamp(_dragNorm - float(event.deltaY) * (fine ? 0.001f : 0.006f), 0.f, 1.f);
		[self commit:[self valueForNorm:_dragNorm]];
	}
	if (_onGesture) {
		_onGesture(NO);
	}
}

- (void)scrollWheel:(NSEvent*)event
{
	const float step = _integerSteps ? 1.f / std::max(1.f, _maxValue - _minValue) : 0.01f;
	const float dir = event.scrollingDeltaY > 0 ? 1.f : (event.scrollingDeltaY < 0 ? -1.f : 0.f);
	if (dir != 0) {
		[self commit:[self valueForNorm:[self norm] + dir * step]];
	}
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Slider

// A horizontal slider sharing the knob's value model: [title] [====o----] [value].
@interface ChipmunkSoulSlider_v1 : ChipmunkSoulKnob_v1
@property (nonatomic) CGFloat titleWidth, valueWidth;
@property (nonatomic) BOOL bipolar;    // fill from zero rather than from the left end
@property (nonatomic) float tickStep;  // draw a tick every `tickStep` units (0 = none)
@end

@implementation ChipmunkSoulSlider_v1

- (NSRect)trackRect
{
	const NSRect b = self.bounds;
	return NSMakeRect(_titleWidth + 8, NSMidY(b) - 2, b.size.width - _titleWidth - _valueWidth - 16, 4);
}

- (CGFloat)xForNorm:(float)n
{
	const NSRect t = [self trackRect];
	return t.origin.x + 7 + n * (t.size.width - 14);
}

- (void)drawRect:(NSRect)dirty
{
	const NSRect b = self.bounds, track = [self trackRect];
	const CGFloat alpha = self.enabled ? 1.0 : 0.35;
	NSDictionary* titleAttrs = TextAttrs(12, [kMuted() colorWithAlphaComponent:alpha], NSFontWeightMedium);
	const NSSize ts = [self.title sizeWithAttributes:titleAttrs];
	[self.title drawAtPoint:NSMakePoint(0, NSMidY(b) - ts.height / 2) withAttributes:titleAttrs];

	FillRounded(track, 2, kRaisedHover());
	if (_tickStep > 0) {
		[CSColor(0xffffff, 0.18 * alpha) setFill];
		for (float v = std::ceil(self.minValue / _tickStep) * _tickStep; v <= self.maxValue + 1e-3f; v += _tickStep) {
			const float n = (v - self.minValue) / (self.maxValue - self.minValue);
			NSRectFill(NSMakeRect(std::round([self xForNorm:n]), NSMidY(b) - 7, 1, 14));
		}
	}
	const float n = [self norm];
	const float zero = _bipolar ? std::clamp(-self.minValue / (self.maxValue - self.minValue), 0.f, 1.f) : 0.f;
	const CGFloat x0 = [self xForNorm:std::min(n, zero)], x1 = [self xForNorm:std::max(n, zero)];
	if (x1 - x0 > 0.5) {
		[[[NSGradient alloc] initWithStartingColor:[kAccent() colorWithAlphaComponent:alpha] endingColor:[kAccentEnd() colorWithAlphaComponent:alpha]]
			drawInBezierPath:Rounded(NSMakeRect(x0, track.origin.y, x1 - x0, track.size.height), 2) angle:0];
	}
	const CGFloat kx = [self xForNorm:n];
	const NSRect knob = NSMakeRect(kx - 7, NSMidY(b) - 7, 14, 14);
	WithGlow(CSColor(0xff6a55, 0.5 * alpha), 6, ^{
		[[kInk() colorWithAlphaComponent:alpha] setFill];
		[[NSBezierPath bezierPathWithOvalInRect:knob] fill];
	});

	NSString* text = self.valueText ? self.valueText(self.value) : [NSString stringWithFormat:@"%.1f", self.value];
	NSDictionary* valueAttrs = TextAttrs(12, [kInk() colorWithAlphaComponent:alpha], NSFontWeightSemibold);
	const NSSize vs = [text sizeWithAttributes:valueAttrs];
	[text drawAtPoint:NSMakePoint(b.size.width - vs.width, NSMidY(b) - vs.height / 2) withAttributes:valueAttrs];
}

- (float)normAt:(NSPoint)p
{
	const NSRect t = [self trackRect];
	return float((p.x - t.origin.x - 7) / std::max<CGFloat>(1, t.size.width - 14));
}

- (void)mouseDown:(NSEvent*)event
{
	if (!self.enabled) {
		return;
	}
	if (event.clickCount == 2) {
		[self commit:self.defaultValue];
		return;
	}
	if (self.onGesture) {
		self.onGesture(YES);
	}
	const NSPoint start = [self convertPoint:event.locationInWindow fromView:nil];
	// Clicking the knob grabs it; clicking the track jumps there.
	if (std::abs(start.x - [self xForNorm:[self norm]]) > 9) {
		[self commit:[self valueForNorm:[self normAt:start]]];
	}
	float n = [self norm];
	while (true) {
		event = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
		if (!event || event.type == NSEventTypeLeftMouseUp) {
			break;
		}
		const BOOL fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
		n = std::clamp(n + float(event.deltaX) / float(std::max<CGFloat>(1, [self trackRect].size.width)) * (fine ? 0.15f : 1.f), 0.f, 1.f);
		[self commit:[self valueForNorm:n]];
	}
	if (self.onGesture) {
		self.onGesture(NO);
	}
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Buttons

// Rounded buttons. `Choice` buttons work as segments of a one-of-many group; `Check` draws a
// toggle switch with its label.
typedef NS_ENUM(NSInteger, CSButtonKind) { CSButtonPrimary, CSButtonSecondary, CSButtonChoice, CSButtonCheck };

// Where a button sits in a joined group: only the group's outer corners are rounded.
typedef NS_ENUM(NSInteger, CSSegment) { CSSegmentSolo, CSSegmentFirst, CSSegmentMiddle, CSSegmentLast };

static NSBezierPath* SegmentPath(NSRect r, CGFloat radius, CSSegment segment)
{
	const CGFloat left = segment == CSSegmentSolo || segment == CSSegmentFirst ? radius : 0;
	const CGFloat right = segment == CSSegmentSolo || segment == CSSegmentLast ? radius : 0;
	NSBezierPath* p = [NSBezierPath bezierPath];
	[p moveToPoint:NSMakePoint(NSMinX(r) + left, NSMinY(r))];
	[p lineToPoint:NSMakePoint(NSMaxX(r) - right, NSMinY(r))];
	if (right > 0) {
		[p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMinY(r)) toPoint:NSMakePoint(NSMaxX(r), NSMinY(r) + right) radius:right];
	}
	[p lineToPoint:NSMakePoint(NSMaxX(r), NSMaxY(r) - right)];
	if (right > 0) {
		[p appendBezierPathWithArcFromPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMaxX(r) - right, NSMaxY(r)) radius:right];
	}
	[p lineToPoint:NSMakePoint(NSMinX(r) + left, NSMaxY(r))];
	if (left > 0) {
		[p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMaxY(r)) toPoint:NSMakePoint(NSMinX(r), NSMaxY(r) - left) radius:left];
	}
	[p lineToPoint:NSMakePoint(NSMinX(r), NSMinY(r) + left)];
	if (left > 0) {
		[p appendBezierPathWithArcFromPoint:NSMakePoint(NSMinX(r), NSMinY(r)) toPoint:NSMakePoint(NSMinX(r) + left, NSMinY(r)) radius:left];
	}
	[p closePath];
	return p;
}

@interface ChipmunkSoulButton_v1 : NSButton
@property (nonatomic) CSButtonKind kind;
@property (nonatomic) CSSegment segment;
+ (instancetype)buttonWithTitle:(NSString*)title kind:(CSButtonKind)kind target:(id)target action:(SEL)action;
@end

@implementation ChipmunkSoulButton_v1

+ (instancetype)buttonWithTitle:(NSString*)title kind:(CSButtonKind)kind target:(id)target action:(SEL)action
{
	ChipmunkSoulButton_v1* b = [[self alloc] initWithFrame:NSZeroRect];
	b.title = title;
	b.kind = kind;
	b.target = target;
	b.action = action;
	b.bordered = NO;
	[b setButtonType:kind == CSButtonPrimary || kind == CSButtonSecondary ? NSButtonTypeMomentaryPushIn : NSButtonTypePushOnPushOff];
	return b;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)drawRect:(NSRect)dirty
{
	const NSRect b = self.bounds;
	const BOOL pressed = self.cell.isHighlighted;
	const BOOL on = self.state == NSControlStateValueOn;
	const CGFloat alpha = self.enabled ? 1.0 : 0.4;

	if (_kind == CSButtonCheck) {
		const NSRect track = NSMakeRect(0, std::round(NSMidY(b) - 9), 32, 18);
		if (on) {
			[AccentGradient() drawInBezierPath:Rounded(track, 9) angle:0];
		} else {
			FillRounded(track, 9, kRaisedHover());
		}
		const NSRect knob = NSMakeRect(on ? NSMaxX(track) - 16 : track.origin.x + 2, track.origin.y + 2, 14, 14);
		WithGlow(CSColor(0x000000, 0.4), 3, ^{
			[kInk() setFill];
			[[NSBezierPath bezierPathWithOvalInRect:knob] fill];
		});
		NSDictionary* attrs = TextAttrs(13, [kInk() colorWithAlphaComponent:alpha]);
		const NSSize ts = [self.title sizeWithAttributes:attrs];
		[self.title drawAtPoint:NSMakePoint(42, NSMidY(b) - ts.height / 2) withAttributes:attrs];
		return;
	}

	const CGFloat radius = 8;
	NSColor* text = kInk();
	NSBezierPath* shape = SegmentPath(b, radius, _segment);
	NSBezierPath* outline = SegmentPath(NSInsetRect(b, 0.5, 0.5), radius - 0.5, _segment);
	outline.lineWidth = 1;
	switch (_kind) {
	case CSButtonPrimary: {
		WithGlow(CSColor(0xff5f6a, pressed ? 0.2 : 0.45), 10, ^{
			[AccentGradient() drawInBezierPath:shape angle:0];
		});
		if (pressed) {
			[CSColor(0x000000, 0.2) setFill];
			[shape fill];
		}
		text = CSColor(0xffffff);
		break;
	}
	case CSButtonChoice:
		[(on ? CSColor(0x3a2620) : pressed ? kRaisedHover() : kRaised()) setFill];
		[shape fill];
		[(on ? [kAccent() colorWithAlphaComponent:0.8] : kRule()) setStroke];
		[outline stroke];
		text = on ? kAccent() : kInk();
		break;
	default:
		[(pressed ? kRaisedHover() : kRaised()) setFill];
		[shape fill];
		[kRule() setStroke];
		[outline stroke];
		break;
	}
	DrawCentered(self.title, b, TextAttrs(13, [text colorWithAlphaComponent:alpha], NSFontWeightSemibold));
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Waveform

@class ChipmunkSoulView_v1;

@interface ChipmunkSoulWaveform_v1 : NSView
@property (nonatomic, weak) ChipmunkSoulView_v1* owner;
@property (nonatomic) std::vector<float> peaks;  // (min, max) pairs
@property (nonatomic) uint32_t frames;
@property (nonatomic) std::vector<uint32_t> starts;
@property (nonatomic) uint32_t regionStart, regionEnd;
@property (nonatomic) std::vector<std::pair<uint32_t, float>> playheads;
@property (nonatomic) std::vector<int> activeSlices;
@property (nonatomic) int rootNote;
@property (nonatomic, copy) NSString* emptyMessage;
@end

@interface ChipmunkSoulPads_v1 : NSView
@property (nonatomic, weak) ChipmunkSoulView_v1* owner;
@property (nonatomic) int count;
@property (nonatomic) int rootNote;
@property (nonatomic) std::vector<float> levels;  // per slice
@property (nonatomic) int keyOffset;              // slice played by the A key
@property (nonatomic) int selected;               // chop whose mute group the picker edits, -1 if none
@property (nonatomic) std::vector<uint8_t> groups;  // mute group per chop
@end

@interface ChipmunkSoulView_v1 : NSView <NSDraggingDestination>
- (instancetype)initWithAudioUnit:(AudioUnit)au;
- (void)audition:(int)slice;
- (void)releaseSlice:(int)slice;
- (void)selectSlice:(int)slice;
- (void)playDrum:(int)drum;
- (NSURL*)exportChop:(int)slice;
- (void)cycleGroupOf:(int)slice;
- (void)focus;
- (void)commitSlices:(const std::vector<uint32_t>&)starts;
- (void)commitRegion:(uint32_t)start end:(uint32_t)end;
- (void)loadPath:(NSString*)path;
@end

static const CGFloat kNavHeight = 34;

// Main view layout: three panels (Song, Keys, Sound), each a gray title bar over a white body.
static const CGFloat kMargin = 16, kBarHeight = 34;
static const CGFloat kSongTop = 76, kSongBottom = 370;
static const CGFloat kKeysTop = 382, kKeysBottom = 630;
static const CGFloat kSoundTop = 642, kSoundBottom = 834;
static const CGFloat kViewHeight = 850;

@implementation ChipmunkSoulWaveform_v1 {
	enum { kDragNone, kDragMarker, kDragRegionNew, kDragRegionStart, kDragRegionEnd, kDragRegionMove } _drag;
	int _dragMarker;
	uint32_t _dragAnchor;
	int64_t _dragOffset;
	int _auditioning;
	NSTrackingArea* _tracking;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

// Drops land on whichever child is under the cursor; hand them to the main view.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [_owner draggingEntered:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [_owner draggingUpdated:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [_owner draggingExited:info]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { return [_owner performDragOperation:info]; }

- (NSRect)navRect { return NSMakeRect(0, 0, self.bounds.size.width, kNavHeight); }
- (NSRect)mainRect { return NSMakeRect(0, kNavHeight + 8, self.bounds.size.width, self.bounds.size.height - kNavHeight - 8); }

- (uint32_t)viewStart { return _regionStart; }
- (uint32_t)viewEnd { return _regionEnd > _regionStart ? _regionEnd : _frames; }

- (CGFloat)xForFrame:(double)f inRect:(NSRect)r start:(double)a end:(double)b
{
	return r.origin.x + (f - a) / std::max(1.0, b - a) * r.size.width;
}

- (double)frameForX:(CGFloat)x inRect:(NSRect)r start:(double)a end:(double)b
{
	return a + (x - r.origin.x) / r.size.width * (b - a);
}

- (void)drawPeaksIn:(NSRect)r start:(double)a end:(double)b color:(NSColor*)color
{
	if (_peaks.empty() || _frames == 0) {
		return;
	}
	const size_t numPeaks = _peaks.size() / 2;
	const CGFloat mid = NSMidY(r), half = r.size.height / 2 - 2;
	NSBezierPath* path = [NSBezierPath bezierPath];
	const int width = int(r.size.width);
	for (int x = 0; x < width; ++x) {
		const double f0 = a + (b - a) * x / width, f1 = a + (b - a) * (x + 1) / width;
		size_t p0 = size_t(f0 / _frames * numPeaks), p1 = size_t(f1 / _frames * numPeaks);
		p1 = std::max(p1, p0 + 1);
		float lo = 0, hi = 0;
		for (size_t p = p0; p < p1 && p < numPeaks; ++p) {
			lo = std::min(lo, _peaks[2 * p]);
			hi = std::max(hi, _peaks[2 * p + 1]);
		}
		const CGFloat px = r.origin.x + x + 0.5;
		[path moveToPoint:NSMakePoint(px, mid - std::min<CGFloat>(1, hi) * half)];
		[path lineToPoint:NSMakePoint(px, mid - std::max<CGFloat>(-1, lo) * half + 0.5)];
	}
	path.lineWidth = 1;
	[color setStroke];
	[path stroke];
}

- (void)drawRect:(NSRect)dirty
{
	const NSRect nav = [self navRect], main = [self mainRect];
	FillRounded(nav, 8, kRaised());
	FillRounded(main, 10, CSColor(0x0f1014));
	StrokeRounded(main, 10, kRule());

	if (_frames == 0) {
		DrawCentered(_emptyMessage ?: @"Drop a song here, or click Load Song", main, TextAttrs(15, kMuted(), NSFontWeightMedium));
		DrawCentered(@"Whole song", nav, TextAttrs(11, kMuted()));
		return;
	}

	// Navigator: whole song, with the chop region highlighted.
	[NSGraphicsContext saveGraphicsState];
	[Rounded(nav, 8) addClip];
	const CGFloat rx0 = [self xForFrame:[self viewStart] inRect:nav start:0 end:_frames];
	const CGFloat rx1 = [self xForFrame:[self viewEnd] inRect:nav start:0 end:_frames];
	[self drawPeaksIn:nav start:0 end:_frames color:CSColor(0x5a5f6b)];
	const NSRect region = NSMakeRect(rx0, 0, std::max<CGFloat>(4, rx1 - rx0), kNavHeight);
	FillRounded(region, 6, kAccentSoft());
	[NSGraphicsContext saveGraphicsState];
	[Rounded(region, 6) addClip];
	[self drawPeaksIn:nav start:0 end:_frames color:kAccent()];
	[NSGraphicsContext restoreGraphicsState];
	StrokeRounded(region, 6, kAccent());
	for (const auto& [frame, level] : _playheads) {
		[[kInk() colorWithAlphaComponent:0.4 + 0.6 * level] setFill];
		NSRectFill(NSMakeRect([self xForFrame:frame inRect:nav start:0 end:_frames], 0, 1, kNavHeight));
	}
	[NSGraphicsContext restoreGraphicsState];

	// Main lane: the chop region, zoomed in; each chop's waveform in its own color.
	const double a = [self viewStart], b = [self viewEnd];
	[NSGraphicsContext saveGraphicsState];
	[Rounded(NSInsetRect(main, 1, 1), 9) addClip];
	for (size_t i = 0; i < _starts.size(); ++i) {
		const double s0 = _starts[i], s1 = i + 1 < _starts.size() ? _starts[i + 1] : b;
		const CGFloat x0 = [self xForFrame:s0 inRect:main start:a end:b], x1 = [self xForFrame:s1 inRect:main start:a end:b];
		const bool active = std::find(_activeSlices.begin(), _activeSlices.end(), int(i)) != _activeSlices.end();
		const NSRect band = NSMakeRect(x0, main.origin.y, x1 - x0, main.size.height);
		[[SliceColor(int(i)) colorWithAlphaComponent:active ? 0.16 : 0.05] setFill];
		NSRectFillUsingOperation(band, NSCompositingOperationSourceOver);
		[NSGraphicsContext saveGraphicsState];
		NSRectClip(band);
		[self drawPeaksIn:main start:a end:b color:[SliceColor(int(i)) colorWithAlphaComponent:active ? 1.0 : 0.75]];
		[NSGraphicsContext restoreGraphicsState];
	}
	if (_starts.empty()) {
		[self drawPeaksIn:main start:a end:b color:kInk()];
	}
	for (size_t i = 0; i < _starts.size(); ++i) {
		const CGFloat x = std::round([self xForFrame:_starts[i] inRect:main start:a end:b]);
		NSColor* color = SliceColor(int(i));
		[[color colorWithAlphaComponent:0.8] setFill];
		NSRectFill(NSMakeRect(x, main.origin.y, 1, main.size.height));
		// Flags shrink to fit when chops sit close together, dropping the note name first.
		const CGFloat next = i + 1 < _starts.size() ? std::round([self xForFrame:_starts[i + 1] inRect:main start:a end:b]) : NSMaxX(main);
		const CGFloat width = std::min<CGFloat>(30, next - x - 2);
		if (width < 8) {
			continue;
		}
		const NSRect flag = NSMakeRect(x, main.origin.y + 6, width, width >= 22 ? 26 : 15);
		FillRounded(flag, 4, color);
		NSRectFill(NSMakeRect(x, flag.origin.y, 4, flag.size.height));  // square edge on the marker side
		NSString* number = [NSString stringWithFormat:@"%zu", i + 1];
		NSDictionary* numberAttrs = TextAttrs(width >= 22 ? 11 : 9, kPage(), NSFontWeightBold);
		if ([number sizeWithAttributes:numberAttrs].width <= width - 3) {
			[number drawAtPoint:NSMakePoint(x + 3, flag.origin.y + 1) withAttributes:numberAttrs];
		}
		if (width >= 22) {
			[NoteName(_rootNote + int(i)) drawAtPoint:NSMakePoint(x + 3, flag.origin.y + 13)
									   withAttributes:TextAttrs(8.5, CSColor(0x0b0c0f, 0.75), NSFontWeightSemibold)];
		}
	}
	for (const auto& [frame, level] : _playheads) {
		if (frame >= a && frame <= b) {
			const CGFloat px = [self xForFrame:frame inRect:main start:a end:b];
			const float brightness = level;
			WithGlow(CSColor(0xffffff, 0.8), 6, ^{
				[[kInk() colorWithAlphaComponent:0.5 + 0.5 * brightness] setFill];
				NSRectFill(NSMakeRect(px, main.origin.y, 2, main.size.height));
			});
		}
	}
	[NSGraphicsContext restoreGraphicsState];
}

- (int)markerNear:(NSPoint)p
{
	const NSRect main = [self mainRect];
	if (!NSPointInRect(p, main)) {
		return -1;
	}
	int best = -1;
	CGFloat bestDist = 6;
	for (size_t i = 0; i < _starts.size(); ++i) {
		const CGFloat x = [self xForFrame:_starts[i] inRect:main start:[self viewStart] end:[self viewEnd]];
		// The number flag at the top of each marker is also a handle.
		const bool onFlag = p.y < main.origin.y + 32 && p.x >= x && p.x <= x + 30;
		const CGFloat dist = onFlag ? 0 : std::abs(p.x - x);
		if (dist < bestDist) {
			bestDist = dist;
			best = int(i);
		}
	}
	return best;
}

- (int)sliceAt:(NSPoint)p
{
	const double f = [self frameForX:p.x inRect:[self mainRect] start:[self viewStart] end:[self viewEnd]];
	int slice = -1;
	for (size_t i = 0; i < _starts.size() && _starts[i] <= f; ++i) {
		slice = int(i);
	}
	return slice;
}

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_tracking) {
		[self removeTrackingArea:_tracking];
	}
	_tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
											 options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
											   owner:self
											userInfo:nil];
	[self addTrackingArea:_tracking];
}

- (void)mouseMoved:(NSEvent*)event
{
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	if (NSPointInRect(p, [self navRect]) || [self markerNear:p] >= 0) {
		[[NSCursor resizeLeftRightCursor] set];
	} else if (NSPointInRect(p, [self mainRect]) && _frames) {
		[[NSCursor pointingHandCursor] set];
	} else {
		[[NSCursor arrowCursor] set];
	}
}

- (void)mouseDown:(NSEvent*)event
{
	[_owner focus];
	if (_frames == 0) {
		return;
	}
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	_drag = kDragNone;
	_auditioning = -1;

	if (NSPointInRect(p, [self navRect])) {
		const NSRect nav = [self navRect];
		const CGFloat x0 = [self xForFrame:[self viewStart] inRect:nav start:0 end:_frames];
		const CGFloat x1 = [self xForFrame:[self viewEnd] inRect:nav start:0 end:_frames];
		const uint32_t f = uint32_t(std::clamp([self frameForX:p.x inRect:nav start:0 end:_frames], 0.0, double(_frames)));
		if (std::abs(p.x - x0) < 6) {
			_drag = kDragRegionStart;
		} else if (std::abs(p.x - x1) < 6) {
			_drag = kDragRegionEnd;
		} else if (p.x > x0 && p.x < x1) {
			_drag = kDragRegionMove;
			_dragOffset = int64_t(f) - int64_t([self viewStart]);
		} else {
			_drag = kDragRegionNew;
			_dragAnchor = f;
		}
		return;
	}

	const int marker = [self markerNear:p];
	if (marker >= 0 && (event.modifierFlags & NSEventModifierFlagOption)) {
		if (_starts.size() > 1) {
			auto starts = _starts;
			starts.erase(starts.begin() + marker);
			[_owner commitSlices:starts];
		}
		return;
	}
	if (event.clickCount == 2) {
		const double f = [self frameForX:p.x inRect:[self mainRect] start:[self viewStart] end:[self viewEnd]];
		if (_starts.size() < size_t(kMaxSlices) && f > _starts.front()) {
			auto starts = _starts;
			starts.push_back(uint32_t(f));
			std::sort(starts.begin(), starts.end());
			[_owner commitSlices:starts];
		}
		return;
	}
	if (marker >= 0) {
		_drag = kDragMarker;
		_dragMarker = marker;
		return;
	}
	const int slice = [self sliceAt:p];
	if (slice >= 0) {
		[_owner selectSlice:slice];
		[_owner audition:slice];
		_auditioning = slice;
	}
}

- (void)mouseDragged:(NSEvent*)event
{
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	if (_drag == kDragMarker) {
		const double f = [self frameForX:p.x inRect:[self mainRect] start:[self viewStart] end:[self viewEnd]];
		const double lo = _dragMarker > 0 ? _starts[_dragMarker - 1] + 64.0 : double([self viewStart]);
		const double hi = size_t(_dragMarker) + 1 < _starts.size() ? _starts[_dragMarker + 1] - 64.0 : double([self viewEnd]) - 64.0;
		_starts[_dragMarker] = uint32_t(std::clamp(f, lo, std::max(lo, hi)));
		self.needsDisplay = YES;
		return;
	}
	const NSRect nav = [self navRect];
	const int64_t f = int64_t(std::clamp([self frameForX:p.x inRect:nav start:0 end:_frames], 0.0, double(_frames)));
	const int64_t minLen = 2048;
	int64_t s = [self viewStart], e = [self viewEnd];
	switch (_drag) {
	case kDragRegionNew:
		s = std::min<int64_t>(_dragAnchor, f);
		e = std::max<int64_t>(_dragAnchor, f);
		break;
	case kDragRegionStart: s = std::min(f, e - minLen); break;
	case kDragRegionEnd: e = std::max(f, s + minLen); break;
	case kDragRegionMove: {
		const int64_t len = e - s;
		s = std::clamp<int64_t>(f - _dragOffset, 0, int64_t(_frames) - len);
		e = s + len;
		break;
	}
	default: return;
	}
	if (e - s < minLen) {
		return;
	}
	_regionStart = uint32_t(std::max<int64_t>(0, s));
	_regionEnd = uint32_t(std::min<int64_t>(_frames, e));
	self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent*)event
{
	if (_drag == kDragMarker) {
		auto starts = _starts;
		std::sort(starts.begin(), starts.end());
		[_owner commitSlices:starts];
	} else if (_drag != kDragNone) {
		[_owner commitRegion:_regionStart end:_regionEnd >= _frames ? 0 : _regionEnd];
	} else if (_auditioning >= 0) {
		[_owner releaseSlice:_auditioning];
	}
	_drag = kDragNone;
	_auditioning = -1;
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Pads

static const int kNoKey = -10000;

@interface ChipmunkSoulPads_v1 () <NSDraggingSource>
@end

@implementation ChipmunkSoulPads_v1 {
	int _pressed;
	NSPoint _downPoint;
	BOOL _dragging;
}
- (BOOL)isFlipped { return YES; }
// Drops land on whichever child is under the cursor; hand them to the main view.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info { return [_owner draggingEntered:info]; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [_owner draggingUpdated:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [_owner draggingExited:info]; }
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info { return YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info { return [_owner performDragOperation:info]; }

- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

// The keyboard spans whole octaves around the chops: chop i sits on note rootNote + i, and keys
// without a chop are drawn but inactive. (The drums have their own pads.)
- (int)firstNote { return _rootNote - _rootNote % 12; }
- (int)lastNote { return std::max(_rootNote + std::max(_count, 12) - 1, [self firstNote] + 11) / 12 * 12 + 11; }

- (int)whiteKeysBefore:(int)note
{
	int n = 0;
	for (int k = [self firstNote]; k < note; ++k) {
		n += !IsBlackKey(k);
	}
	return n;
}

- (NSRect)rectForNote:(int)note
{
	const int whites = [self whiteKeysBefore:[self lastNote] + 1];
	const CGFloat w = self.bounds.size.width / whites, h = self.bounds.size.height;
	if (IsBlackKey(note)) {
		const CGFloat bw = w * 0.6;
		return NSMakeRect(std::round([self whiteKeysBefore:note] * w - bw / 2), 0, std::round(bw), std::round(h * 0.6));
	}
	const CGFloat x0 = std::round([self whiteKeysBefore:note] * w), x1 = std::round(([self whiteKeysBefore:note] + 1) * w);
	return NSMakeRect(x0, 0, x1 - x0 + 1, h);  // +1 so neighbouring keys share one rule
}

- (void)drawKey:(int)note
{
	NSRect r = [self rectForNote:note];
	const int slice = note - _rootNote;
	const bool black = IsBlackKey(note);
	const bool active = slice >= 0 && slice < _count;
	const float level = active && slice < int(_levels.size()) ? _levels[size_t(slice)] : 0.f;
	if (!black) {
		r = NSInsetRect(r, 1, 0);  // a hairline gap between white keys
	}

	// Keys hang from the top: square top edge, rounded bottom.
	const CGFloat radius = black ? 4 : 6;
	NSBezierPath* shape = Rounded(r, radius);
	[shape appendBezierPathWithRect:NSMakeRect(r.origin.x, r.origin.y, r.size.width, radius)];
	shape.windingRule = NSWindingRuleNonZero;

	NSGradient* fill;
	if (level > 0.05f) {
		fill = AccentGradient();
	} else if (black) {
		fill = [[NSGradient alloc] initWithStartingColor:CSColor(active ? 0x34373f : 0x24262c) endingColor:CSColor(active ? 0x111216 : 0x15161a)];
	} else {
		fill = [[NSGradient alloc] initWithStartingColor:CSColor(active ? 0xf5f6f9 : 0x3a3d45) endingColor:CSColor(active ? 0xd6d9e0 : 0x2c2f36)];
	}
	if (level > 0.05f) {
		WithGlow(CSColor(0xff6a55, 0.7 * level), 12, ^{
			[fill drawInBezierPath:shape angle:black ? 90 : 0];
		});
	} else {
		[fill drawInBezierPath:shape angle:90];
	}
	if (!active) {
		return;
	}
	const bool lit = level > 0.05f;
	if (slice == _selected) {
		NSBezierPath* ring = Rounded(NSInsetRect(r, 1.5, 1.5), radius);
		ring.lineWidth = 2.5;
		[kAccent() setStroke];
		[ring stroke];
	}
	const int group = slice < int(_groups.size()) ? _groups[size_t(slice)] : 0;

	NSColor* text = lit || black ? CSColor(0xffffff) : CSColor(0x15171c);
	NSDictionary* number = TextAttrs(black ? 10 : 12, text, NSFontWeightBold);
	NSString* label = [NSString stringWithFormat:@"%d", slice + 1];
	const CGFloat bottom = r.origin.y + r.size.height - (black ? 7 : 9);
	const NSSize ns = [label sizeWithAttributes:number];
	[label drawAtPoint:NSMakePoint(NSMidX(r) - ns.width / 2, bottom - ns.height) withAttributes:number];

	const int keyIndex = slice - _keyOffset;
	if (keyIndex >= 0 && keyIndex < kNumPadKeys) {
		NSString* key = [@"⇧" stringByAppendingString:kPadKeys[keyIndex].label];
		NSColor* keyColor = lit ? CSColor(0xffffff, 0.85) : black ? CSColor(0xffa27a) : CSColor(0xe0531f);
		NSDictionary* keyAttrs = TextAttrs(black ? 9 : 10.5, keyColor, NSFontWeightSemibold);
		const NSSize ks = [key sizeWithAttributes:keyAttrs];
		[key drawAtPoint:NSMakePoint(NSMidX(r) - ks.width / 2, bottom - ns.height - ks.height) withAttributes:keyAttrs];
	}
	if (group > 0) {
		// Black keys: at the top. White keys: stacked above the Shift-key label.
		const CGFloat d = black ? 15 : 17;
		const CGFloat y = black ? r.origin.y + 8 : bottom - ns.height - 15 - d - 3;
		const NSRect badge = NSMakeRect(NSMidX(r) - d / 2, y, d, d);
		[GroupColor(group) setFill];
		[[NSBezierPath bezierPathWithOvalInRect:badge] fill];
		DrawCentered(GroupName(group), NSOffsetRect(badge, 0, 0.5), TextAttrs(black ? 9 : 10, CSColor(0x0b0c0f), NSFontWeightBold));
	}
	if (note % 12 == 0) {
		[NoteName(note) drawAtPoint:NSMakePoint(r.origin.x + 6, r.origin.y + 6)
					 withAttributes:TextAttrs(9, lit ? CSColor(0xffffff, 0.8) : CSColor(0x6b7080), NSFontWeightMedium)];
	}
}

- (void)drawRect:(NSRect)dirty
{
	for (int note = [self firstNote]; note <= [self lastNote]; ++note) {
		if (!IsBlackKey(note)) {
			[self drawKey:note];
		}
	}
	for (int note = [self firstNote]; note <= [self lastNote]; ++note) {
		if (IsBlackKey(note)) {
			[self drawKey:note];
		}
	}
}

// Chop index of the key under the point, or kNoKey when the key has no chop.
- (int)keyAt:(NSPoint)p
{
	for (int pass = 0; pass < 2; ++pass) {  // black keys sit on top
		for (int note = [self firstNote]; note <= [self lastNote]; ++note) {
			if (IsBlackKey(note) == (pass == 0) && NSPointInRect(p, [self rectForNote:note])) {
				const int offset = note - _rootNote;
				return offset >= 0 && offset < _count ? offset : kNoKey;
			}
		}
	}
	return kNoKey;
}

- (void)mouseDown:(NSEvent*)event
{
	[_owner focus];
	_downPoint = [self convertPoint:event.locationInWindow fromView:nil];
	_dragging = NO;
	const int slice = [self keyAt:_downPoint];
	_pressed = -1;
	if (slice == kNoKey) {
		return;
	}
	if (event.modifierFlags & NSEventModifierFlagOption) {
		[_owner cycleGroupOf:slice];  // ⌥-click: Off → A → B → C → D → Off
		return;
	}
	_pressed = slice;
	[_owner selectSlice:slice];
	[_owner audition:slice];
}

- (void)mouseUp:(NSEvent*)event
{
	if (_pressed >= 0) {
		[_owner releaseSlice:_pressed];
		_pressed = -1;
	}
}

// Dragging a chop key out of the window exports that chop as a WAV and drags the file, so it can
// be dropped onto a GarageBand track.
- (void)mouseDragged:(NSEvent*)event
{
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	if (_pressed < 0 || _dragging || std::hypot(p.x - _downPoint.x, p.y - _downPoint.y) < 6) {
		return;
	}
	_dragging = YES;
	const int slice = _pressed;
	[_owner releaseSlice:slice];
	_pressed = -1;
	NSURL* url = [_owner exportChop:slice];
	if (!url) {
		return;
	}
	NSString* title = [NSString stringWithFormat:@"Chop %d", slice + 1];
	NSImage* image = [NSImage imageWithSize:NSMakeSize(96, 28) flipped:NO drawingHandler:^BOOL(NSRect rect) {
		[AccentGradient() drawInBezierPath:Rounded(rect, 8) angle:0];
		DrawCentered(title, rect, TextAttrs(12, CSColor(0xffffff), NSFontWeightBold));
		return YES;
	}];
	NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
	[item setDraggingFrame:NSMakeRect(p.x - 48, p.y - 14, 96, 28) contents:image];
	[self beginDraggingSessionWithItems:@[ item ] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
	return NSDragOperationCopy;
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Drum pads

// ⇧1 … ⇧9, ⇧0 play the ten drum pads (physical key codes of the number row).
static const unsigned short kDrumKeyCodes[kNumDrums] = { 18, 19, 20, 21, 23, 22, 26, 28, 25, 29 };
static NSString* const kDrumKeyLabels[kNumDrums] = { @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"0" };

@interface ChipmunkSoulDrumPads_v1 : NSView
@property (nonatomic, weak) ChipmunkSoulView_v1* owner;
@property (nonatomic) std::vector<float> levels;  // per drum, for the hit flash
@end

@implementation ChipmunkSoulDrumPads_v1

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (NSRect)rectForPad:(int)i
{
	const CGFloat gap = 6, w = (self.bounds.size.width - gap * CGFloat(kNumDrums - 1)) / CGFloat(kNumDrums);
	return NSMakeRect(std::round(i * (w + gap)), 0, std::round(w), self.bounds.size.height);
}

- (void)drawRect:(NSRect)dirty
{
	for (int i = 0; i < kNumDrums; ++i) {
		const NSRect r = [self rectForPad:i];
		const float level = i < int(_levels.size()) ? _levels[size_t(i)] : 0.f;
		const bool lit = level > 0.05f;
		NSBezierPath* shape = Rounded(r, 8);
		if (lit) {
			WithGlow(CSColor(0xff6a55, 0.7 * level), 12, ^{
				[AccentGradient() drawInBezierPath:shape angle:0];
			});
		} else {
			[[[NSGradient alloc] initWithStartingColor:CSColor(0x2c3039) endingColor:CSColor(0x1d2027)] drawInBezierPath:shape angle:90];
		}
		StrokeRounded(r, 8, kRule());
		DrawCentered(@(kDrumNames[i]), NSOffsetRect(r, 0, 5), TextAttrs(12, lit ? CSColor(0xffffff) : kInk(), NSFontWeightSemibold));
		[[@"⇧" stringByAppendingString:kDrumKeyLabels[i]] drawAtPoint:NSMakePoint(r.origin.x + 7, r.origin.y + 4)
															 withAttributes:TextAttrs(10, lit ? CSColor(0xffffff, 0.85) : kAccent(), NSFontWeightSemibold)];
	}
}

- (void)mouseDown:(NSEvent*)event
{
	[_owner focus];
	const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	for (int i = 0; i < kNumDrums; ++i) {
		if (NSPointInRect(p, [self rectForPad:i])) {
			[_owner playDrum:i];
			return;
		}
	}
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Recorded take

// A chip holding the last recorded take; drag it onto a GarageBand track to drop it in as a MIDI
// region.
@interface ChipmunkSoulClip_v1 : NSView <NSDraggingSource>
@property (nonatomic, weak) ChipmunkSoulView_v1* owner;
@property (nonatomic, copy) NSString* text;
@property (nonatomic) BOOL ready;
@end

// ---- importing songs -----------------------------------------------------------------------------

// Music › Chipmunk Soul: the one place GarageBand's plug-in helper can always read songs from.
static NSURL* SongFolder()
{
	NSURL* folder = [[NSFileManager.defaultManager URLsForDirectory:NSMusicDirectory inDomains:NSUserDomainMask].firstObject
		URLByAppendingPathComponent:@"Chipmunk Soul"];
	[NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
	return folder;
}

// Asks Finder to do the copy. Used when macOS won't let the plug-in read the original itself
// (the first time, macOS asks whether GarageBand may control Finder).
static BOOL FinderCopy(NSURL* src, NSURL* dest)
{
	NSString* (^quoted)(NSString*) = ^(NSString* s) {
		return [NSString stringWithFormat:@"\"%@\"",
						 [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
	};
	NSString* script = [NSString stringWithFormat:
		@"tell application \"Finder\"\n"
		 "set f to duplicate (POSIX file %@ as alias) to (POSIX file %@ as alias)\n"
		 "set name of f to %@\n"
		 "end tell",
		quoted(src.path), quoted(dest.URLByDeletingLastPathComponent.path), quoted(dest.lastPathComponent)];
	NSTask* task = [[NSTask alloc] init];
	task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
	task.arguments = @[ @"-e", script ];
	task.standardOutput = task.standardError = [NSFileHandle fileHandleWithNullDevice];
	if (![task launchAndReturnError:nil]) {
		return NO;
	}
	[task waitUntilExit];
	return task.terminationStatus == 0 && [NSFileManager.defaultManager fileExistsAtPath:dest.path];
}

// Copies a song into the song folder and returns the copy. A song that's already there, or was
// imported before (same name and size), isn't copied again; a different song with the same name gets " 2".
static NSURL* ImportSong(NSURL* src, NSString** error)
{
	NSFileManager* fm = NSFileManager.defaultManager;
	NSURL* folder = SongFolder().URLByStandardizingPath.URLByResolvingSymlinksInPath;
	NSURL* source = src.URLByStandardizingPath.URLByResolvingSymlinksInPath;
	if ([source.URLByDeletingLastPathComponent.path isEqualToString:folder.path]) {
		return src;
	}
	const BOOL scoped = [src startAccessingSecurityScopedResource];
	NSNumber* size = nil;
	[src getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
	NSString* base = src.lastPathComponent.stringByDeletingPathExtension, *ext = src.pathExtension;
	NSURL* dest = [folder URLByAppendingPathComponent:src.lastPathComponent];
	for (int n = 2; [fm fileExistsAtPath:dest.path]; ++n) {
		NSNumber* existing = [fm attributesOfItemAtPath:dest.path error:nil][NSFileSize];
		if (size && [existing isEqual:size]) {
			break;  // imported before
		}
		NSString* name = [NSString stringWithFormat:@"%@ %d", base, n];
		dest = [folder URLByAppendingPathComponent:ext.length ? [name stringByAppendingPathExtension:ext] : name];
	}
	BOOL ok = [fm fileExistsAtPath:dest.path] || [fm copyItemAtURL:src toURL:dest error:nil] || FinderCopy(src, dest);
	if (scoped) {
		[src stopAccessingSecurityScopedResource];
	}
	if (!ok && error) {
		*error = [NSString stringWithFormat:@"Couldn't copy %@. Move it into Music > Chipmunk Soul in Finder", src.lastPathComponent];
	}
	return ok ? dest : nil;
}

@interface ChipmunkSoulView_v1 (Takes)
- (NSURL*)writeTake;
@end

@implementation ChipmunkSoulClip_v1

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)drawRect:(NSRect)dirty
{
	const NSRect b = self.bounds;
	if (_ready) {
		[[[NSGradient alloc] initWithStartingColor:CSColor(0x3a2620) endingColor:CSColor(0x2a1d24)] drawInBezierPath:Rounded(b, 8) angle:0];
		StrokeRounded(b, 8, [kAccent() colorWithAlphaComponent:0.8]);
	} else {
		FillRounded(b, 8, kRaised());
		StrokeRounded(b, 8, kRule());
	}
	// A little MIDI-region glyph: three notes on a strip.
	const NSRect glyph = NSMakeRect(8, NSMidY(b) - 7, 18, 14);
	FillRounded(glyph, 3, _ready ? kAccent() : kRaisedHover());
	[(_ready ? CSColor(0x0b0c0f) : kMuted()) setFill];
	NSRectFill(NSMakeRect(glyph.origin.x + 3, glyph.origin.y + 3, 5, 2));
	NSRectFill(NSMakeRect(glyph.origin.x + 7, glyph.origin.y + 7, 6, 2));
	NSRectFill(NSMakeRect(glyph.origin.x + 11, glyph.origin.y + 10, 4, 2));
	NSDictionary* attrs = TextAttrs(12, _ready ? kInk() : kMuted(), NSFontWeightSemibold);
	const NSSize ts = [_text sizeWithAttributes:attrs];
	[_text drawAtPoint:NSMakePoint(32, NSMidY(b) - ts.height / 2) withAttributes:attrs];
}

- (void)mouseDown:(NSEvent*)event
{
	if (!_ready) {
		return;
	}
	NSURL* url = [_owner writeTake];
	if (!url) {
		return;
	}
	NSString* title = _text;
	const NSSize size = self.bounds.size;
	NSImage* image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
		[AccentGradient() drawInBezierPath:Rounded(rect, 8) angle:0];
		DrawCentered(title, rect, TextAttrs(12, CSColor(0xffffff), NSFontWeightBold));
		return YES;
	}];
	NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
	[item setDraggingFrame:self.bounds contents:image];
	[self beginDraggingSessionWithItems:@[ item ] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context
{
	return NSDragOperationCopy;
}
@end

// -------------------------------------------------------------------------------------------------
#pragma mark - Main view

static void EventListenerProc(void* refCon, void* object, const AudioUnitEvent* event, UInt64, AudioUnitParameterValue value);

@implementation ChipmunkSoulView_v1 {
	AudioUnit _au;
	AUEventListenerRef _listener;
	NSTimer* _timer;
	id _keyMonitor;
	NSTrackingArea* _hoverArea;
	int _tick;

	ChipmunkSoulWaveform_v1* _wave;
	ChipmunkSoulPads_v1* _pads;
	NSTextField* _fileLabel;
	NSTextField* _bpmLabel;
	NSTextField* _statusLabel;
	ChipmunkSoulButton_v1* _syncBox;
	NSArray<ChipmunkSoulButton_v1*>* _modeButtons;    // tag = ChopMode
	NSArray<ChipmunkSoulButton_v1*>* _lengthButtons;  // tag = beats
	ChipmunkSoulSlider_v1* _sensitivity;
	NSTextField* _sensitivityLabel;
	ChipmunkSoulButton_v1* _choke;
	NSArray<ChipmunkSoulButton_v1*>* _groupButtons;  // tag = mute group
	NSTextField* _groupLabel;
	NSTextField* _chopLabel;
	ChipmunkSoulSlider_v1* _chopPitch;
	ChipmunkSoulSlider_v1* _chopGain;
	ChipmunkSoulButton_v1* _chopReverse;
	ChipmunkSoulButton_v1* _keepPitch;
	NSArray<ChipmunkSoulButton_v1*>* _endButtons;  // tag = EndMode
	ChipmunkSoulButton_v1* _instantPlay;
	ChipmunkSoulDrumPads_v1* _drumPads;
	NSPopUpButton* _kitMenu;
	ChipmunkSoulButton_v1* _recordButton;
	ChipmunkSoulButton_v1* _quantize;
	ChipmunkSoulClip_v1* _clip;
	BOOL _recording;
	int _takeNumber;
	std::vector<RecordedNote> _take;
	std::vector<ChopEdit> _edits;
	struct Snapshot {
		std::vector<uint32_t> starts;
		uint32_t regionStart, regionEnd;
		ChopSettings settings;
	};
	std::vector<Snapshot> _undo, _redo;
	ChipmunkSoulButton_v1* _reverse;
	NSMutableDictionary<NSNumber*, ChipmunkSoulKnob_v1*>* _knobs;

	double _sampleBPM, _hostBPM, _tempoRatio;
	ChopSettings _chop;
	BOOL _busy;
	BOOL _dropHighlight;
	double _playingPitch;
	int _selectedSlice;
	std::vector<uint8_t> _groups;
	NSString* _lastStatus;
	int _heldKeys[128];  // slice held down by each key code, -1 if up
	double _sampleRate;
	int _picks;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithAudioUnit:(AudioUnit)au
{
	self = [super initWithFrame:NSMakeRect(0, 0, 980, kViewHeight)];
	if (!self) {
		return nil;
	}
	_au = au;
	_knobs = [NSMutableDictionary dictionary];
	std::fill(std::begin(_heldKeys), std::end(_heldKeys), -1);
	self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
	[self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
	[self buildUI];
	[self startListening];
	[self setEditorOpen:YES];
	[self refreshAll];
	return self;
}

- (void)dealloc
{
	[self stop];
}

- (void)setEditorOpen:(BOOL)open
{
	int32_t value = open ? 1 : 0;
	AudioUnitSetProperty(_au, kProp_EditorOpen, kAudioUnitScope_Global, 0, &value, sizeof(value));
}

- (void)stop
{
	[self setEditorOpen:NO];
	[_timer invalidate];
	_timer = nil;
	[self stopKeyMonitor];
	if (_listener) {
		AUListenerDispose(_listener);
		_listener = nullptr;
	}
}

- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if (!self.window) {
		[_timer invalidate];
		_timer = nil;
		[self stopKeyMonitor];
		[self setEditorOpen:NO];
	} else if (!_timer) {
		[self startKeyMonitor];
		[self setEditorOpen:YES];
		__weak ChipmunkSoulView_v1* weakSelf = self;
		_timer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer*) { [weakSelf tick]; }];
		[[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
		dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf focus]; });
	}
}

// ---- laptop keyboard -----------------------------------------------------------------------------

- (BOOL)acceptsFirstResponder { return YES; }

// GarageBand 10.4.14 shows the editor inside its own plug-in window (a remote view), and that window
// only takes the keyboard when the clicked view asks for it. Without this, keys go to GarageBand.
- (BOOL)needsPanelToBecomeKey { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }

- (void)focus
{
	if (self.window.firstResponder != self) {
		[self.window makeFirstResponder:self];
	}
}

- (void)mouseDown:(NSEvent*)event
{
	[self focus];
}

// Every key that reaches the plug-in window is handled here, whichever control in it has focus
// (after clicking the kit menu, say). Keys aren't passed on: a stray key would make the system beep
// (the screen flash) or let GarageBand act on it. ⌘ shortcuts still go through normally.
- (void)startKeyMonitor
{
	if (_keyMonitor) {
		return;
	}
	__weak ChipmunkSoulView_v1* weakSelf = self;
	_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
														handler:^NSEvent*(NSEvent* event) {
		ChipmunkSoulView_v1* view = weakSelf;
		if (!view || !view.window || event.window != view.window || (event.modifierFlags & NSEventModifierFlagCommand)) {
			return event;
		}
		if (event.type == NSEventTypeKeyDown) {
			[view handleKeyDown:event];
		} else {
			[view handleKeyUp:event];
		}
		return nil;
	}];
}

- (void)stopKeyMonitor
{
	if (_keyMonitor) {
		[NSEvent removeMonitor:_keyMonitor];
		_keyMonitor = nil;
	}
}

// Pointing at the plug-in gives it the keyboard, so Shift+keys play it without clicking first.
- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_hoverArea) {
		[self removeTrackingArea:_hoverArea];
	}
	_hoverArea = [[NSTrackingArea alloc] initWithRect:self.bounds
											  options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
												owner:self
											 userInfo:nil];
	[self addTrackingArea:_hoverArea];
}

- (void)mouseEntered:(NSEvent*)event
{
	if (!self.window.isKeyWindow) {
		[self.window makeKeyWindow];
	}
	[self focus];
}

- (void)keyDown:(NSEvent*)event
{
	if (event.modifierFlags & NSEventModifierFlagCommand) {
		[super keyDown:event];  // ⌘ shortcuts belong to GarageBand
		return;
	}
	[self handleKeyDown:event];
}

- (void)handleKeyDown:(NSEvent*)event
{
	const NSEventModifierFlags mods = event.modifierFlags;
	const BOOL shiftOnly = (mods & NSEventModifierFlagShift) && !(mods & (NSEventModifierFlagControl | NSEventModifierFlagOption));
	if (!shiftOnly || event.isARepeat || event.keyCode >= 128) {
		return;
	}
	for (int d = 0; d < kNumDrums; ++d) {
		if (kDrumKeyCodes[d] == event.keyCode) {
			[self playDrum:d];
			return;
		}
	}
	if (event.keyCode == kOctaveDownKey || event.keyCode == kOctaveUpKey) {
		const int step = event.keyCode == kOctaveUpKey ? 12 : -12;
		const int maxOffset = std::max(0, (_pads.count - 1) / 12 * 12);
		_pads.keyOffset = std::clamp(_pads.keyOffset + step, 0, maxOffset);
		_pads.needsDisplay = YES;
		return;
	}
	for (int i = 0; i < kNumPadKeys; ++i) {
		if (kPadKeys[i].keyCode == event.keyCode) {
			const int slice = _pads.keyOffset + i;
			if (slice >= 0 && slice < _pads.count) {
				_heldKeys[event.keyCode] = slice;
				[self selectSlice:slice];
				[self audition:slice];
			}
			return;
		}
	}
}

- (BOOL)performKeyEquivalent:(NSEvent*)event
{
	const NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
	if (event.keyCode == 6 && (mods & NSEventModifierFlagCommand)) {  // ⌘Z / ⇧⌘Z
		if (mods & NSEventModifierFlagShift) {
			[self redo:nil];
		} else {
			[self undo:nil];
		}
		return YES;
	}
	return [super performKeyEquivalent:event];
}

// Releases don't need Shift: letting go of Shift first must not leave a note hanging.
- (void)keyUp:(NSEvent*)event
{
	if (event.modifierFlags & NSEventModifierFlagCommand) {
		[super keyUp:event];
		return;
	}
	[self handleKeyUp:event];
}

- (void)handleKeyUp:(NSEvent*)event
{
	if (event.keyCode < 128 && _heldKeys[event.keyCode] >= 0) {
		[self releaseSlice:_heldKeys[event.keyCode]];
		_heldKeys[event.keyCode] = -1;
	}
}

- (void)drawPanel:(NSString*)title top:(CGFloat)top bottom:(CGFloat)bottom note:(NSString*)note leftNote:(NSString*)leftNote
{
	const CGFloat w = self.bounds.size.width - 2 * kMargin;
	const NSRect panel = NSMakeRect(kMargin, top, w, bottom - top);
	FillRounded(panel, 14, kSurface());
	StrokeRounded(panel, 14, kRule());
	NSDictionary* heading = @{ NSFontAttributeName : CSDisplay(18), NSForegroundColorAttributeName : kInk() };
	const NSSize hs = [title sizeWithAttributes:heading];
	[title drawAtPoint:NSMakePoint(kMargin + 14, top + (kBarHeight - hs.height) / 2 + 3) withAttributes:heading];
	if (leftNote) {
		NSDictionary* attrs = TextAttrs(11, CSColor(0x6b7080));
		const NSSize ns = [leftNote sizeWithAttributes:attrs];
		[leftNote drawAtPoint:NSMakePoint(kMargin + 14 + hs.width + 12, top + (kBarHeight - ns.height) / 2 + 3) withAttributes:attrs];
	}
	if (note) {
		NSDictionary* attrs = TextAttrs(11, CSColor(0x6b7080));
		const NSSize ns = [note sizeWithAttributes:attrs];
		[note drawAtPoint:NSMakePoint(kMargin + w - 14 - ns.width, top + (kBarHeight - ns.height) / 2 + 2) withAttributes:attrs];
	}
}

- (void)drawRect:(NSRect)dirty
{
	[kPage() setFill];
	NSRectFill(self.bounds);
	// A soft warm glow behind the header.
	NSGradient* glow = [[NSGradient alloc] initWithStartingColor:CSColor(0xff6a45, 0.12) endingColor:CSColor(0xff6a45, 0.0)];
	[glow drawFromCenter:NSMakePoint(120, -40) radius:0 toCenter:NSMakePoint(120, -40) radius:420 options:0];

	// Logo: a gradient tile with a minigun on it (an homage to a certain cyborg from the future).
	const NSRect tile = NSMakeRect(kMargin, 16, 40, 40);
	WithGlow(CSColor(0xff5f6a, 0.5), 12, ^{
		[AccentGradient() drawInBezierPath:Rounded(tile, 11) angle:-45];
	});
	[NSGraphicsContext saveGraphicsState];
	NSAffineTransform* tilt = [NSAffineTransform transform];
	[tilt translateXBy:NSMidX(tile) yBy:NSMidY(tile)];
	[tilt rotateByDegrees:-12];
	[tilt translateXBy:-NSMidX(tile) yBy:-NSMidY(tile)];
	[tilt concat];
	const CGFloat ox = tile.origin.x, oy = tile.origin.y;
	[CSColor(0xffffff) setFill];
	for (int b = 0; b < 3; ++b) {  // the rotating barrels
		[Rounded(NSMakeRect(ox + 4, oy + 14 + b * 3.2, 18, 2.2), 1.1) fill];
	}
	[Rounded(NSMakeRect(ox + 3, oy + 13, 3, 9.5), 1) fill];        // muzzle clamp
	[Rounded(NSMakeRect(ox + 13, oy + 13, 2.5, 9.5), 1) fill];     // barrel clamp
	[Rounded(NSMakeRect(ox + 21, oy + 12, 11, 11), 3) fill];      // motor housing
	[Rounded(NSMakeRect(ox + 31, oy + 14.5, 5, 6), 1.5) fill];    // rear handle
	[Rounded(NSMakeRect(ox + 24, oy + 22, 3.5, 8), 1.5) fill];    // grip
	NSBezierPath* belt = [NSBezierPath bezierPath];                // ammo belt sweeping down
	[belt moveToPoint:NSMakePoint(ox + 22, oy + 22)];
	[belt curveToPoint:NSMakePoint(ox + 12, oy + 31) controlPoint1:NSMakePoint(ox + 19, oy + 27) controlPoint2:NSMakePoint(ox + 16, oy + 30)];
	belt.lineWidth = 2.4;
	belt.lineCapStyle = NSLineCapStyleRound;
	[CSColor(0xffffff) setStroke];
	[belt stroke];
	[NSGraphicsContext restoreGraphicsState];
	[@"Arnold Chopper" drawAtPoint:NSMakePoint(kMargin + 52, 11)
				   withAttributes:@{ NSFontAttributeName : CSDisplay(25, NSFontWeightBold), NSForegroundColorAttributeName : kInk() }];
	[@"Auto-chop sampler" drawAtPoint:NSMakePoint(kMargin + 53, 41) withAttributes:TextAttrs(12, kMuted(), NSFontWeightMedium)];

	[self drawPanel:@"Song" top:kSongTop bottom:kSongBottom
			   note:nil
		   leftNote:nil];
	[self drawPanel:@"Keys" top:kKeysTop bottom:kKeysBottom
			   note:nil
		   leftNote:@"⇧+keys: chops · ⇧1–⇧0: drums · ⌥-click: mute group · drag a key to export"];
	[self drawPanel:@"Sound" top:kSoundTop bottom:kSoundBottom note:nil leftNote:nil];

	if (_dropHighlight) {
		NSBezierPath* border = Rounded(NSInsetRect(self.bounds, 3, 3), 16);
		border.lineWidth = 3;
		[kAccent() setStroke];
		[border stroke];
	}
}

// ---- building ------------------------------------------------------------------------------------

- (NSTextField*)label:(NSRect)frame size:(CGFloat)size color:(NSColor*)color weight:(NSFontWeight)weight
{
	NSTextField* t = [NSTextField labelWithString:@""];
	t.frame = frame;
	t.font = CSBody(size, weight);
	t.drawsBackground = NO;
	t.textColor = color;
	t.lineBreakMode = NSLineBreakByTruncatingMiddle;
	[self addSubview:t];
	return t;
}

- (ChipmunkSoulButton_v1*)button:(NSString*)title kind:(CSButtonKind)kind frame:(NSRect)frame action:(SEL)action
{
	ChipmunkSoulButton_v1* b = [ChipmunkSoulButton_v1 buttonWithTitle:title kind:kind target:self action:action];
	b.frame = frame;
	[self addSubview:b];
	return b;
}

// A row of adjoining choice buttons that behaves like a segmented control.
- (NSArray<ChipmunkSoulButton_v1*>*)choices:(NSArray<NSString*>*)titles tags:(NSArray<NSNumber*>*)tags
									  frame:(NSRect)frame action:(SEL)action
{
	NSMutableArray* group = [NSMutableArray array];
	for (NSUInteger i = 0; i < titles.count; ++i) {
		ChipmunkSoulButton_v1* b = [self button:titles[i] kind:CSButtonChoice frame:NSZeroRect action:action];
		b.tag = tags[i].integerValue;
		[group addObject:b];
	}
	std::vector<CGFloat> widths(titles.count, (frame.size.width + titles.count - 1) / titles.count);
	[self join:group x:frame.origin.x y:frame.origin.y height:frame.size.height widths:widths];
	return group;
}

// Lays buttons side by side as one joined group (neighbours share their 1 px border).
- (void)join:(NSArray<ChipmunkSoulButton_v1*>*)buttons x:(CGFloat)x y:(CGFloat)y height:(CGFloat)h widths:(const std::vector<CGFloat>&)widths
{
	for (NSUInteger i = 0; i < buttons.count; ++i) {
		buttons[i].frame = NSMakeRect(std::round(x), y, std::round(widths[i]), h);
		buttons[i].segment = buttons.count == 1 ? CSSegmentSolo : i == 0 ? CSSegmentFirst : i + 1 == buttons.count ? CSSegmentLast : CSSegmentMiddle;
		x += widths[i] - 1;
	}
}

- (void)select:(NSInteger)tag in:(NSArray<ChipmunkSoulButton_v1*>*)group
{
	for (ChipmunkSoulButton_v1* b in group) {
		b.state = b.tag == tag ? NSControlStateValueOn : NSControlStateValueOff;
		if (b.state == NSControlStateValueOn) {
			[self addSubview:b positioned:NSWindowAbove relativeTo:nil];  // its accent border on top
		}
	}
}

- (NSInteger)selectedIn:(NSArray<ChipmunkSoulButton_v1*>*)group
{
	for (ChipmunkSoulButton_v1* b in group) {
		if (b.state == NSControlStateValueOn) {
			return b.tag;
		}
	}
	return group.firstObject.tag;
}

- (void)buildUI
{
	const CGFloat W = self.bounds.size.width;
	const CGFloat left = kMargin + 12, right = W - kMargin - 12;

	// Header.
	// The recorder sits in the header, between the title and Load Song.
	_recordButton = [self button:@"\u25cf Record" kind:CSButtonChoice frame:NSMakeRect(278, 20, 100, 32) action:@selector(toggleRecording:)];
	_recordButton.toolTip = @"Record everything you play (keys, pads, drums, MIDI). Timed to the song when GarageBand is playing.";
	_quantize = [self button:@"Quantize" kind:CSButtonCheck frame:NSMakeRect(388, 25, 100, 22) action:@selector(quantizeChanged:)];
	_quantize.toolTip = @"Snap the take to 16th notes when it's dragged out.";
	_clip = [[ChipmunkSoulClip_v1 alloc] initWithFrame:NSMakeRect(494, 20, 126, 32)];
	_clip.owner = self;
	_clip.text = @"No take yet";
	_clip.toolTip = @"Drag the take onto a GarageBand track: it lands as a MIDI region you can edit and rearrange.";
	[self addSubview:_clip];

	// The song's name and status sit in the Song panel's title bar.
	_fileLabel = [self label:NSMakeRect(left + 64, kSongTop + 8, 330, 20) size:13 color:kInk() weight:NSFontWeightSemibold];
	_statusLabel = [self label:NSMakeRect(left + 404, kSongTop + 9, 380, 18) size:12 color:kMuted() weight:NSFontWeightMedium];
	ChipmunkSoulButton_v1* import = [self button:@"Import" kind:CSButtonSecondary frame:NSZeroRect action:@selector(importAudio:)];
	import.toolTip = @"Copy songs from anywhere (Downloads, Desktop, a drive…) into Music \u203a Chipmunk Soul and load the first one";
	ChipmunkSoulButton_v1* load = [self button:@"Load Song" kind:CSButtonPrimary frame:NSZeroRect action:@selector(openFile:)];
	load.toolTip = @"Load a song from Music \u203a Chipmunk Soul";
	[self join:@[ import, load ] x:630 y:18 height:34 widths:{ 70, 90 }];
	_bpmLabel = [self label:NSMakeRect(796, 13, right - 796 + 12, 20) size:13 color:kInk() weight:NSFontWeightSemibold];
	_bpmLabel.alignment = NSTextAlignmentRight;
	_syncBox = [self button:@"Sync to tempo" kind:CSButtonCheck frame:NSMakeRect(796, 38, 172, 22) action:@selector(togglesChanged:)];
	_syncBox.toolTip = @"Speeds the sample up (or down) so its tempo locks to your GarageBand project tempo, "
					   @"and follows tempo changes (a faster project pitches the record up). "
					   @"Turn off, or grab the Pitch knob, to set pitch yourself.";

	// Song panel: undo/redo in the header, the waveform, then the chop controls.
	ChipmunkSoulButton_v1* undo = [self button:@"Undo" kind:CSButtonSecondary frame:NSZeroRect action:@selector(undo:)];
	ChipmunkSoulButton_v1* redo = [self button:@"Redo" kind:CSButtonSecondary frame:NSZeroRect action:@selector(redo:)];
	undo.toolTip = @"Undo the last chop edit (\u2318Z)";
	redo.toolTip = @"Redo (\u21e7\u2318Z)";
	[self join:@[ undo, redo ] x:right - 130 y:kSongTop + 6 height:26 widths:{ 66, 65 }];

	const CGFloat songBody = kSongTop + kBarHeight + 12;
	_wave = [[ChipmunkSoulWaveform_v1 alloc] initWithFrame:NSMakeRect(left, songBody, right - left, 190)];
	_wave.owner = self;
	_wave.toolTip = @"Drag the top strip to pick a part \u00b7 drag a marker to move it \u00b7 double-click to add one \u00b7 \u2325-click to delete";
	[_wave registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
	[self addSubview:_wave];

	const CGFloat cy = songBody + 190 + 12;
	_lengthButtons = [self choices:@[ @"1 bar", @"2", @"4", @"8" ] tags:@[ @4, @8, @16, @32 ]
							 frame:NSMakeRect(left, cy, 160, 32)
							action:@selector(choiceClicked:)];
	for (ChipmunkSoulButton_v1* b in _lengthButtons) {
		b.toolTip = @"Bars to chop. Best part looks for a stretch this long; Beats and Even give one slice per beat.";
	}
	[self join:_lengthButtons x:left y:cy height:32 widths:{ 52, 37, 37, 37 }];

	_sensitivity = [[ChipmunkSoulSlider_v1 alloc] initWithFrame:NSMakeRect(left + 174, cy + 2, 196, 28)];
	_sensitivity.title = @"Sensitivity";
	_sensitivity.titleWidth = 66;
	_sensitivity.valueWidth = 34;
	_sensitivity.minValue = 0;
	_sensitivity.maxValue = 100;
	_sensitivity.defaultValue = 50;
	_sensitivity.integerSteps = YES;
	_sensitivity.valueText = ^(float v) { return [NSString stringWithFormat:@"%.0f%%", v]; };
	_sensitivity.toolTip = @"Transients mode: higher means more, smaller hits become chops.";
	__weak ChipmunkSoulView_v1* weakSelf = self;
	_sensitivity.onGesture = ^(BOOL begin) {
		if (!begin) {
			[weakSelf chopSettingsChanged:nil];  // re-chop once, when you let go
		}
	};
	[self addSubview:_sensitivity];

	// [Transients | Beats | Even] [Best Part | Prev Idea | Next Idea | Reset], right-aligned.
	_modeButtons = [self choices:@[ @"Transients", @"Beats", @"Even" ]
							tags:@[ @(kChop_Transients), @(kChop_Beats), @(kChop_Even) ]
						   frame:NSZeroRect
						  action:@selector(choiceClicked:)];
	_modeButtons[0].toolTip = @"Cut on drum hits and chord stabs. Sensitivity sets how many.";
	_modeButtons[1].toolTip = @"Detect the tempo and cut on every beat.";
	_modeButtons[2].toolTip = @"Equal slices, one per beat.";
	ChipmunkSoulButton_v1* best = [self button:@"Best Part" kind:CSButtonSecondary frame:NSZeroRect action:@selector(bestPart:)];
	best.toolTip = @"Scan the whole song and chop its best part: the hook, sung and repeated.";
	ChipmunkSoulButton_v1* prev = [self button:@"Prev Idea" kind:CSButtonSecondary frame:NSZeroRect action:@selector(prevIdea:)];
	prev.toolTip = @"Go back to the previous part of the song.";
	ChipmunkSoulButton_v1* next = [self button:@"Next Idea" kind:CSButtonSecondary frame:NSZeroRect action:@selector(nextIdea:)];
	next.toolTip = @"Try the next-best part of the song.";
	ChipmunkSoulButton_v1* reset = [self button:@"Reset" kind:CSButtonSecondary frame:NSZeroRect action:@selector(chopSettingsChanged:)];
	reset.toolTip = @"Throw away your marker edits and chop this section again.";
	const std::vector<CGFloat> actionWidths = { 86, 84, 84, 62 }, modeWidths = { 92, 62, 58 };
	const CGFloat actionX = right - (86 + 84 + 84 + 62 - 3);
	[self join:@[ best, prev, next, reset ] x:actionX y:cy height:32 widths:actionWidths];
	[self join:_modeButtons x:actionX - 12 - (92 + 62 + 58 - 2) y:cy height:32 widths:modeWidths];

	_instantPlay = [self button:@"Instant play" kind:CSButtonCheck frame:NSMakeRect(right - 132, kKeysTop + 8, 132, 22) action:@selector(togglesChanged:)];
	_instantPlay.toolTip = @"Pads and keys you play here go straight to your speakers, so they sound the moment you press them. "
						   @"(They skip the track's fader and effects in GarageBand.) Turn off to play them through GarageBand.";

	// Keys panel: the drum pads with the kit menu, the piano keyboard, then the selected chop's settings.
	const CGFloat drumTop = kKeysTop + kBarHeight + 8;
	NSTextField* drumLabel = [self label:NSMakeRect(left, drumTop + 12, 60, 22) size:14 color:kInk() weight:NSFontWeightSemibold];
	drumLabel.font = CSDisplay(16);
	drumLabel.stringValue = @"Drums";
	_kitMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(left + 58, drumTop + 8, 116, 28) pullsDown:NO];
	for (int k = 0; k < kNumDrumKits; ++k) {
		[_kitMenu addItemWithTitle:@(kDrumKitNames[k])];
		_kitMenu.lastItem.tag = k;
	}
	_kitMenu.target = self;
	_kitMenu.action = @selector(kitChanged:);
	_kitMenu.toolTip = @"Drum kit, in the style of a classic drum machine.";
	[self addSubview:_kitMenu];
	_drumPads = [[ChipmunkSoulDrumPads_v1 alloc] initWithFrame:NSMakeRect(left + 186, drumTop, right - left - 186, 44)];
	_drumPads.owner = self;
	_drumPads.levels.assign(kNumDrums, 0.f);
	[self addSubview:_drumPads];

	const CGFloat pianoTop = drumTop + 44 + 8;
	_pads = [[ChipmunkSoulPads_v1 alloc] initWithFrame:NSMakeRect(left, pianoTop, right - left, 100)];
	_pads.owner = self;
	[_pads registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
	[self addSubview:_pads];

	const CGFloat iy = pianoTop + 100 + 12;
	_chopLabel = [self label:NSMakeRect(left, iy + 4, 96, 22) size:14 color:kInk() weight:NSFontWeightSemibold];
	_chopLabel.font = CSDisplay(16);
	_chopPitch = [[ChipmunkSoulSlider_v1 alloc] initWithFrame:NSMakeRect(left + 100, iy, 210, 28)];
	_chopPitch.title = @"Pitch";
	_chopPitch.titleWidth = 34;
	_chopPitch.valueWidth = 42;
	_chopPitch.minValue = -24;
	_chopPitch.maxValue = 24;
	_chopPitch.integerSteps = YES;
	_chopPitch.bipolar = YES;
	_chopPitch.tickStep = 12;
	_chopPitch.valueText = ^(float v) { return [NSString stringWithFormat:@"%+.0f st", v]; };
	_chopPitch.toolTip = @"Tune just this chop, in semitones.";
	_chopPitch.onChange = ^(float v) { [weakSelf setChopEdit:^(ChopEdit& e) { e.pitch = v; }]; };
	[self addSubview:_chopPitch];
	_chopGain = [[ChipmunkSoulSlider_v1 alloc] initWithFrame:NSMakeRect(left + 326, iy, 214, 28)];
	_chopGain.title = @"Volume";
	_chopGain.titleWidth = 46;
	_chopGain.valueWidth = 50;
	_chopGain.minValue = -24;
	_chopGain.maxValue = 12;
	_chopGain.bipolar = YES;
	_chopGain.tickStep = 12;
	_chopGain.valueText = ^(float v) { return [NSString stringWithFormat:@"%+.1f dB", v]; };
	_chopGain.toolTip = @"Turn just this chop up or down.";
	_chopGain.onChange = ^(float v) { [weakSelf setChopEdit:^(ChopEdit& e) { e.gainDb = v; }]; };
	[self addSubview:_chopGain];
	_chopReverse = [self button:@"Reverse" kind:CSButtonCheck frame:NSMakeRect(left + 556, iy + 3, 100, 22) action:@selector(chopReverseClicked:)];
	_chopReverse.toolTip = @"Play just this chop backwards.";
	_groupLabel = [self label:NSMakeRect(right - 196 - 84, iy + 6, 78, 18) size:12 color:kMuted() weight:NSFontWeightMedium];
	_groupLabel.stringValue = @"Mute group";
	_groupLabel.alignment = NSTextAlignmentRight;
	_groupButtons = [self choices:@[ @"Off", @"A", @"B", @"C", @"D" ] tags:@[ @0, @1, @2, @3, @4 ]
							frame:NSMakeRect(right - 196, iy + 1, 196, 26)
						   action:@selector(groupClicked:)];
	for (ChipmunkSoulButton_v1* b in _groupButtons) {
		b.toolTip = @"Mute group: playing a chop stops any other chop in the same group (like open and closed hi-hats).";
	}
	_selectedSlice = -1;
	_edits.assign(kMaxSlices, ChopEdit{ 0, 0, 0 });

	// Sound panel: a wide Pitch slider with Keep Pitch, then the knobs and switches.
	const CGFloat pitchTop = kSoundTop + kBarHeight + 8;
	ChipmunkSoulSlider_v1* pitch = [[ChipmunkSoulSlider_v1 alloc] initWithFrame:NSMakeRect(left, pitchTop, 470, 28)];
	pitch.title = @"Pitch";
	pitch.titleWidth = 40;
	pitch.valueWidth = 54;
	pitch.minValue = -12;
	pitch.maxValue = 24;
	pitch.defaultValue = 4;
	pitch.integerSteps = YES;
	pitch.bipolar = YES;
	pitch.tickStep = 12;
	pitch.valueText = ^(float v) { return [NSString stringWithFormat:@"%+.1f st", v]; };
	pitch.toolTip = @"Pitch of the whole sample in semitones. +3 to +7 is the classic chipmunk soul zone.";
	pitch.onChange = ^(float v) { [weakSelf knobChanged:kParam_Pitch value:v]; };
	pitch.onGesture = ^(BOOL begin) {
		[weakSelf gesture:kParam_Pitch begin:begin];
		if (!begin) {
			[weakSelf focus];
		}
	};
	[self addSubview:pitch];
	_knobs[@(kParam_Pitch)] = pitch;
	_keepPitch = [self button:@"Keep pitch" kind:CSButtonCheck frame:NSMakeRect(left + 488, pitchTop + 3, 120, 22) action:@selector(togglesChanged:)];
	// What a held key does when its chop ends.
	NSTextField* endLabel = [self label:NSMakeRect(right - 216 - 84, pitchTop + 5, 78, 18) size:12 color:kMuted() weight:NSFontWeightMedium];
	endLabel.stringValue = @"At chop end";
	endLabel.alignment = NSTextAlignmentRight;
	_endButtons = [self choices:@[ @"Continue", @"Stop at end", @"Loop" ] tags:@[ @(kEndContinue), @(kEndStop), @(kEndLoop) ]
						  frame:NSZeroRect
						 action:@selector(endModeClicked:)];
	[self join:_endButtons x:right - 216 y:pitchTop height:28 widths:{ 78, 90, 50 }];
	_endButtons[0].toolTip = @"Holding a key keeps playing past the chop's end, on into the song.";
	_endButtons[1].toolTip = @"Holding a key stops at the end of its chop.";
	_endButtons[2].toolTip = @"Holding a key repeats its chop until you let go.";
	_keepPitch.toolTip = @"Sync to the song tempo by time-stretching instead of speeding the record up, so Pitch moves pitch alone.";

	struct KnobDef {
		AudioUnitParameterID param;
		NSString* title;
		CSKnobCurve curve;
		BOOL integer;
		NSString* (^format)(float);
	};
	const KnobDef defs[] = {
		{ kParam_RootNote, @"Root Key", CSKnobLinear, YES, ^(float v) { return NoteName(int(v)); } },
		{ kParam_Attack, @"Attack", CSKnobSqrt, NO, ^(float v) { return [NSString stringWithFormat:@"%.0f ms", v]; } },
		{ kParam_Release, @"Release", CSKnobSqrt, NO, ^(float v) { return [NSString stringWithFormat:@"%.0f ms", v]; } },
		{ kParam_LowCut, @"Low Cut", CSKnobLog, NO, ^(float v) {
			 return v <= 20.5f ? @"Off" : [NSString stringWithFormat:@"%.0f Hz", v];
		 } },
		{ kParam_HighCut, @"High Cut", CSKnobLog, NO, ^(float v) {
			 return v >= 19900.f ? @"Off" : v >= 1000 ? [NSString stringWithFormat:@"%.1f kHz", v / 1000] : [NSString stringWithFormat:@"%.0f Hz", v];
		 } },
		{ kParam_Crunch, @"Crunch", CSKnobLinear, NO, ^(float v) { return [NSString stringWithFormat:@"%.0f%%", v]; } },
		{ kParam_Vinyl, @"Vinyl", CSKnobLinear, NO, ^(float v) { return v < 0.5f ? @"Off" : [NSString stringWithFormat:@"%.0f%%", v]; } },
		{ kParam_Swing, @"Swing", CSKnobLinear, YES, ^(float v) { return v <= 50.5f ? @"Off" : [NSString stringWithFormat:@"%.0f%%", v]; } },
		{ kParam_VelocitySens, @"Velocity", CSKnobLinear, NO, ^(float v) { return [NSString stringWithFormat:@"%.0f%%", v]; } },
		{ kParam_Volume, @"Volume", CSKnobLinear, NO, ^(float v) { return [NSString stringWithFormat:@"%+.1f dB", v]; } },
		{ kParam_DrumVolume, @"Drums", CSKnobLinear, NO, ^(float v) { return v <= -39.5f ? @"Off" : [NSString stringWithFormat:@"%+.1f dB", v]; } },
	};
	CGFloat x = left - 8;
	const CGFloat knobTop = pitchTop + 36;
	for (const auto& d : defs) {
		AudioUnitParameterInfo info{};
		UInt32 size = sizeof(info);
		AudioUnitGetProperty(_au, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, d.param, &info, &size);
		if (info.flags & kAudioUnitParameterFlag_CFNameRelease) {
			CFRelease(info.cfNameString);
		}
		ChipmunkSoulKnob_v1* k = [[ChipmunkSoulKnob_v1 alloc] initWithFrame:NSMakeRect(x, knobTop, 72, 100)];
		k.title = d.title;
		k.minValue = info.minValue;
		k.maxValue = info.maxValue;
		k.defaultValue = info.defaultValue;
		k.curve = d.curve;
		k.integerSteps = d.integer;
		k.valueText = d.format;
		const AudioUnitParameterID pid = d.param;
		k.onChange = ^(float v) { [weakSelf knobChanged:pid value:v]; };
		k.onGesture = ^(BOOL begin) {
			[weakSelf gesture:pid begin:begin];
			if (!begin) {
				[weakSelf focus];
			}
		};
		[self addSubview:k];
		_knobs[@(d.param)] = k;
		x += 72;
	}
	_knobs[@(kParam_Crunch)].toolTip = @"SP-1200 style grit: fewer bits, lower sample rate, a little drive.";
	_knobs[@(kParam_Vinyl)].toolTip = @"Record crackle and hiss while chops play, plus a little wow and flutter.";
	_knobs[@(kParam_Swing)].toolTip = @"MPC-style swing: pushes off-beat 16th notes late while the song plays. 54-62% is a nice bounce.";
	_knobs[@(kParam_DrumVolume)].toolTip = @"Level of the built-in drum kit (the octave below the chops).";

	const CGFloat tx = x + 14;
	_choke = [self button:@"Choke" kind:CSButtonCheck frame:NSMakeRect(tx, knobTop + 22, 150, 24) action:@selector(togglesChanged:)];
	_choke.toolTip = @"Every new chop cuts off the one that's playing, like an MPC.";
	_reverse = [self button:@"Reverse" kind:CSButtonCheck frame:NSMakeRect(tx, knobTop + 58, 150, 24) action:@selector(togglesChanged:)];
	_reverse.toolTip = @"Play every chop backwards.";
}

// ---- mute groups ---------------------------------------------------------------------------------

- (void)selectSlice:(int)slice
{
	_selectedSlice = slice;
	_pads.selected = slice;
	_pads.needsDisplay = YES;
	[self refreshGroupPicker];
}

- (void)refreshGroupPicker
{
	const BOOL have = _selectedSlice >= 0 && _selectedSlice < _pads.count;
	for (ChipmunkSoulButton_v1* b in _groupButtons) {
		b.enabled = have;
	}
	[self select:have && size_t(_selectedSlice) < _groups.size() ? _groups[size_t(_selectedSlice)] : -1 in:_groupButtons];
	_chopLabel.stringValue = have ? [NSString stringWithFormat:@"Chop %d", _selectedSlice + 1] : @"No chop";
	_chopLabel.textColor = have ? kInk() : kMuted();
	const ChopEdit e = have && size_t(_selectedSlice) < _edits.size() ? _edits[size_t(_selectedSlice)] : ChopEdit{ 0, 0, 0 };
	_chopPitch.enabled = _chopGain.enabled = _chopReverse.enabled = have;
	_chopPitch.value = e.pitch;
	_chopGain.value = e.gainDb;
	_chopReverse.state = e.reverse ? NSControlStateValueOn : NSControlStateValueOff;
	_chopPitch.needsDisplay = _chopGain.needsDisplay = _chopReverse.needsDisplay = YES;
}

// ---- per-chop tweaks -----------------------------------------------------------------------------

- (void)refreshEdits
{
	CFDataRef data = (CFDataRef)[self copyCFProperty:kProp_ChopEdits];
	_edits.assign(kMaxSlices, ChopEdit{ 0, 0, 0 });
	if (data && CFDataGetLength(data) == CFIndex(sizeof(ChopEdit) * kMaxSlices)) {
		memcpy(_edits.data(), CFDataGetBytePtr(data), sizeof(ChopEdit) * kMaxSlices);
	}
	if (data) {
		CFRelease(data);
	}
	[self refreshGroupPicker];
}

- (void)setChopEdit:(void (^)(ChopEdit&))change
{
	if (_selectedSlice < 0 || _selectedSlice >= kMaxSlices) {
		return;
	}
	_edits.resize(kMaxSlices, ChopEdit{ 0, 0, 0 });
	change(_edits[size_t(_selectedSlice)]);
	CFDataRef data = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(_edits.data()), CFIndex(sizeof(ChopEdit) * kMaxSlices));
	AudioUnitSetProperty(_au, kProp_ChopEdits, kAudioUnitScope_Global, 0, &data, sizeof(data));
	CFRelease(data);
}

- (void)chopReverseClicked:(id)sender
{
	const BOOL on = _chopReverse.state == NSControlStateValueOn;
	[self setChopEdit:^(ChopEdit& e) { e.reverse = on ? 1 : 0; }];
	[self focus];
}

// ---- recorder ------------------------------------------------------------------------------------

- (void)collectRecorded
{
	CFDataRef data = (CFDataRef)[self copyCFProperty:kProp_Recorded];
	if (!data) {
		return;
	}
	if (_recording) {
		const size_t count = size_t(CFDataGetLength(data)) / sizeof(RecordedNote);
		const auto* notes = reinterpret_cast<const RecordedNote*>(CFDataGetBytePtr(data));
		_take.insert(_take.end(), notes, notes + count);
	}
	CFRelease(data);
}

- (void)toggleRecording:(id)sender
{
	if (!_recording) {
		_recording = NO;
		[self collectRecorded];  // drop anything played before Record was pressed
		_take.clear();
		_recording = YES;
		_recordButton.title = @"■ Stop";
		_recordButton.state = NSControlStateValueOn;
		_statusLabel.stringValue = @"Recording: play anything, then press Stop";
		_statusLabel.textColor = kAccent();
	} else {
		[self collectRecorded];
		_recording = NO;
		_recordButton.title = @"● Record";
		_recordButton.state = NSControlStateValueOff;
		int notes = 0;
		for (const auto& n : _take) {
			notes += n.velocity > 0;
		}
		if (notes > 0) {
			++_takeNumber;
			_clip.text = [NSString stringWithFormat:@"Take %d · %d notes", _takeNumber, notes];
			_clip.ready = YES;
			_statusLabel.stringValue = @"Drag the take onto your track to drop it in as MIDI";
		} else {
			_statusLabel.stringValue = @"Nothing was played, so there's no take";
		}
		_statusLabel.textColor = kMuted();
		_clip.needsDisplay = YES;
	}
	[self focus];
}

- (void)quantizeChanged:(id)sender
{
	[self focus];
}

// Writes the take as a standard MIDI file in Music/Chipmunk Soul/MIDI and returns it. Notes keep
// the plug-in's note numbers, so the region plays the same chops and drums back. When GarageBand
// was playing, the region starts on the bar the first note fell in, so it lines up when dropped on
// that bar; otherwise it starts on the first note.
- (NSURL*)writeTake
{
	if (_take.empty()) {
		return nil;
	}
	struct Note {
		double on, off;
		int note, velocity;
	};
	std::vector<Note> notes;
	std::vector<int> open(128, -1);
	for (const auto& r : _take) {
		if (r.velocity > 0) {
			if (open[r.note] >= 0 && notes[size_t(open[r.note])].off < 0) {
				notes[size_t(open[r.note])].off = r.beat;  // retriggered before its note-off
			}
			open[r.note] = int(notes.size());
			notes.push_back({ r.beat, -1, r.note, r.velocity });
		} else if (open[r.note] >= 0) {
			notes[size_t(open[r.note])].off = r.beat;
			open[r.note] = -1;
		}
	}
	if (notes.empty()) {
		return nil;
	}
	const bool quantize = _quantize.state == NSControlStateValueOn;
	const bool songTime = _take.front().hostPlaying != 0;
	const double first = notes.front().on;
	const double start = songTime ? std::floor(first / 4.0 + 1e-6) * 4.0 : (quantize ? std::floor(first * 4.0) / 4.0 : first);
	for (auto& n : notes) {
		const double length = n.off < 0 ? 0.25 : n.off - n.on;
		n.on -= start;
		if (quantize) {
			n.on = std::round(n.on * 4.0) / 4.0;
		}
		n.off = n.on + std::max(length, 0.25);  // drums are one-shots: give them a 16th
	}

	// Standard MIDI file, format 0, 480 ticks per beat.
	constexpr int kTicks = 480;
	struct Event {
		uint32_t tick;
		uint8_t status, note, velocity;
	};
	std::vector<Event> events;
	for (const auto& n : notes) {
		events.push_back({ uint32_t(std::lround(n.on * kTicks)), 0x90, uint8_t(n.note), uint8_t(n.velocity) });
		events.push_back({ uint32_t(std::lround(n.off * kTicks)), 0x80, uint8_t(n.note), 0 });
	}
	std::stable_sort(events.begin(), events.end(), [](const Event& a, const Event& b) {
		return a.tick != b.tick ? a.tick < b.tick : a.status < b.status;  // note-offs first
	});
	std::vector<uint8_t> track;
	auto varlen = [&](uint32_t v) {
		uint8_t bytes[5];
		int count = 0;
		bytes[count++] = v & 0x7f;
		while (v >>= 7) {
			bytes[count++] = uint8_t((v & 0x7f) | 0x80);
		}
		while (count--) {
			track.push_back(bytes[count]);
		}
	};
	const double tempo = _hostBPM > 0 ? _hostBPM : 120.0;
	const uint32_t microsPerBeat = uint32_t(60000000.0 / tempo);
	varlen(0);
	track.insert(track.end(), { 0xff, 0x51, 0x03, uint8_t(microsPerBeat >> 16), uint8_t(microsPerBeat >> 8), uint8_t(microsPerBeat) });
	uint32_t last = 0;
	for (const auto& e : events) {
		varlen(e.tick - last);
		last = e.tick;
		track.insert(track.end(), { e.status, e.note, e.velocity });
	}
	varlen(0);
	track.insert(track.end(), { 0xff, 0x2f, 0x00 });

	std::vector<uint8_t> file = { 'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, uint8_t(kTicks >> 8), uint8_t(kTicks & 0xff), 'M', 'T', 'r', 'k' };
	const uint32_t len = uint32_t(track.size());
	file.insert(file.end(), { uint8_t(len >> 24), uint8_t(len >> 16), uint8_t(len >> 8), uint8_t(len) });
	file.insert(file.end(), track.begin(), track.end());

	NSURL* folder = [[[NSFileManager.defaultManager URLsForDirectory:NSMusicDirectory inDomains:NSUserDomainMask].firstObject
		URLByAppendingPathComponent:@"Chipmunk Soul"] URLByAppendingPathComponent:@"MIDI"];
	[NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
	NSString* song = _fileLabel.stringValue.stringByDeletingPathExtension;
	if (song.length == 0 || [song isEqualToString:@"No song loaded"]) {
		song = @"Arnold Chopper";
	}
	NSURL* url = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ take %d.mid", song, _takeNumber]];
	if (![[NSData dataWithBytes:file.data() length:file.size()] writeToURL:url atomically:YES]) {
		return nil;
	}
	return url;
}

- (void)kitChanged:(id)sender
{
	[self setParam:kParam_DrumKit value:float(_kitMenu.selectedTag)];
	[self focus];
}

- (void)playDrum:(int)drum
{
	if (drum < 0) {
		return;
	}
	int32_t value = kAuditionDrum + drum;
	AudioUnitSetProperty(_au, kProp_Audition, kAudioUnitScope_Global, 0, &value, sizeof(value));
	auto levels = _drumPads.levels;
	levels.resize(kNumDrums, 0.f);
	levels[size_t(drum)] = 1.f;
	_drumPads.levels = levels;
	_drumPads.needsDisplay = YES;
}

- (NSURL*)exportChop:(int)slice
{
	int32_t value = slice;
	if (AudioUnitSetProperty(_au, kProp_ExportChop, kAudioUnitScope_Global, 0, &value, sizeof(value)) != noErr) {
		return nil;
	}
	CFStringRef path = (CFStringRef)[self copyCFProperty:kProp_ExportPath];
	NSString* p = (__bridge_transfer NSString*)path;
	return p.length ? [NSURL fileURLWithPath:p] : nil;
}

// ---- undo ----------------------------------------------------------------------------------------

- (Snapshot)snapshot
{
	return { _wave.starts, _wave.regionStart, _wave.regionEnd, _chop };
}

- (void)pushUndo
{
	if (_wave.frames == 0) {
		return;
	}
	_undo.push_back([self snapshot]);
	if (_undo.size() > 100) {
		_undo.erase(_undo.begin());
	}
	_redo.clear();
}

- (void)restore:(const Snapshot&)snap
{
	ChopSettings s = snap.settings;
	s.autoPick = -1;  // restore exactly this region, don't search again
	s.regionStart = snap.regionStart;
	s.regionEnd = snap.regionEnd >= _wave.frames ? 0 : snap.regionEnd;
	AudioUnitSetProperty(_au, kProp_ChopSettings, kAudioUnitScope_Global, 0, &s, sizeof(s));
	SliceHeader h{ snap.regionStart, snap.regionEnd, uint32_t(snap.starts.size()) };
	NSMutableData* data = [NSMutableData dataWithBytes:&h length:sizeof(h)];
	[data appendBytes:snap.starts.data() length:snap.starts.size() * sizeof(uint32_t)];
	CFDataRef ref = (__bridge CFDataRef)data;
	AudioUnitSetProperty(_au, kProp_Slices, kAudioUnitScope_Global, 0, &ref, sizeof(ref));
	[self refreshAll];
	_chop.autoPick = snap.settings.autoPick;
}

- (void)undo:(id)sender
{
	if (_undo.empty()) {
		return;
	}
	_redo.push_back([self snapshot]);
	const Snapshot snap = _undo.back();
	_undo.pop_back();
	[self restore:snap];
	_statusLabel.stringValue = @"Undone";
	_statusLabel.textColor = kMuted();
	[self focus];
}

- (void)redo:(id)sender
{
	if (_redo.empty()) {
		return;
	}
	_undo.push_back([self snapshot]);
	const Snapshot snap = _redo.back();
	_redo.pop_back();
	[self restore:snap];
	_statusLabel.stringValue = @"Redone";
	_statusLabel.textColor = kMuted();
	[self focus];
}

- (void)refreshGroups
{
	CFDataRef data = (CFDataRef)[self copyCFProperty:kProp_MuteGroups];
	_groups.assign(kMaxSlices, 0);
	if (data && CFDataGetLength(data) == kMaxSlices) {
		memcpy(_groups.data(), CFDataGetBytePtr(data), kMaxSlices);
	}
	if (data) {
		CFRelease(data);
	}
	_pads.groups = _groups;
	_pads.needsDisplay = YES;
	[self refreshGroupPicker];
}

- (void)setGroup:(int)group of:(int)slice
{
	if (slice < 0 || slice >= kMaxSlices) {
		return;
	}
	_groups.resize(kMaxSlices, 0);
	_groups[size_t(slice)] = uint8_t(group);
	CFDataRef data = CFDataCreate(nullptr, _groups.data(), kMaxSlices);
	AudioUnitSetProperty(_au, kProp_MuteGroups, kAudioUnitScope_Global, 0, &data, sizeof(data));
	CFRelease(data);
	[self refreshGroups];
}

- (void)cycleGroupOf:(int)slice
{
	[self selectSlice:slice];
	const int current = size_t(slice) < _groups.size() ? _groups[size_t(slice)] : 0;
	[self setGroup:(current + 1) % (kMuteGroups + 1) of:slice];
}

- (void)groupClicked:(ChipmunkSoulButton_v1*)sender
{
	[self setGroup:int(sender.tag) of:_selectedSlice];
	[self focus];
}

- (void)endModeClicked:(ChipmunkSoulButton_v1*)sender
{
	[self select:sender.tag in:_endButtons];
	[self setParam:kParam_EndMode value:float(sender.tag)];
	[self focus];
}

- (void)choiceClicked:(ChipmunkSoulButton_v1*)sender
{
	for (NSArray* group in @[ _modeButtons, _lengthButtons ]) {
		if ([group containsObject:sender]) {
			[self select:sender.tag in:group];
			[self chopSettingsChanged:sender];
		}
	}
}

// ---- AU plumbing ---------------------------------------------------------------------------------

- (void)startListening
{
	if (AUEventListenerCreate(EventListenerProc, (__bridge void*)self, CFRunLoopGetMain(), kCFRunLoopDefaultMode,
			0.02f, 0.02f, &_listener) != noErr) {
		return;
	}
	for (AudioUnitParameterID p = 0; p < kNumParams; ++p) {
		AudioUnitEvent e{};
		e.mEventType = kAudioUnitEvent_ParameterValueChange;
		e.mArgument.mParameter = { _au, p, kAudioUnitScope_Global, 0 };
		AUEventListenerAddEventType(_listener, (__bridge void*)self, &e);
	}
	for (AudioUnitPropertyID prop : { kProp_Overview, kProp_Slices, kProp_ChopSettings, kProp_Info, kProp_MuteGroups, kProp_ChopEdits }) {
		AudioUnitEvent e{};
		e.mEventType = kAudioUnitEvent_PropertyChange;
		e.mArgument.mProperty = { _au, prop, kAudioUnitScope_Global, 0 };
		AUEventListenerAddEventType(_listener, (__bridge void*)self, &e);
	}
}

- (float)param:(AudioUnitParameterID)p
{
	AudioUnitParameterValue v = 0;
	AudioUnitGetParameter(_au, p, kAudioUnitScope_Global, 0, &v);
	return v;
}

- (void)setParam:(AudioUnitParameterID)p value:(float)v
{
	AudioUnitParameter param{ _au, p, kAudioUnitScope_Global, 0 };
	AUParameterSet(_listener, (__bridge void*)self, &param, v, 0);
	if (p == kParam_Pitch) {
		[self refreshBPM];
	} else if (p == kParam_RootNote) {
		[self refreshRoot];
	}
}

- (void)knobChanged:(AudioUnitParameterID)p value:(float)v
{
	if (p == kParam_Pitch && [self param:kParam_Sync] >= 0.5f && [self param:kParam_KeepPitch] < 0.5f) {
		[self setParam:kParam_Sync value:0.f];  // grabbing Pitch takes manual control
		_syncBox.state = NSControlStateValueOff;
	}
	[self setParam:p value:v];
}

- (void)gesture:(AudioUnitParameterID)p begin:(BOOL)begin
{
	AudioUnitEvent e{};
	e.mEventType = begin ? kAudioUnitEvent_BeginParameterChangeGesture : kAudioUnitEvent_EndParameterChangeGesture;
	e.mArgument.mParameter = { _au, p, kAudioUnitScope_Global, 0 };
	AUEventListenerNotify(_listener, (__bridge void*)self, &e);
}

- (void)parameterChanged:(AudioUnitParameterID)p value:(float)v
{
	if (ChipmunkSoulKnob_v1* k = _knobs[@(p)]) {
		if (!(p == kParam_Pitch && [self param:kParam_Sync] >= 0.5f && [self param:kParam_KeepPitch] < 0.5f && _sampleBPM > 0)) {
			k.value = v;
		}
	}
	switch (p) {
	case kParam_Sync:
		_syncBox.state = v >= 0.5f ? NSControlStateValueOn : NSControlStateValueOff;
		[self refreshBPM];
		break;
	case kParam_InstantPlay:
		_instantPlay.state = v >= 0.5f ? NSControlStateValueOn : NSControlStateValueOff;
		break;
	case kParam_EndMode:
		[self select:std::clamp(int(v + 0.5f), 0, 2) in:_endButtons];
		break;
	case kParam_DrumKit:
		[_kitMenu selectItemWithTag:std::clamp(int(v + 0.5f), 0, kNumDrumKits - 1)];
		break;
	case kParam_KeepPitch:
		_keepPitch.state = v >= 0.5f ? NSControlStateValueOn : NSControlStateValueOff;
		[self refreshBPM];
		break;
	case kParam_Choke: _choke.state = v >= 0.5f ? NSControlStateValueOn : NSControlStateValueOff; break;
	case kParam_Reverse: _reverse.state = v >= 0.5f ? NSControlStateValueOn : NSControlStateValueOff; break;
	case kParam_Pitch: [self refreshBPM]; break;
	case kParam_RootNote: [self refreshRoot]; break;
	default: break;
	}
}

- (void)propertyChanged:(AudioUnitPropertyID)prop
{
	switch (prop) {
	case kProp_Overview: [self refreshOverview]; break;
	case kProp_Slices: [self refreshSlices]; break;
	case kProp_ChopSettings: [self refreshChopSettings]; break;
	case kProp_Info: [self refreshInfo]; break;
	case kProp_MuteGroups: [self refreshGroups]; break;
	case kProp_ChopEdits: [self refreshEdits]; break;
	default: break;
	}
}

- (CFTypeRef)copyCFProperty:(AudioUnitPropertyID)prop
{
	CFTypeRef value = nullptr;
	UInt32 size = sizeof(value);
	if (AudioUnitGetProperty(_au, prop, kAudioUnitScope_Global, 0, &value, &size) != noErr) {
		return nullptr;
	}
	return value;
}

// ---- refresh -------------------------------------------------------------------------------------

- (void)refreshAll
{
	for (AudioUnitParameterID p = 0; p < kNumParams; ++p) {
		[self parameterChanged:p value:[self param:p]];
	}
	[self refreshOverview];
	[self refreshSlices];
	[self refreshChopSettings];
	[self refreshInfo];
	[self refreshGroups];
	[self refreshEdits];
}

- (void)refreshOverview
{
	CFDataRef data = (CFDataRef)[self copyCFProperty:kProp_Overview];
	std::vector<float> peaks;
	uint32_t frames = 0;
	if (data && size_t(CFDataGetLength(data)) >= sizeof(OverviewHeader)) {
		OverviewHeader h;
		memcpy(&h, CFDataGetBytePtr(data), sizeof(h));
		if (size_t(CFDataGetLength(data)) == sizeof(h) + h.numPeaks * 2 * sizeof(float)) {
			peaks.resize(h.numPeaks * 2);
			memcpy(peaks.data(), CFDataGetBytePtr(data) + sizeof(h), peaks.size() * sizeof(float));
			frames = h.numFrames;
			_sampleRate = h.sampleRate;
		}
	}
	if (data) {
		CFRelease(data);
	}
	_wave.peaks = peaks;
	_wave.frames = frames;
	_wave.needsDisplay = YES;
}

- (void)refreshSlices
{
	CFDataRef data = (CFDataRef)[self copyCFProperty:kProp_Slices];
	std::vector<uint32_t> starts;
	SliceHeader h{ 0, 0, 0 };
	if (data && size_t(CFDataGetLength(data)) >= sizeof(SliceHeader)) {
		memcpy(&h, CFDataGetBytePtr(data), sizeof(h));
		if (size_t(CFDataGetLength(data)) == sizeof(h) + h.count * sizeof(uint32_t)) {
			starts.resize(h.count);
			memcpy(starts.data(), CFDataGetBytePtr(data) + sizeof(h), h.count * sizeof(uint32_t));
		}
	}
	if (data) {
		CFRelease(data);
	}
	_wave.starts = starts;
	_wave.regionStart = h.regionStart;
	_wave.regionEnd = h.regionEnd;
	_wave.needsDisplay = YES;
	_pads.count = int(starts.size());
	if (_selectedSlice >= _pads.count) {
		[self selectSlice:-1];
	}
	_pads.levels.assign(starts.size(), 0.f);
	_pads.needsDisplay = YES;
}

- (void)refreshChopSettings
{
	ChopSettings s{};
	UInt32 size = sizeof(s);
	if (AudioUnitGetProperty(_au, kProp_ChopSettings, kAudioUnitScope_Global, 0, &s, &size) != noErr) {
		return;
	}
	_chop = s;
	[self select:std::clamp<int>(s.mode, 0, 2) in:_modeButtons];
	NSInteger closest = 16;
	for (ChipmunkSoulButton_v1* b in _lengthButtons) {
		if (std::abs(b.tag - s.count) < std::abs(closest - s.count)) {
			closest = b.tag;
		}
	}
	[self select:closest in:_lengthButtons];
	_sensitivity.value = std::round(s.sensitivity * 100);
	_sensitivity.enabled = s.mode == kChop_Transients;
	_sensitivity.needsDisplay = YES;
}

- (void)refreshInfo
{
	CFDictionaryRef info = (CFDictionaryRef)[self copyCFProperty:kProp_Info];
	if (!info) {
		return;
	}
	NSDictionary* d = (__bridge_transfer NSDictionary*)info;
	NSString* name = d[(__bridge NSString*)kInfoFileName];
	NSString* status = d[(__bridge NSString*)kInfoStatus];
	_sampleBPM = [d[(__bridge NSString*)kInfoSampleBPM] doubleValue];
	_hostBPM = [d[(__bridge NSString*)kInfoHostBPM] doubleValue];
	_playingPitch = [d[(__bridge NSString*)kInfoPitch] doubleValue];
	_picks = [d[(__bridge NSString*)kInfoPicks] intValue];
	_tempoRatio = [d[(__bridge NSString*)kInfoTempoRatio] doubleValue];
	_lastStatus = status;
	_fileLabel.stringValue = name.length ? name : @"No song loaded";
	if (!_busy) {
		_statusLabel.stringValue = status.length ? status : @"";
		_statusLabel.textColor = status.length ? kError() : kMuted();
		_wave.emptyMessage = status.length ? status : nil;
	}
	[self refreshBPM];
}

- (void)refreshBPM
{
	const BOOL keepPitch = [self param:kParam_KeepPitch] >= 0.5f;
	const BOOL synced = [self param:kParam_Sync] >= 0.5f && _sampleBPM > 0 && _hostBPM > 0;
	// With varispeed sync the tempo sets the pitch; with Keep Pitch the slider is always yours.
	const BOOL pitchLocked = synced && !keepPitch;
	const double pitch = pitchLocked ? _playingPitch : [self param:kParam_Pitch];
	ChipmunkSoulKnob_v1* knob = _knobs[@(kParam_Pitch)];
	knob.value = float(pitch);
	knob.alphaValue = pitchLocked ? 0.6 : 1.0;
	if (_sampleBPM > 0) {
		const double ratio = keepPitch ? (synced && _tempoRatio > 0 ? _tempoRatio : 1.0) : std::exp2(pitch / 12.0);
		const double pitched = _sampleBPM * ratio;
		_bpmLabel.stringValue = [NSString stringWithFormat:@"%.1f → %.1f BPM", _sampleBPM, pitched];
		_bpmLabel.toolTip = @"Detected tempo of the chopped section, and its tempo after the pitch-up.";
	} else {
		_bpmLabel.stringValue = _wave.frames ? @"Tempo not detected" : @"";
	}
	_syncBox.title = _hostBPM > 0 ? [NSString stringWithFormat:@"Sync to tempo (%.0f)", _hostBPM] : @"Sync to tempo";
}

- (void)refreshRoot
{
	const int root = int([self param:kParam_RootNote]);
	_wave.rootNote = _pads.rootNote = root;
	_wave.needsDisplay = _pads.needsDisplay = YES;
}

- (void)tick
{
	Playheads p{};
	UInt32 size = sizeof(p);
	if (AudioUnitGetProperty(_au, kProp_Playheads, kAudioUnitScope_Global, 0, &p, &size) != noErr) {
		return;
	}
	std::vector<std::pair<uint32_t, float>> heads;
	std::vector<int> active;
	std::vector<float> levels(size_t(_pads.count), 0.f);
	for (uint32_t i = 0; i < std::min<uint32_t>(p.count, kMaxVoices); ++i) {
		if (p.slices[i] >= 0) {
			heads.emplace_back(p.frames[i], p.levels[i]);
			active.push_back(p.slices[i]);
			if (p.slices[i] < _pads.count) {
				levels[size_t(p.slices[i])] = std::max(levels[size_t(p.slices[i])], p.levels[i]);
			}
		}
	}
	// Let pads fade out instead of blinking off.
	const auto prev = _pads.levels;
	bool changed = !heads.empty() || !_wave.playheads.empty();
	for (size_t i = 0; i < levels.size() && i < prev.size(); ++i) {
		const float v = std::max(levels[i], prev[i] * 0.82f);
		levels[i] = v < 0.02f ? 0.f : v;
		changed = changed || levels[i] != prev[i];
	}
	if (changed) {
		_wave.playheads = heads;
		_wave.activeSlices = active;
		_pads.levels = levels;
		_wave.needsDisplay = _pads.needsDisplay = YES;
	}
	auto drums = _drumPads.levels;
	bool drumsChanged = false;
	for (auto& d : drums) {
		if (d > 0) {
			d = d < 0.03f ? 0.f : d * 0.85f;
			drumsChanged = true;
		}
	}
	if (drumsChanged) {
		_drumPads.levels = drums;
		_drumPads.needsDisplay = YES;
	}
	[self collectRecorded];
	if (++_tick % 10 == 0) {
		[self refreshInfo];  // picks up project tempo changes and the synced pitch
	}
}

// ---- actions -------------------------------------------------------------------------------------

- (void)audition:(int)slice
{
	int32_t s = slice;
	AudioUnitSetProperty(_au, kProp_Audition, kAudioUnitScope_Global, 0, &s, sizeof(s));
}

- (void)releaseSlice:(int)slice
{
	int32_t s = -2 - slice;
	AudioUnitSetProperty(_au, kProp_Audition, kAudioUnitScope_Global, 0, &s, sizeof(s));
}

- (void)showChopResult
{
	_pads.keyOffset = 0;
	if (_lastStatus.length == 0 && _pads.count > 0) {
		if (_chop.autoPick >= 0 && _picks > 0 && _sampleRate > 0) {
			auto mmss = [](double t) { return [NSString stringWithFormat:@"%d:%02d", int(t) / 60, int(t) % 60]; };
			_statusLabel.stringValue = [NSString stringWithFormat:@"Best part #%d of %d (%@–%@), chopped into %d slices",
												 _chop.autoPick + 1, _picks, mmss(_chop.regionStart / _sampleRate),
												 mmss(_chop.regionEnd / _sampleRate), _pads.count];
		} else {
			_statusLabel.stringValue = [NSString stringWithFormat:@"Chopped into %d slices", _pads.count];
		}
		_statusLabel.textColor = kAccent();
	}
}

- (void)commitSlices:(const std::vector<uint32_t>&)starts
{
	[self pushUndo];
	SliceHeader h{ _wave.regionStart, _wave.regionEnd, uint32_t(starts.size()) };
	NSMutableData* data = [NSMutableData dataWithBytes:&h length:sizeof(h)];
	[data appendBytes:starts.data() length:starts.size() * sizeof(uint32_t)];
	CFDataRef ref = (__bridge CFDataRef)data;
	AudioUnitSetProperty(_au, kProp_Slices, kAudioUnitScope_Global, 0, &ref, sizeof(ref));
	[self refreshSlices];
}

- (void)applyChop:(ChopSettings)s
{
	[self pushUndo];
	_chop = s;
	_busy = YES;
	_statusLabel.stringValue = @"Chopping…";
	_statusLabel.textColor = kAccent();
	AudioUnit au = _au;
	__weak ChipmunkSoulView_v1* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		AudioUnitSetProperty(au, kProp_ChopSettings, kAudioUnitScope_Global, 0, &s, sizeof(s));
		dispatch_async(dispatch_get_main_queue(), ^{
			ChipmunkSoulView_v1* strong = weakSelf;
			if (strong) {
				strong->_busy = NO;
				[strong refreshAll];
				[strong showChopResult];
				[strong focus];
			}
		});
	});
}

- (void)commitRegion:(uint32_t)start end:(uint32_t)end
{
	ChopSettings s = _chop;
	s.regionStart = start;
	s.regionEnd = end;
	s.autoPick = -1;  // the user chose the region by hand
	[self applyChop:s];
}

- (void)chopSettingsChanged:(id)sender
{
	ChopSettings s = _chop;
	s.mode = int32_t([self selectedIn:_modeButtons]);
	s.count = int32_t([self selectedIn:_lengthButtons]);
	s.sensitivity = _sensitivity.value / 100.f;
	s.regionStart = _wave.regionStart;
	s.regionEnd = _wave.regionEnd >= _wave.frames ? 0 : _wave.regionEnd;
	[self applyChop:s];
}

- (void)bestPart:(id)sender
{
	ChopSettings s = _chop;
	s.autoPick = 0;
	[self applyChop:s];
}

- (void)prevIdea:(id)sender
{
	ChopSettings s = _chop;
	const int picks = std::max(1, _picks);
	s.autoPick = s.autoPick <= 0 ? picks - 1 : s.autoPick - 1;
	[self applyChop:s];
}

- (void)nextIdea:(id)sender
{
	ChopSettings s = _chop;
	s.autoPick = s.autoPick < 0 ? 0 : s.autoPick + 1;  // the plug-in wraps around after the last idea
	[self applyChop:s];
}

- (void)togglesChanged:(id)sender
{
	if (sender == _choke) {
		[self setParam:kParam_Choke value:_choke.state == NSControlStateValueOn ? 1.f : 0.f];
	} else if (sender == _reverse) {
		[self setParam:kParam_Reverse value:_reverse.state == NSControlStateValueOn ? 1.f : 0.f];
	} else if (sender == _instantPlay) {
		[self setParam:kParam_InstantPlay value:_instantPlay.state == NSControlStateValueOn ? 1.f : 0.f];
		int32_t allOff = -1;  // switches the output over right away
		AudioUnitSetProperty(_au, kProp_Audition, kAudioUnitScope_Global, 0, &allOff, sizeof(allOff));
	} else if (sender == _keepPitch) {
		[self setParam:kParam_KeepPitch value:_keepPitch.state == NSControlStateValueOn ? 1.f : 0.f];
		[self refreshBPM];
	} else if (sender == _syncBox) {
		[self setParam:kParam_Sync value:_syncBox.state == NSControlStateValueOn ? 1.f : 0.f];
		if (_syncBox.state == NSControlStateValueOff) {
			[self parameterChanged:kParam_Pitch value:[self param:kParam_Pitch]];
		}
		[self refreshBPM];
	}
	[self focus];
}

- (void)openFile:(id)sender
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.allowedContentTypes = @[ UTTypeAudio ];
	panel.message = @"Pick a song to chop (songs from other folders are copied into Music > Chipmunk Soul)";
	panel.directoryURL = SongFolder();
	__weak ChipmunkSoulView_v1* weakSelf = self;
	void (^done)(NSModalResponse) = ^(NSModalResponse r) {
		if (r == NSModalResponseOK && panel.URL) {
			[weakSelf importURLs:@[ panel.URL ]];
		}
	};
	if (self.window) {
		[panel beginSheetModalForWindow:self.window completionHandler:done];
	} else {
		done([panel runModal]);
	}
}

// Import: pick any number of songs from anywhere, copy them into Music › Chipmunk Soul, load the first.
- (void)importAudio:(id)sender
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.allowedContentTypes = @[ UTTypeAudio, UTTypeAudiovisualContent ];
	panel.allowsMultipleSelection = YES;
	panel.prompt = @"Import";
	panel.message = @"Pick songs to copy into Music > Chipmunk Soul (the first one is loaded)";
	panel.directoryURL = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
	__weak ChipmunkSoulView_v1* weakSelf = self;
	void (^done)(NSModalResponse) = ^(NSModalResponse r) {
		if (r == NSModalResponseOK && panel.URLs.count) {
			[weakSelf importURLs:panel.URLs];
		}
	};
	if (self.window) {
		[panel beginSheetModalForWindow:self.window completionHandler:done];
	} else {
		done([panel runModal]);
	}
}

// Copies songs that live outside Music › Chipmunk Soul into it (GarageBand's plug-in helper can't read
// Downloads, Desktop or Documents), then loads the first. Songs already in the folder load as they are.
- (void)importURLs:(NSArray<NSURL*>*)urls
{
	_busy = YES;
	_statusLabel.stringValue = urls.count == 1 ? [NSString stringWithFormat:@"Importing %@…", urls.firstObject.lastPathComponent]
											   : [NSString stringWithFormat:@"Importing %d songs…", (int)urls.count];
	_statusLabel.textColor = kAccent();
	__weak ChipmunkSoulView_v1* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableArray<NSURL*>* imported = [NSMutableArray array];
		NSString* error = nil;
		for (NSURL* url in urls) {
			NSURL* copy = ImportSong(url, &error);
			if (copy) {
				[imported addObject:copy];
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			ChipmunkSoulView_v1* strong = weakSelf;
			if (!strong) {
				return;
			}
			strong->_busy = NO;
			if (imported.count) {
				[strong loadPath:imported.firstObject.path];
			} else {
				strong->_statusLabel.stringValue = error ?: @"Couldn't import that";
				strong->_statusLabel.textColor = kError();
			}
		});
	});
}

- (void)loadPath:(NSString*)path
{
	_busy = YES;
	_statusLabel.stringValue = [NSString stringWithFormat:@"Loading %@ and chopping…", path.lastPathComponent];
	_statusLabel.textColor = kAccent();
	AudioUnit au = _au;
	__weak ChipmunkSoulView_v1* weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		CFStringRef p = (__bridge CFStringRef)path;
		AudioUnitSetProperty(au, kProp_LoadFile, kAudioUnitScope_Global, 0, &p, sizeof(p));
		dispatch_async(dispatch_get_main_queue(), ^{
			ChipmunkSoulView_v1* strong = weakSelf;
			if (strong) {
				strong->_busy = NO;
				[strong refreshAll];
				[strong showChopResult];
				[strong focus];
			}
		});
	});
}

// ---- drag & drop ---------------------------------------------------------------------------------

// Prefers a file that looks like audio; otherwise takes any file and lets the loader say if it
// can't decode it (content-type lookups can fail inside a sandboxed host).
- (NSURL*)audioURLFrom:(id<NSDraggingInfo>)info
{
	NSArray<NSURL*>* urls = [info.draggingPasteboard readObjectsForClasses:@[ NSURL.class ]
																   options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
	for (NSURL* url in urls) {
		UTType* type = nil;
		[url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
		if (!type) {
			type = [UTType typeWithFilenameExtension:url.pathExtension];
		}
		if ([type conformsToType:UTTypeAudio] || [type conformsToType:UTTypeAudiovisualContent]) {
			return url;
		}
	}
	return urls.firstObject;
}

- (void)setDropHighlight:(BOOL)on
{
	_dropHighlight = on;
	self.needsDisplay = YES;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info
{
	const BOOL ok = info.draggingSource != _pads && info.draggingSource != _clip && [self audioURLFrom:info] != nil;
	[self setDropHighlight:ok];
	return ok ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info
{
	return _dropHighlight ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)info
{
	[self setDropHighlight:NO];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)info
{
	return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)info
{
	[self setDropHighlight:NO];
	NSURL* url = [self audioURLFrom:info];
	if (url) {
		[self importURLs:@[ url ]];
	}
	return url != nil;
}
@end

static void EventListenerProc(void* refCon, void*, const AudioUnitEvent* event, UInt64, AudioUnitParameterValue value)
{
	ChipmunkSoulView_v1* view = (__bridge ChipmunkSoulView_v1*)refCon;
	if (event->mEventType == kAudioUnitEvent_ParameterValueChange) {
		[view parameterChanged:event->mArgument.mParameter.mParameterID value:value];
	} else if (event->mEventType == kAudioUnitEvent_PropertyChange) {
		[view propertyChanged:event->mArgument.mProperty.mPropertyID];
	}
}

// -------------------------------------------------------------------------------------------------
#pragma mark - Factory

@interface ChipmunkSoulViewFactory_v1 : NSObject <AUCocoaUIBase>
@end

@implementation ChipmunkSoulViewFactory_v1
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"Arnold Chopper"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)au withSize:(NSSize)size
{
	return [[ChipmunkSoulView_v1 alloc] initWithAudioUnit:au];
}
@end
