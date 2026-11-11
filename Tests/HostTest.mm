// Drives the installed component like a host: load a file, check the chop, play notes,
// verify varispeed, round-trip the saved state, and build the editor view.
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>

#include "Shared.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <cstdio>
#include <vector>

using namespace cs;

static int gFailures = 0;

@interface CSKeySpy : NSResponder
@property int keys;
@end
@implementation CSKeySpy
- (void)keyDown:(NSEvent*)event { self.keys = self.keys + 1; }
- (void)keyUp:(NSEvent*)event {}
@end
#define CHECK(cond, ...) do { bool ok_ = (cond); gFailures += !ok_; printf("%s  ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); } while (0)

static const double kSR = 44100;

// 4 bars at 90 BPM: a click every beat, each beat a different sine pitch so slices are distinguishable.
static void WriteTestFile(const char* path, double silentIntro = 0)
{
	const double beat = 60.0 / 90.0;
	const size_t intro = size_t(silentIntro * kSR);
	const size_t n = intro + size_t(16 * beat * kSR);
	std::vector<float> data(n * 2, 0.f);
	for (int b = 0; b < 16; ++b) {
		const size_t at = intro + size_t(b * beat * kSR);
		for (size_t k = 0; k < size_t(0.3 * kSR) && at + k < n; ++k) {
			const double t = k / kSR;
			const float v = 0.6f * float(std::exp(-t * 12) * std::sin(2 * M_PI * (200 + 40 * b) * t));
			data[2 * (at + k)] = data[2 * (at + k) + 1] = v;
		}
	}
	AudioStreamBasicDescription fmt{ kSR, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8*)path, strlen(path), false);
	ExtAudioFileRef f;
	ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fmt, nullptr, kAudioFileFlags_EraseFile, &f);
	AudioBufferList abl{ 1, { { 2, UInt32(data.size() * 4), data.data() } } };
	ExtAudioFileWrite(f, UInt32(n), &abl);
	ExtAudioFileDispose(f);
	CFRelease(url);
}

struct Host {
	AudioUnit au = nullptr;
	std::vector<float> L, R;

	Host()
	{
		AudioComponentDescription d{ 'aumu', 'Cmsl', 'Antz', 0, 0 };
		AudioComponent c = AudioComponentFindNext(nullptr, &d);
		if (!c || AudioComponentInstanceNew(c, &au) != noErr) {
			au = nullptr;
			return;
		}
		AudioStreamBasicDescription fmt{ kSR, kAudioFormatLinearPCM,
			kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0 };
		AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof(fmt));
		AudioUnitInitialize(au);
		AudioUnitSetParameter(au, kParam_InstantPlay, kAudioUnitScope_Global, 0, 0, 0);  // render editor notes here
	}
	~Host()
	{
		if (au) {
			AudioUnitUninitialize(au);
			AudioComponentInstanceDispose(au);
		}
	}
	// Renders `frames`, recording output.
	void Render(UInt32 frames)
	{
		static double sampleTime = 0;
		std::vector<float> l(512), r(512);
		while (frames > 0) {
			const UInt32 n = std::min<UInt32>(512, frames);
			AudioBufferList* abl = (AudioBufferList*)alloca(sizeof(AudioBufferList) + sizeof(AudioBuffer));
			abl->mNumberBuffers = 2;
			abl->mBuffers[0] = { 1, n * 4, l.data() };
			abl->mBuffers[1] = { 1, n * 4, r.data() };
			AudioTimeStamp ts{};
			ts.mSampleTime = sampleTime;
			ts.mFlags = kAudioTimeStampSampleTimeValid;
			AudioUnitRenderActionFlags flags = 0;
			AudioUnitRender(au, &flags, &ts, 0, n, abl);
			L.insert(L.end(), l.begin(), l.begin() + n);
			R.insert(R.end(), r.begin(), r.begin() + n);
			sampleTime += n;
			frames -= n;
		}
	}
	std::vector<uint32_t> Slices()
	{
		CFDataRef data = nullptr;
		UInt32 size = sizeof(data);
		AudioUnitGetProperty(au, kProp_Slices, kAudioUnitScope_Global, 0, &data, &size);
		std::vector<uint32_t> out;
		if (data) {
			SliceHeader h;
			memcpy(&h, CFDataGetBytePtr(data), sizeof(h));
			out.resize(h.count);
			memcpy(out.data(), CFDataGetBytePtr(data) + sizeof(h), h.count * 4);
			CFRelease(data);
		}
		return out;
	}
};

static double Rms(const std::vector<float>& v, size_t a, size_t b)
{
	double s = 0;
	for (size_t i = a; i < b && i < v.size(); ++i) s += v[i] * v[i];
	return std::sqrt(s / std::max<size_t>(1, b - a));
}

// Length of the audible part after `from` (first and last sample above -60 dB-ish).
static double SoundingSeconds(const std::vector<float>& v, size_t from)
{
	size_t first = 0, last = 0;
	for (size_t i = from; i < v.size(); ++i) {
		if (std::abs(v[i]) > 1e-3f) {
			if (!first) first = i;
			last = i;
		}
	}
	return first ? (last - first) / kSR : 0;
}

