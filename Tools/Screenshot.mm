// Renders the installed plug-in's editor to a PNG, with a song loaded and a few keys held.
//   clang++ -std=c++23 -fobjc-arc -ISource Tools/Screenshot.mm -framework AppKit -framework AudioToolbox -framework AudioUnit -o build/Screenshot
//   build/Screenshot "song.wav" out.png [project BPM] [MIDI notes held, or param=value...]
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#include "Shared.h"

#include <cstdlib>
#include <cstring>
#include <vector>

using namespace cs;

static double gTempo = 90;

static OSStatus BeatAndTempo(void*, Float64* beat, Float64* tempo)
{
	if (beat) *beat = 0;
	if (tempo) *tempo = gTempo;
	return noErr;
}

int main(int argc, const char* argv[])
{
	@autoreleasepool {
		if (argc < 3) {
			fprintf(stderr, "usage: Screenshot song.wav out.png [bpm] [notes...]\n");
			return 1;
		}
		[NSApplication sharedApplication];
		if (argc > 3) gTempo = atof(argv[3]);

		AudioComponentDescription d{ 'aumu', 'Cmsl', 'Antz', 0, 0 };
		AudioUnit au = nullptr;
		if (AudioComponentInstanceNew(AudioComponentFindNext(nullptr, &d), &au) != noErr) {
			fprintf(stderr, "Arnold Chopper isn't installed (run ./build.sh)\n");
			return 1;
		}
		const double sr = 44100;
		AudioStreamBasicDescription fmt{ sr, kAudioFormatLinearPCM,
			kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0 };
		AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof(fmt));
		HostCallbackInfo callbacks{};
		callbacks.beatAndTempoProc = BeatAndTempo;
		AudioUnitSetProperty(au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &callbacks, sizeof(callbacks));
		AudioUnitInitialize(au);

		CFStringRef path = (__bridge CFStringRef)[NSString stringWithUTF8String:argv[1]];
		AudioUnitSetProperty(au, kProp_LoadFile, kAudioUnitScope_Global, 0, &path, sizeof(path));

		NSString* component = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/Components/ArnoldChopper.component"];
		id<AUCocoaUIBase> factory = [[[NSBundle bundleWithPath:component] classNamed:@"ChipmunkSoulViewFactory_v1"] new];
		NSView* view = [factory uiViewForAudioUnit:au withSize:NSZeroSize];
		NSWindow* window = [[NSWindow alloc] initWithContentRect:view.bounds styleMask:NSWindowStyleMaskBorderless
														 backing:NSBackingStoreBuffered defer:NO];
		window.releasedWhenClosed = NO;
		window.contentView = view;

		// Hold the requested notes and render a little so the keys and playheads light up.
		for (int i = 4; i < argc; ++i) {
			if (const char* eq = strchr(argv[i], '=')) {
				AudioUnitParameter param{ au, AudioUnitParameterID(atoi(argv[i])), kAudioUnitScope_Global, 0 };
				AUParameterSet(nullptr, nullptr, &param, atof(eq + 1), 0);  // tells the editor too
			}
		}
		[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
		for (int i = 4; i < argc; ++i) {
			if (!strchr(argv[i], '=')) {
				MusicDeviceMIDIEvent(au, 0x90, atoi(argv[i]), 110, 0);
			}
		}
		std::vector<float> l(512), r(512);
		for (int block = 0; block < int(sr * 0.6 / 512); ++block) {
			AudioBufferList* abl = (AudioBufferList*)alloca(sizeof(AudioBufferList) + sizeof(AudioBuffer));
			abl->mNumberBuffers = 2;
			abl->mBuffers[0] = { 1, 512 * 4, l.data() };
			abl->mBuffers[1] = { 1, 512 * 4, r.data() };
			AudioTimeStamp ts{};
			ts.mSampleTime = block * 512.0;
			ts.mFlags = kAudioTimeStampSampleTimeValid;
			AudioUnitRenderActionFlags flags = 0;
			AudioUnitRender(au, &flags, &ts, 0, 512, abl);
		}
		[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];

		[view displayIfNeeded];
		NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
		[view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
		NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
		[png writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
		printf("wrote %s (%ldx%ld)\n", argv[2], (long)rep.pixelsWide, (long)rep.pixelsHigh);
		window.contentView = nil;
		[window close];
	}
	return 0;
}