int main(int argc, char** argv)
{
	@autoreleasepool {
		const char* path = argc > 1 ? argv[1] : "/tmp/cs_test.wav";
		WriteTestFile(path);

		Host h;
		CHECK(h.au != nullptr, "component found and instantiated");
		if (!h.au) return 1;

		ChopSettings beats{ kChop_Beats, 16, 0.5f, 0, 0, -1 };
		AudioUnitSetProperty(h.au, kProp_ChopSettings, kAudioUnitScope_Global, 0, &beats, sizeof(beats));
		CFStringRef p = CFStringCreateWithCString(nullptr, path, kCFStringEncodingUTF8);
		AudioUnitSetProperty(h.au, kProp_LoadFile, kAudioUnitScope_Global, 0, &p, sizeof(p));
		CFRelease(p);

		auto slices = h.Slices();
		const double beatFrames = 60.0 / 90.0 * kSR;
		double worst = 0;
		for (size_t i = 0; i < slices.size(); ++i) worst = std::max(worst, std::abs(slices[i] - i * beatFrames) / kSR * 1000);
		CHECK(slices.size() == 16 && worst < 8, "beat chop: %zu slices, worst %.1f ms off the beat", slices.size(), worst);

		CFDictionaryRef info = nullptr;
		UInt32 size = sizeof(info);
		AudioUnitGetProperty(h.au, kProp_Info, kAudioUnitScope_Global, 0, &info, &size);
		double bpm = [((__bridge NSDictionary*)info)[(__bridge NSString*)kInfoSampleBPM] doubleValue];
		CHECK(std::abs(bpm - 90) < 1, "detected %.2f BPM (true 90)", bpm);
		CFRelease(info);

		// Silence before any notes.
		h.Render(4096);
		CHECK(Rms(h.L, 0, 4096) == 0, "silent with no notes");

		// A tap plays only while the key is down: C3 (60) is slice 1, a one-beat chop (0.67 s).
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 0, 0);
		size_t mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(UInt32(kSR * 0.15));
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.5));
		CHECK(Rms(h.L, mark, mark + 4096) > 0.05 && Rms(h.L, mark + size_t(kSR * 0.3), mark + size_t(kSR * 0.6)) < 1e-4,
			"tap: note 60 plays slice 1 (rms %.3f) and stops when released, mid-chop", Rms(h.L, mark, mark + 4096));

		// Varispeed: +12 semitones moves through the record twice as fast.
		auto travelIn = [&](double seconds) {
			MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
			h.Render(UInt32(seconds * kSR));
			Playheads ph{};
			UInt32 sz = sizeof(ph);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &sz);
			double frame = -1;
			for (uint32_t k = 0; k < ph.count; ++k) if (ph.slices[k] == 0) frame = ph.frames[k];
			MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
			h.Render(UInt32(kSR * 0.3));
			return (frame - slices[0]) / kSR;
		};
		const double at0 = travelIn(0.2);
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 12, 0);
		const double at12 = travelIn(0.2);
		CHECK(std::abs(at12 / at0 - 2.0) < 0.05, "varispeed: in 0.2 s, +12 st covers %.3fs of the record vs %.3fs at 0 st (x%.2f)",
			at12, at0, at12 / at0);

		// Holding a key sounds; releasing it stops the sound.
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 4, 0);
		AudioUnitSetParameter(h.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 1, 0);
		AudioUnitSetParameter(h.au, kParam_Release, kAudioUnitScope_Global, 0, 10, 0);
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 63, 100, 0);
		h.Render(2205);
		MusicDeviceMIDIEvent(h.au, 0x80, 63, 0, 0);
		h.Render(UInt32(kSR * 0.5));
		CHECK(Rms(h.L, mark, mark + 2205) > 0.02 && Rms(h.L, mark + 4410, mark + 22050) < 1e-4,
			"hold then release: sounds while held (rms %.3f), silent after release", Rms(h.L, mark, mark + 2205));

		// Out-of-range note does nothing.
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 40, 100, 0);
		h.Render(4096);
		CHECK(Rms(h.L, mark, mark + 4096) == 0, "note below the root is silent");

		// Crunch + filters still produce sane output (no NaNs, no blow-up).
		AudioUnitSetParameter(h.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Crunch, kAudioUnitScope_Global, 0, 100, 0);
		AudioUnitSetParameter(h.au, kParam_LowCut, kAudioUnitScope_Global, 0, 300, 0);
		AudioUnitSetParameter(h.au, kParam_HighCut, kAudioUnitScope_Global, 0, 3000, 0);
		AudioUnitSetParameter(h.au, kParam_Reverse, kAudioUnitScope_Global, 0, 1, 0);
		mark = h.L.size();
		for (int n = 60; n < 76; ++n) MusicDeviceMIDIEvent(h.au, 0x90, n, 127, UInt32((n - 60) * 300));
		h.Render(UInt32(kSR));
		float peak = 0;
		bool finite = true;
		for (size_t i = mark; i < h.L.size(); ++i) { peak = std::max(peak, std::abs(h.L[i])); finite = finite && std::isfinite(h.L[i]); }
		CHECK(finite && peak > 0.01 && peak < 2.0, "16 notes with crunch/filters/reverse: peak %.3f, finite", peak);
		MusicDeviceMIDIEvent(h.au, 0xB0, 123, 0, 0);  // all notes off
		h.Render(UInt32(kSR * 0.2));

		// Hold to keep going: one-shot slice 1 is one beat (0.667 s); holding the key for 1.5 s
		// keeps playing into slices 2 and 3, and letting go fades it out.
		AudioUnitSetParameter(h.au, kParam_Crunch, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_LowCut, kAudioUnitScope_Global, 0, 20, 0);
		AudioUnitSetParameter(h.au, kParam_HighCut, kAudioUnitScope_Global, 0, 20000, 0);
		AudioUnitSetParameter(h.au, kParam_Reverse, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Release, kAudioUnitScope_Global, 0, 30, 0);
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(UInt32(kSR * 1.5));
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.5));
		const double beat = 60.0 / 90.0;
		CHECK(Rms(h.L, mark + size_t(kSR * (beat + 0.02)), mark + size_t(kSR * (beat + 0.25))) > 0.05 &&
				  Rms(h.L, mark + size_t(kSR * 1.7), mark + size_t(kSR * 2.0)) < 1e-4,
			"hold: keeps playing into the next chop while held, fades after release");

		// Stop at end: the same 1.5 s hold now stops when the chop (one beat) ends.
		AudioUnitSetParameter(h.au, kParam_EndMode, kAudioUnitScope_Global, 0, kEndStop, 0);
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(UInt32(kSR * 1.5));
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.2));
		AudioUnitSetParameter(h.au, kParam_EndMode, kAudioUnitScope_Global, 0, kEndContinue, 0);
		CHECK(Rms(h.L, mark, mark + 4410) > 0.05 && Rms(h.L, mark + size_t(kSR * (beat + 0.02)), mark + size_t(kSR * 1.4)) < 1e-4,
			"stop at end: a held key stops at the end of its chop");

		// Loop: holding chop 1 (one beat, 0.667 s) for 1.5 s plays it over and over: the playhead
		// never leaves the chop, and the second time round sounds like the first.
		AudioUnitSetParameter(h.au, kParam_EndMode, kAudioUnitScope_Global, 0, kEndLoop, 0);
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		bool stayedInChop = true;
		for (int b = 0; b < 30; ++b) {
			h.Render(2205);
			Playheads lp{};
			UInt32 lpSize = sizeof(lp);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &lp, &lpSize);
			for (uint32_t k = 0; k < lp.count; ++k)
				if (lp.slices[k] == 0) stayedInChop = stayedInChop && lp.frames[k] >= slices[0] && lp.frames[k] < slices[1];
		}
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.2));
		AudioUnitSetParameter(h.au, kParam_EndMode, kAudioUnitScope_Global, 0, kEndContinue, 0);
		const size_t cycle = size_t(slices[1] - slices[0]);
		const double firstPass = Rms(h.L, mark + 441, mark + 441 + 8820), secondPass = Rms(h.L, mark + cycle + 441, mark + cycle + 441 + 8820);
		CHECK(stayedInChop && secondPass > 0.05 && std::abs(secondPass / firstPass - 1.0) < 0.1,
			"loop: a held chop repeats (second pass level %.3f vs first %.3f) and never plays past its end", secondPass, firstPass);

		// Polyphony: ten keys held at once all sound together.
		for (int n = 60; n < 70; ++n) MusicDeviceMIDIEvent(h.au, 0x90, n, 100, 0);
		h.Render(2048);
		Playheads poly{};
		UInt32 polySize = sizeof(poly);
		AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &poly, &polySize);
		int voices = 0;
		for (uint32_t i = 0; i < poly.count; ++i) voices += poly.slices[i] >= 0;
		CHECK(voices == 10, "ten keys held at once: %d voices playing", voices);
		for (int n = 60; n < 70; ++n) MusicDeviceMIDIEvent(h.au, 0x80, n, 0, 0);
		h.Render(UInt32(kSR * 0.3));

		// Mute groups: chops 1 and 2 in group A cut each other off; chop 3 (no group) doesn't.
		auto voicesPlaying = [&]() {
			Playheads ph{};
			UInt32 sz = sizeof(ph);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &sz);
			std::vector<int> playing;
			for (uint32_t k = 0; k < ph.count; ++k) if (ph.slices[k] >= 0) playing.push_back(ph.slices[k]);
			std::sort(playing.begin(), playing.end());
			return playing;
		};
		uint8_t groups[kMaxSlices] = {};
		groups[0] = groups[1] = 1;
		CFDataRef groupData = CFDataCreate(nullptr, groups, kMaxSlices);
		AudioUnitSetProperty(h.au, kProp_MuteGroups, kAudioUnitScope_Global, 0, &groupData, sizeof(groupData));
		CFRelease(groupData);
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 100, 0);
		h.Render(2048);
		MusicDeviceMIDIEvent(h.au, 0x90, 62, 100, 0);  // chop 3, no group
		h.Render(2048);
		MusicDeviceMIDIEvent(h.au, 0x90, 61, 100, 0);  // chop 2, group A: cuts chop 1
		h.Render(UInt32(kSR * 0.1));
		const auto stillPlaying = voicesPlaying();
		CHECK((stillPlaying == std::vector<int>{ 1, 2 }), "mute group A: chop 2 cut off chop 1, chop 3 kept playing (%zu voices)",
			stillPlaying.size());
		for (int n : { 60, 61, 62 }) MusicDeviceMIDIEvent(h.au, 0x80, n, 0, 0);
		h.Render(UInt32(kSR * 0.3));

		// Tempo sync: a 90 BPM sample in a 120 BPM project must play each beat-slice in 0.5 s.
		AudioUnitSetParameter(h.au, kParam_Crunch, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_LowCut, kAudioUnitScope_Global, 0, 20, 0);
		AudioUnitSetParameter(h.au, kParam_HighCut, kAudioUnitScope_Global, 0, 20000, 0);
		AudioUnitSetParameter(h.au, kParam_Reverse, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 0, 0);
		HostCallbackInfo cb{};
		cb.beatAndTempoProc = [](void*, Float64* beat, Float64* tempo) -> OSStatus {
			if (beat) *beat = 0;
			if (tempo) *tempo = 120;
			return noErr;
		};
		AudioUnitSetProperty(h.au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &cb, sizeof(cb));
		// Slice 1 of the test file holds one 300 ms ping, so measure the slice by position instead:
		// the playhead must cover one beat of source audio in 0.5 s of output.
		auto playheadAfter = [&](double seconds) {
			h.Render(UInt32(seconds * kSR));
			Playheads ph{};
			UInt32 sz = sizeof(ph);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &sz);
			for (uint32_t i = 0; i < ph.count; ++i) if (ph.slices[i] >= 0) return double(ph.frames[i]);
			return -1.0;
		};
		h.Render(512);
		MusicDeviceMIDIEvent(h.au, 0x90, 61, 127, 0);  // slice 2 starts at one beat
		const double travelled = playheadAfter(0.25) - slices[1];
		MusicDeviceMIDIEvent(h.au, 0xB0, 123, 0, 0);
		h.Render(UInt32(kSR * 0.2));
		CFDictionaryRef info2 = nullptr;
		size = sizeof(info2);
		AudioUnitGetProperty(h.au, kProp_Info, kAudioUnitScope_Global, 0, &info2, &size);
		const double playing = [((__bridge NSDictionary*)info2)[(__bridge NSString*)kInfoPitch] doubleValue];
		CFRelease(info2);
		// 0.25 s at 120/90 speed covers 0.333 s of the source.
		CHECK(std::abs(travelled / kSR - 0.25 * 120 / 90) < 0.01 && std::abs(playing - 12 * std::log2(120.0 / 90)) < 0.05,
			"sync: 90 BPM sample locked to 120 BPM song (pitch %+.2f st, %.3fs of source in 0.25s)", playing, travelled / kSR);
		AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 0, 0);
		h.Render(UInt32(kSR));
		MusicDeviceMIDIEvent(h.au, 0x90, 61, 127, 0);
		const double manual = playheadAfter(0.25) - slices[1];
		CHECK(std::abs(manual / kSR - 0.25) < 0.01, "sync off: Pitch knob (0 st) is back in charge (%.3fs of source)", manual / kSR);
		MusicDeviceMIDIEvent(h.au, 0xB0, 123, 0, 0);  // let go of the held test notes
		h.Render(UInt32(kSR));

		// Tempo changes: a chop held while GarageBand plays stays locked to the song's beat through
		// tempo changes, even when GarageBand throws away audio it rendered ahead and renders it again.
		{
			static double gSyncBeat = 0, gSyncTempo = 120;
			HostCallbackInfo syncCb{};
			syncCb.beatAndTempoProc = [](void*, Float64* b, Float64* t) -> OSStatus {
				if (b) *b = gSyncBeat;
				if (t) *t = gSyncTempo;
				return noErr;
			};
			syncCb.transportStateProc = [](void*, Boolean* playing, Boolean*, Float64*, Boolean*, Float64*, Float64*) -> OSStatus {
				if (playing) *playing = true;
				return noErr;
			};
			AudioUnitSetProperty(h.au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &syncCb, sizeof(syncCb));
			AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 1, 0);
			AudioUnitSetParameter(h.au, kParam_KeepPitch, kAudioUnitScope_Global, 0, 0, 0);
			AudioUnitSetParameter(h.au, kParam_EndMode, kAudioUnitScope_Global, 0, kEndContinue, 0);
			CFDictionaryRef syncInfo = nullptr;
			UInt32 infoSize = sizeof(syncInfo);
			AudioUnitGetProperty(h.au, kProp_Info, kAudioUnitScope_Global, 0, &syncInfo, &infoSize);
			const double sampleBPM = [((__bridge NSDictionary*)syncInfo)[(__bridge NSString*)kInfoSampleBPM] doubleValue];
			CFRelease(syncInfo);
			// Renders one block at the current song position and moves the position on.
			auto block = [&]() {
				h.Render(512);
				gSyncBeat += 512 / kSR * gSyncTempo / 60.0;
			};
			gSyncBeat = 8.0;
			MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);  // hold chop 1 from beat 8
			const double startBeat = gSyncBeat;
			for (double tempo : { 120.0, 100.0, 140.0, 95.0 }) {
				gSyncTempo = tempo;
				for (int b = 0; b < 40; ++b) block();
				// GarageBand drops the last 10 blocks it rendered ahead and renders them again.
				gSyncBeat -= 10 * 512 / kSR * gSyncTempo / 60.0;
				for (int b = 0; b < 10; ++b) block();
			}
			Playheads ph{};
			UInt32 phSize = sizeof(ph);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &phSize);
			double frame = -1;
			for (uint32_t k = 0; k < ph.count; ++k) if (ph.slices[k] == 0) frame = ph.frames[k];
			// Synced, one beat of the song plays one beat of the record (all these tempos keep the same octave).
			const double framesPerBeat = kSR * 60.0 / sampleBPM;
			const double expected = slices[0] + (gSyncBeat - startBeat) * framesPerBeat;
			const double offBeats = (frame - expected) / framesPerBeat;
			MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
			h.Render(UInt32(kSR * 0.3));
			AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 0, 0);
			AudioUnitSetProperty(h.au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &cb, sizeof(cb));  // back to the 120 BPM, stopped host
			CHECK(std::abs(offBeats) < 0.01, "tempo changes: held chop stays on the song's beat after 4 tempo changes and re-renders (%.3f beats off)",
				offBeats);
		}

		// Editor press-and-hold in Gate mode: sounds while held, stops on release.
		AudioUnitSetParameter(h.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 1, 0);
		int32_t pad = 3;
		mark = h.L.size();
		AudioUnitSetProperty(h.au, kProp_Audition, kAudioUnitScope_Global, 0, &pad, sizeof(pad));
		h.Render(2205);
		pad = -2 - 3;
		AudioUnitSetProperty(h.au, kProp_Audition, kAudioUnitScope_Global, 0, &pad, sizeof(pad));
		h.Render(UInt32(kSR * 0.5));
		CHECK(Rms(h.L, mark, mark + 2205) > 0.02 && Rms(h.L, mark + 8820, mark + 22050) < 1e-4,
			"editor key: press plays, release stops");
		AudioUnitSetParameter(h.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 0, 0);

		// ---- per-chop tweaks, drums, Keep Pitch, swing, vinyl, export ----
		AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Pitch, kAudioUnitScope_Global, 0, 0, 0);
		auto chopTravel = [&](int note, int slice, double seconds) {  // seconds of record covered while held
			MusicDeviceMIDIEvent(h.au, 0x90, note, 127, 0);
			h.Render(UInt32(seconds * kSR));
			Playheads ph{};
			UInt32 sz = sizeof(ph);
			AudioUnitGetProperty(h.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &sz);
			double frame = -1;
			for (uint32_t k = 0; k < ph.count; ++k) if (ph.slices[k] == slice) frame = ph.frames[k];
			MusicDeviceMIDIEvent(h.au, 0x80, note, 0, 0);
			h.Render(UInt32(kSR * 0.3));
			return (frame - slices[size_t(slice)]) / kSR;
		};
		auto setEdits = [&](std::vector<std::pair<int, ChopEdit>> changes) {
			ChopEdit edits[kMaxSlices] = {};
			for (auto& [i, e] : changes) edits[i] = e;
			CFDataRef d = CFDataCreate(nullptr, (const UInt8*)edits, sizeof(edits));
			AudioUnitSetProperty(h.au, kProp_ChopEdits, kAudioUnitScope_Global, 0, &d, sizeof(d));
			CFRelease(d);
		};
		setEdits({ { 1, { 12.f, -12.f, 0 } }, { 2, { 0.f, 0.f, 1 } } });
		const double base = chopTravel(60, 0, 0.2), up = chopTravel(61, 1, 0.2), back = chopTravel(62, 2, 0.2);
		// Reversed, chop 3 starts at its end and moves back: after 0.2 s it's 0.2 s before the end.
		const double len3 = (slices[3] - slices[2]) / kSR;
		CHECK(std::abs(up / base - 2.0) < 0.05 && std::abs(back - (len3 - 0.2)) < 0.02,
			"per-chop pitch +12 plays chop 2 twice as fast (x%.2f); per-chop reverse plays chop 3 backwards (%.2fs)", up / base, back);
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(4410);
		const double loud = Rms(h.L, mark, mark + 4410);
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.3));
		setEdits({ { 0, { 0.f, -12.f, 0 } } });
		mark = h.L.size();
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(4410);
		const double quiet = Rms(h.L, mark, mark + 4410);
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 0.3));
		CHECK(std::abs(quiet / loud - 0.251) < 0.02, "per-chop volume -12 dB (level x%.3f)", quiet / loud);
		setEdits({});

		// Drums: the octave below the root (C2 = 48 is the kick when the root is C3).
		bool drumsOK = true;
		std::string offKits;
		for (int kit = 0; kit < kNumDrumKits; ++kit) {
			AudioUnitSetParameter(h.au, kParam_DrumKit, kAudioUnitScope_Global, 0, kit, 0);
			for (int d = 0; d < kNumDrums; ++d) {
				mark = h.L.size();
				MusicDeviceMIDIEvent(h.au, 0x90, 60 + kDrumOffsets[d], 120, 0);
				h.Render(4410);
				const double level = Rms(h.L, mark, mark + 4410);
				if (!(level > 0.01 && level < 1.0)) {
					drumsOK = false;
					offKits += std::string(" ") + kDrumKitNames[kit] + "/" + kDrumNames[d] + "=" + std::to_string(level);
				}
				MusicDeviceMIDIEvent(h.au, 0xB0, 120, 0, 0);  // all sound off between hits
				h.Render(UInt32(kSR * 0.1));
			}
		}
		AudioUnitSetParameter(h.au, kParam_DrumKit, kAudioUnitScope_Global, 0, 0, 0);
		h.Render(UInt32(kSR * 3));
		if (!offKits.empty()) printf("      out of range:%s\n", offKits.c_str());
		// Closed hat cuts a ringing open hat.
		MusicDeviceMIDIEvent(h.au, 0x90, 60 + kDrumOffsets[kDrumOpenHat], 120, 0);
		h.Render(4410);
		MusicDeviceMIDIEvent(h.au, 0x90, 60 + kDrumOffsets[kDrumClosedHat], 120, 0);
		h.Render(UInt32(kSR * 0.2));
		mark = h.L.size();
		h.Render(4410);
		CHECK(drumsOK && Rms(h.L, mark, mark + 4410) < 1e-4, "drums: all %d sounds play in all %d kits, closed hat chokes the open hat", kNumDrums, kNumDrumKits);
		h.Render(UInt32(kSR));

		// Keep Pitch: synced to 120 BPM (record is 90) the chop moves 1.33x faster but keeps its
		// pitch; varispeed raises the pitch by the same 1.33x. Chop 2 is a 240 Hz ping.
		auto pingHz = [&]() {
			mark = h.L.size();
			MusicDeviceMIDIEvent(h.au, 0x90, 61, 127, 0);
			h.Render(UInt32(kSR * 0.2));
			MusicDeviceMIDIEvent(h.au, 0x80, 61, 0, 0);
			h.Render(UInt32(kSR * 0.3));
			int crossings = 0;
			const size_t a = mark + 1000, b = mark + 1000 + size_t(kSR * 0.12);
			for (size_t i = a + 1; i < b; ++i) crossings += (h.L[i - 1] < 0) != (h.L[i] < 0);
			return crossings / 2.0 / ((b - a) / kSR);
		};
		AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 1, 0);
		const double variHz = pingHz();
		AudioUnitSetParameter(h.au, kParam_KeepPitch, kAudioUnitScope_Global, 0, 1, 0);
		const double keptHz = pingHz();
		const double keptTravel = chopTravel(61, 1, 0.3);
		CHECK(std::abs(variHz / 240 - 4.0 / 3) < 0.05 && std::abs(keptHz / 240 - 1.0) < 0.05 && std::abs(keptTravel / 0.3 - 4.0 / 3) < 0.05,
			"Keep Pitch: %.0f Hz (record 240 Hz, varispeed %.0f Hz), moving x%.2f to match 120 BPM", keptHz, variHz, keptTravel / 0.3);
		AudioUnitSetParameter(h.au, kParam_KeepPitch, kAudioUnitScope_Global, 0, 0, 0);
		AudioUnitSetParameter(h.au, kParam_Sync, kAudioUnitScope_Global, 0, 0, 0);

		// Swing 66%: with the song playing, a note on the second 16th of a beat is pushed back by
		// (0.66 - 0.5) of an 8th note; a note on the beat isn't.
		static double gBeat = 0;
		HostCallbackInfo cb2{};
		cb2.beatAndTempoProc = [](void*, Float64* b, Float64* t) -> OSStatus {
			if (b) *b = gBeat;
			if (t) *t = 120;
			return noErr;
		};
		cb2.transportStateProc = [](void*, Boolean* playing, Boolean*, Float64*, Boolean*, Float64*, Float64*) -> OSStatus {
			if (playing) *playing = true;
			return noErr;
		};
		AudioUnitSetProperty(h.au, kAudioUnitProperty_HostCallbacks, kAudioUnitScope_Global, 0, &cb2, sizeof(cb2));
		AudioUnitSetParameter(h.au, kParam_Swing, kAudioUnitScope_Global, 0, 66, 0);
		auto onsetAfter = [&](double beatAtBlockStart) {
			gBeat = beatAtBlockStart;
			mark = h.L.size();
			MusicDeviceMIDIEvent(h.au, 0x90, 60 + kDrumOffsets[kDrumRim], 127, 0);  // rim: instant and short, easy to time
			h.Render(UInt32(kSR * 0.2));
			for (size_t i = mark; i < h.L.size(); ++i) if (std::abs(h.L[i]) > 1e-3) return double(i - mark);
			return -1.0;

		};
		const double onBeat = onsetAfter(4.0);
		h.Render(UInt32(kSR * 2));  // let the kick die away
		const double offBeat = onsetAfter(4.25);
		const double expected = (0.66 - 0.5) * 0.5 * 0.5 * kSR;  // 8th at 120 BPM = 0.25 s
		AudioUnitSetParameter(h.au, kParam_Swing, kAudioUnitScope_Global, 0, 50, 0);
		CHECK(onBeat < 64 && std::abs(offBeat - expected) < 64, "swing 66%%: off-beat 16th delayed %.0f samples (expected %.0f), on-beat %.0f",
			offBeat, expected, onBeat);
		h.Render(UInt32(kSR * 1.5));

		// Vinyl: crackle and hiss ride along while a chop plays and go quiet afterwards.
		AudioUnitSetParameter(h.au, kParam_Vinyl, kAudioUnitScope_Global, 0, 100, 0);
		AudioUnitSetParameter(h.au, kParam_HighCut, kAudioUnitScope_Global, 0, 20000, 0);
		h.Render(UInt32(kSR * 0.5));
		mark = h.L.size();
		h.Render(4410);
		const double idle = Rms(h.L, mark, mark + 4410);
		MusicDeviceMIDIEvent(h.au, 0x90, 60, 127, 0);
		h.Render(UInt32(kSR * 0.5));
		MusicDeviceMIDIEvent(h.au, 0x80, 60, 0, 0);
		h.Render(UInt32(kSR * 2));
		mark = h.L.size();
		h.Render(4410);
		const double after = Rms(h.L, mark, mark + 4410);
		AudioUnitSetParameter(h.au, kParam_Vinyl, kAudioUnitScope_Global, 0, 0, 0);
		CHECK(idle == 0 && after < 1e-4, "vinyl: silent when nothing plays (before %.6f, after %.6f)", idle, after);

		// Export: chop 1 (one beat, 0.667 s at pitch 0) lands in Music/Chipmunk Soul/Chops.
		int32_t exportSlice = 0;
		OSStatus exportErr = AudioUnitSetProperty(h.au, kProp_ExportChop, kAudioUnitScope_Global, 0, &exportSlice, sizeof(exportSlice));
		CFStringRef exported = nullptr;
		size = sizeof(exported);
		AudioUnitGetProperty(h.au, kProp_ExportPath, kAudioUnitScope_Global, 0, &exported, &size);
		NSString* exportPath = (__bridge_transfer NSString*)exported;
		double exportSeconds = 0;
		if (exportErr == noErr && exportPath.length) {
			ExtAudioFileRef ef;
			if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:exportPath], &ef) == noErr) {
				SInt64 frames = 0;
				UInt32 fs = sizeof(frames);
				ExtAudioFileGetProperty(ef, kExtAudioFileProperty_FileLengthFrames, &fs, &frames);
				exportSeconds = frames / 44100.0;
				ExtAudioFileDispose(ef);
			}
			[NSFileManager.defaultManager removeItemAtPath:exportPath error:nil];
		}
		CHECK(std::abs(exportSeconds - (slices[1] - slices[0]) / kSR) < 0.01, "export: chop 1 written as a %.3f s WAV", exportSeconds);

		// Edit slices, save state, restore into a fresh instance (sync was left off above).
		std::vector<uint32_t> edited(slices.begin(), slices.begin() + 5);
		edited[2] += 1234;
		SliceHeader sh{ 0, slices.back() + 20000, uint32_t(edited.size()) };
		NSMutableData* d = [NSMutableData dataWithBytes:&sh length:sizeof(sh)];
		[d appendBytes:edited.data() length:edited.size() * 4];
		CFDataRef dref = (__bridge CFDataRef)d;
		AudioUnitSetProperty(h.au, kProp_Slices, kAudioUnitScope_Global, 0, &dref, sizeof(dref));
		CFPropertyListRef state = nullptr;
		size = sizeof(state);
		AudioUnitGetProperty(h.au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, &size);

		Host h2;
		AudioUnitSetProperty(h2.au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &state, sizeof(state));
		CFRelease(state);
		CFDataRef restoredGroups = nullptr;
		size = sizeof(restoredGroups);
		AudioUnitGetProperty(h2.au, kProp_MuteGroups, kAudioUnitScope_Global, 0, &restoredGroups, &size);
		const bool groupsKept = restoredGroups && CFDataGetBytePtr(restoredGroups)[0] == 1 && CFDataGetBytePtr(restoredGroups)[1] == 1 &&
								CFDataGetBytePtr(restoredGroups)[2] == 0;
		if (restoredGroups) CFRelease(restoredGroups);
		auto restored = h2.Slices();
		AudioUnitParameterValue playMode = 0, sync = 1;
		AudioUnitGetParameter(h2.au, kParam_PlayMode, kAudioUnitScope_Global, 0, &playMode);
		AudioUnitGetParameter(h2.au, kParam_Sync, kAudioUnitScope_Global, 0, &sync);
		CHECK(restored == edited && playMode == 0 && sync == 0 && groupsKept, "state round-trip: %zu edited slices and params restored", restored.size());

		// The editor view builds and lays out without a window.
		AudioUnitCocoaViewInfo vi{};
		size = sizeof(vi);
		OSStatus err = AudioUnitGetProperty(h2.au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &vi, &size);
		NSView* view = nil;
		if (err == noErr) {
			NSBundle* b = [NSBundle bundleWithURL:(__bridge NSURL*)vi.mCocoaAUViewBundleLocation];
			Class cls = [b classNamed:(__bridge NSString*)vi.mCocoaAUViewClass[0]];
			id<AUCocoaUIBase> factory = [[cls alloc] init];
			view = [factory uiViewForAudioUnit:h2.au withSize:NSZeroSize];
			NSBitmapImageRep* rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
			[view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
			NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
			NSString* out = [[NSString stringWithUTF8String:path] stringByAppendingString:@".png"];
			[png writeToFile:out atomically:YES];
			printf("      editor screenshot: %s\n", out.UTF8String);
			CFRelease(vi.mCocoaAUViewBundleLocation);
			CFRelease(vi.mCocoaAUViewClass[0]);
		}
		CHECK(view && view.frame.size.width > 0, "editor view created (%.0fx%.0f)", view.frame.size.width, view.frame.size.height);

		// Laptop keys: Shift+W (second piano key, C#) plays slice 2; W without Shift does nothing.
		AudioUnitSetParameter(h2.au, kParam_Sync, kAudioUnitScope_Global, 0, 0, 0);
		h2.Render(1024);
		auto key = [&](NSEventType type, unsigned short code, NSString* chars, NSEventModifierFlags mods) {
			return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:0
									 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
		};
		mark = h2.L.size();
		@try {
			[view keyDown:key(NSEventTypeKeyDown, 13, @"w", 0)];  // unhandled without Shift: goes up the responder chain
		} @catch (NSException*) {
		}
		h2.Render(4096);
		const double plain = Rms(h2.L, mark, mark + 4096);
		mark = h2.L.size();
		[view keyDown:key(NSEventTypeKeyDown, 13, @"W", NSEventModifierFlagShift)];
		h2.Render(4096);
		[view keyUp:key(NSEventTypeKeyUp, 13, @"w", 0)];
		Playheads ph{};
		size = sizeof(ph);
		AudioUnitGetProperty(h2.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &size);
		int playingSlice = -1;
		for (uint32_t i = 0; i < ph.count; ++i) if (ph.slices[i] >= 0) playingSlice = ph.slices[i];
		CHECK(plain == 0 && Rms(h2.L, mark, mark + 4096) > 0.02 && playingSlice == 1,
			"laptop keys: W alone is silent, Shift+W plays slice 2 (rms %.3f)", Rms(h2.L, mark, mark + 4096));

		// Instant response: a drum pad or a chop pressed in the editor sounds from the very next
		// sample the plug-in renders.
		auto firstAudible = [&](int32_t value) {
			h2.Render(UInt32(kSR * 2));
			const size_t from = h2.L.size();
			AudioUnitSetProperty(h2.au, kProp_Audition, kAudioUnitScope_Global, 0, &value, sizeof(value));
			h2.Render(2048);
			for (size_t i = from; i < h2.L.size(); ++i) if (std::abs(h2.L[i]) > 0.01f) return int(i - from);
			return -1;
		};
		int worstDrum = 0;
		for (int d = 0; d < kNumDrums; ++d) worstDrum = std::max(worstDrum, firstAudible(kAuditionDrum + d));
		const int chopDelay = firstAudible(1);
		int32_t allOff = -1;
		AudioUnitSetProperty(h2.au, kProp_Audition, kAudioUnitScope_Global, 0, &allOff, sizeof(allOff));
		// (A chop starts a hair before its hit, with a 1 ms fade-in, so allow a few ms of its own lead-in.)
		CHECK(worstDrum >= 0 && worstDrum < 32 && chopDelay >= 0 && chopDelay < 0.005 * kSR,
			"instant: drum pads sound within %d samples, chops within %d", worstDrum, chopDelay);

		// Keyboard focus: keys without Shift stay in the plug-in (passing them on let GarageBand take
		// the keyboard away); ⌘ shortcuts still go through to GarageBand.
		CSKeySpy* spy = [CSKeySpy new];
		view.nextResponder = spy;
		[view keyDown:key(NSEventTypeKeyDown, 12, @"q", 0)];
		[view keyUp:key(NSEventTypeKeyUp, 12, @"q", 0)];
		const int strayPassed = spy.keys;
		[view keyDown:key(NSEventTypeKeyDown, 1, @"s", NSEventModifierFlagCommand)];
		CHECK(strayPassed == 0 && spy.keys == 1, "focus: a key without Shift stays in the plug-in, ⌘ shortcuts pass through");

		// Instant Play: with the editor open, its notes play on their own output straight to the
		// speakers (GarageBand's render stays silent), and they show on the playheads.
		{
			AudioUnitSetParameter(h2.au, kParam_Volume, kAudioUnitScope_Global, 0, -40, 0);  // quiet on the speakers
			AudioUnitSetParameter(h2.au, kParam_InstantPlay, kAudioUnitScope_Global, 0, 1, 0);
			h2.Render(UInt32(kSR * 2));
			mark = h2.L.size();
			int32_t chop = 1;
			AudioUnitSetProperty(h2.au, kProp_Audition, kAudioUnitScope_Global, 0, &chop, sizeof(chop));
			[NSThread sleepForTimeInterval:0.15];
			h2.Render(4096);
			Playheads ph{};
			UInt32 phSize = sizeof(ph);
			AudioUnitGetProperty(h2.au, kProp_Playheads, kAudioUnitScope_Global, 0, &ph, &phSize);
			int instantSlice = -1;
			for (uint32_t k = 0; k < ph.count; ++k) if (ph.slices[k] >= 0) instantSlice = ph.slices[k];
			int32_t release = -2 - 1;
			AudioUnitSetProperty(h2.au, kProp_Audition, kAudioUnitScope_Global, 0, &release, sizeof(release));
			AudioUnitSetParameter(h2.au, kParam_InstantPlay, kAudioUnitScope_Global, 0, 0, 0);
			int32_t allOff = -1;
			AudioUnitSetProperty(h2.au, kProp_Audition, kAudioUnitScope_Global, 0, &allOff, sizeof(allOff));  // back to GarageBand's render
			AudioUnitSetParameter(h2.au, kParam_Volume, kAudioUnitScope_Global, 0, 0, 0);
			CHECK(instantSlice == 1 && Rms(h2.L, mark, mark + 4096) == 0,
				"instant play: an editor note plays on its own output (playing chop %d), not through GarageBand's render", instantSlice + 1);
			h2.Render(UInt32(kSR));
		}

		// Keys reach the plug-in even when another control in its window has focus (here the kit menu,
		// as after clicking it): they're caught at the window and never passed on to beep or leak.
		{
			[NSApplication sharedApplication];
			NSWindow* window = [[NSWindow alloc] initWithContentRect:view.bounds styleMask:NSWindowStyleMaskTitled
															 backing:NSBackingStoreBuffered defer:NO];
			window.releasedWhenClosed = NO;  // ARC owns it
			[window.contentView addSubview:view];
			NSPopUpButton* kitMenu = nil;
			for (NSView* sub in view.subviews) if ([sub isKindOfClass:NSPopUpButton.class]) kitMenu = (NSPopUpButton*)sub;
			[window makeFirstResponder:kitMenu];
			const BOOL menuFocused = window.firstResponder == kitMenu;
			CSKeySpy* windowSpy = [CSKeySpy new];
			window.nextResponder = windowSpy;
			h2.Render(UInt32(kSR * 3));
			mark = h2.L.size();
			auto windowKey = [&](NSEventType type, unsigned short code, NSString* chars, NSEventModifierFlags mods) {
				return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:mods timestamp:0 windowNumber:window.windowNumber
										 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
			};
			[NSApp sendEvent:windowKey(NSEventTypeKeyDown, 18, @"!", NSEventModifierFlagShift)];  // ⇧1: kick
			[NSApp sendEvent:windowKey(NSEventTypeKeyDown, 12, @"q", 0)];                         // stray key
			h2.Render(4410);
			CHECK(menuFocused && Rms(h2.L, mark, mark + 4410) > 0.02 && windowSpy.keys == 0,
				"focus: with the kit menu focused, \u21e71 still plays the kick and stray keys don't leak");
			[view removeFromSuperview];
			[window close];
			h2.Render(UInt32(kSR * 3));
		}

		// Drums on ⇧1..⇧0: ⇧1 is the kick.
		h2.Render(UInt32(kSR * 0.5));
		mark = h2.L.size();
		[view keyDown:key(NSEventTypeKeyDown, 18, @"!", NSEventModifierFlagShift)];
		h2.Render(4410);
		CHECK(Rms(h2.L, mark, mark + 4410) > 0.02, "drum pads: ⇧1 plays the kick (rms %.3f)", Rms(h2.L, mark, mark + 4410));
		h2.Render(UInt32(kSR * 3));

		// Recorder: press Record, play chop 2 from the laptop keys, the snare pad and a MIDI note from
		// "GarageBand", press Stop, and the take comes out as a MIDI file with those notes.
		AudioUnitSetParameter(h2.au, kParam_PlayMode, kAudioUnitScope_Global, 0, 0, 0);
		[view performSelector:NSSelectorFromString(@"toggleRecording:") withObject:nil];
		[view keyDown:key(NSEventTypeKeyDown, 13, @"W", NSEventModifierFlagShift)];  // chop 2 = C#3 (61)
		h2.Render(UInt32(kSR * 0.25));
		[view keyUp:key(NSEventTypeKeyUp, 13, @"w", 0)];
		h2.Render(UInt32(kSR * 0.25));
		[view keyDown:key(NSEventTypeKeyDown, 19, @"@", NSEventModifierFlagShift)];  // ⇧2 = snare (root - 10 = 50)
		h2.Render(UInt32(kSR * 0.25));
		MusicDeviceMIDIEvent(h2.au, 0x90, 64, 90, 0);                                  // chop 5 from MIDI
		h2.Render(UInt32(kSR * 0.25));
		MusicDeviceMIDIEvent(h2.au, 0x80, 64, 0, 0);
		h2.Render(UInt32(kSR * 0.1));
		[view performSelector:NSSelectorFromString(@"toggleRecording:") withObject:nil];
		NSURL* take = [view performSelector:NSSelectorFromString(@"writeTake")];
		NSData* midi = take ? [NSData dataWithContentsOfURL:take] : nil;
		std::vector<int> onNotes;
		double firstGap = -1;
		if (midi.length > 22 && memcmp(midi.bytes, "MThd", 4) == 0) {
			const uint8_t* b = (const uint8_t*)midi.bytes;
			size_t i = 22;  // past the header and the track length
			uint32_t tick = 0, firstTick = 0, secondTick = 0;
			while (i < midi.length) {
				uint32_t delta = 0;
				do { delta = (delta << 7) | (b[i] & 0x7f); } while (b[i++] & 0x80);
				tick += delta;
				if (b[i] == 0xff) { i += 3 + b[i + 2]; continue; }
				if ((b[i] & 0xf0) == 0x90 && b[i + 2] > 0) {
					onNotes.push_back(b[i + 1]);
					if (onNotes.size() == 1) firstTick = tick;
					if (onNotes.size() == 2) secondTick = tick;
				}
				i += 3;
			}
			firstGap = (secondTick - firstTick) / 480.0;  // beats between the first two notes (120 BPM: 0.5 s = 1 beat)
		}
		CHECK((onNotes == std::vector<int>{ 61, 50, 64 }) && std::abs(firstGap - 1.0) < 0.05,
			"recorder: take has chop 2, the snare and the MIDI note (%zu notes), timed right (%.2f beats apart)", onNotes.size(), firstGap);
		if (take) [NSFileManager.defaultManager removeItemAtURL:take error:nil];

		// Loading a song with a long quiet intro: the automatic best-part pick skips the intro.
		NSString* introPath = [[NSString stringWithUTF8String:path] stringByAppendingString:@".intro.wav"];
		WriteTestFile(introPath.UTF8String, 20);
		Host h3;
		CFStringRef ip = (__bridge CFStringRef)introPath;
		AudioUnitSetProperty(h3.au, kProp_LoadFile, kAudioUnitScope_Global, 0, &ip, sizeof(ip));
		ChopSettings cs3{};
		size = sizeof(cs3);
		AudioUnitGetProperty(h3.au, kProp_ChopSettings, kAudioUnitScope_Global, 0, &cs3, &size);
		auto s3 = h3.Slices();
		CHECK(cs3.autoPick == 0 && cs3.regionStart > 19.5 * kSR && !s3.empty() && s3.front() >= cs3.regionStart,
			"new song auto-picks its best part: %.1f-%.1fs (music starts at 20s), %zu slices",
			cs3.regionStart / kSR, cs3.regionEnd / kSR, s3.size());
		// Undo/redo in the editor: Next Idea re-chops (in the background); Undo brings back the exact
		// previous chops, Redo the new ones. Uses a song long enough to have several ideas.
		{
			Host h4;
			CFStringRef longSong = (__bridge CFStringRef)[NSHomeDirectory() stringByAppendingPathComponent:@"Music/Chipmunk Soul/Ponderosa Twins Plus One - Bound.wav"];
			if ([NSFileManager.defaultManager fileExistsAtPath:(__bridge NSString*)longSong]) {
				AudioUnitSetProperty(h4.au, kProp_LoadFile, kAudioUnitScope_Global, 0, &longSong, sizeof(longSong));
				id<AUCocoaUIBase> factory4 = [[[NSBundle bundleWithURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/Components/ArnoldChopper.component"]]]
					classNamed:@"ChipmunkSoulViewFactory_v1"] new];
				NSView* v4 = [factory4 uiViewForAudioUnit:h4.au withSize:NSZeroSize];
				const auto before = h4.Slices();
				[v4 performSelector:NSSelectorFromString(@"nextIdea:") withObject:nil];
				for (int i = 0; i < 60 && h4.Slices() == before; ++i) {
					[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
				}
				[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
				const auto after = h4.Slices();
				[v4 performSelector:NSSelectorFromString(@"undo:") withObject:nil];
				const auto undone = h4.Slices();
				[v4 performSelector:NSSelectorFromString(@"redo:") withObject:nil];
				const auto redone = h4.Slices();
				CHECK(after != before && undone == before && redone == after, "undo/redo: Next Idea, then Undo restores %zu chops, Redo brings back %zu",
					undone.size(), redone.size());
			} else {
				printf("SKIP  undo/redo (Bound.wav not on this Mac)\n");
			}
		}
		// Import: a song from outside Music › Chipmunk Soul is copied in and the copy is loaded.
		// Importing it again reuses the copy instead of making "… 2".
		{
			Host h5;
			NSString* name = [NSString stringWithFormat:@"Import Test %d.wav", getpid()];
			NSString* outside = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
			NSString* folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Music/Chipmunk Soul"];
			NSString* copy = [folder stringByAppendingPathComponent:name];
			[NSFileManager.defaultManager copyItemAtPath:introPath toPath:outside error:nil];
			id<AUCocoaUIBase> factory5 = [[[NSBundle bundleWithURL:[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/Components/ArnoldChopper.component"]]]
				classNamed:@"ChipmunkSoulViewFactory_v1"] new];
			NSView* v5 = [factory5 uiViewForAudioUnit:h5.au withSize:NSZeroSize];
			auto loadedPath = [&] {
				CFDictionaryRef info = nullptr;
				UInt32 sz = sizeof(info);
				AudioUnitGetProperty(h5.au, kProp_Info, kAudioUnitScope_Global, 0, &info, &sz);
				NSString* p = info ? [((__bridge NSDictionary*)info)[(__bridge NSString*)kInfoFilePath] copy] : nil;
				if (info) CFRelease(info);
				return p;
			};
			for (int pass = 0; pass < 2; ++pass) {
				[v5 performSelector:NSSelectorFromString(@"importURLs:") withObject:@[ [NSURL fileURLWithPath:outside] ]];
				for (int i = 0; i < 100 && ![loadedPath() isEqualToString:copy]; ++i) {
					[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
				}
				[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
			}
			NSString* dup = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"Import Test %d 2.wav", getpid()]];
			CHECK([loadedPath() isEqualToString:copy] && [NSFileManager.defaultManager fileExistsAtPath:copy] &&
					  ![NSFileManager.defaultManager fileExistsAtPath:dup] && !h5.Slices().empty(),
				"import: a song from outside is copied into Music/Chipmunk Soul and loaded (%zu chops), once", h5.Slices().size());
			for (NSString* f in @[ outside, copy, dup ]) {
				[NSFileManager.defaultManager removeItemAtPath:f error:nil];
			}
		}
		view = nil;
	}
	printf(gFailures ? "\n%d FAILED\n" : "\nALL PASSED\n", gFailures);
	return gFailures;
}
