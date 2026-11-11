// Chipmunk Soul — an auto-chopping sampler instrument (AUv2, aumu).
//
// Load a record, it gets chopped into slices (by transients, by beats, or evenly), and each slice
// is mapped to a key starting at the root note. Playback is varispeed like a turntable or an
// SP-1200 pitched up, so raising the pitch also speeds it up — the classic chipmunk soul sound.

#include "Analysis.h"
#include "DrumKits.h"
#include "Shared.h"

#include <AudioUnitSDK/AUPlugInDispatch.h>
#include <AudioUnitSDK/MusicDeviceBase.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <mach/mach_time.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace cs {

namespace {

struct Kit {
	std::shared_ptr<const Sample> sample;
	std::vector<uint32_t> starts;
	uint32_t regionStart = 0, regionEnd = 0;
	ChopSettings settings{ kChop_Transients, 16, 0.5f, 0, 0, 0 };
	double bpm = 0;
	int numPicks = 0;  // best-part candidates found for the current slice count
	uint64_t generation = 0;

	uint32_t SliceEnd(size_t i) const { return i + 1 < starts.size() ? starts[i + 1] : regionEnd; }
};

// Single-producer / single-consumer queue of note events.
struct NoteEvent {
	enum Type : uint8_t { kOn, kOff, kAudition, kAuditionOff, kAuditionDrum, kAllOff } type;
	uint8_t note, velocity;
	uint32_t offset;
};

template <typename T, size_t N>
class EventQueue {
public:
	bool Push(const T& e)
	{
		const size_t w = mWrite.load(std::memory_order_relaxed);
		const size_t next = (w + 1) % N;
		if (next == mRead.load(std::memory_order_acquire)) {
			return false;
		}
		mItems[w] = e;
		mWrite.store(next, std::memory_order_release);
		return true;
	}
	bool Pop(T& e)
	{
		const size_t r = mRead.load(std::memory_order_relaxed);
		if (r == mWrite.load(std::memory_order_acquire)) {
			return false;
		}
		e = mItems[r];
		mRead.store((r + 1) % N, std::memory_order_release);
		return true;
	}

private:
	std::array<T, N> mItems{};
	std::atomic<size_t> mRead{ 0 }, mWrite{ 0 };
};

// Zero-delay-feedback state variable filter (Simper / Cytomic).
struct SVF {
	float ic1 = 0, ic2 = 0;
	void Reset() { ic1 = ic2 = 0; }
	// Returns low-pass; high-pass via out param.
	inline float Tick(float x, float g, float k, float& high)
	{
		const float a1 = 1.f / (1.f + g * (g + k)), a2 = g * a1, a3 = g * a2;
		const float v3 = x - ic2;
		const float v1 = a1 * ic1 + a2 * v3;
		const float v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = 2.f * v1 - ic1;
		ic2 = 2.f * v2 - ic2;
		high = x - k * v1 - v2;
		return v2;
	}
};

inline float Hermite(const float* d, int64_t n, double pos)
{
	const int64_t i = int64_t(std::floor(pos));
	const float t = float(pos - double(i));
	auto at = [&](int64_t j) { return d[std::clamp<int64_t>(j, 0, n - 1)]; };
	const float xm1 = at(i - 1), x0 = at(i), x1 = at(i + 1), x2 = at(i + 2);
	const float c1 = 0.5f * (x1 - xm1);
	const float c2 = xm1 - 2.5f * x0 + 2.f * x1 - 0.5f * x2;
	const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
	return ((c3 * t + c2) * t + c1) * t + x0;
}

struct Voice {
	enum Stage { kIdle, kAttack, kSustain, kRelease } stage = kIdle;
	int slice = -1;
	int note = -1;
	double pos = 0;
	uint32_t start = 0, end = 0;
	bool reverse = false;
	bool held = false;  // key still down: play on past the slice end, through the rest of the song
	int group = 0;      // mute group it was started in (0 = none)
	double sinceLoop = 1e9;  // output frames since a looping chop last wrapped around (for the seam fade)
	double chopRatio = 1.0;  // this chop's own pitch tweak, as a speed ratio
	// Beat lock (Sync on, song playing): where the voice was at which song beat, and how many record
	// frames each song beat moves it. Position comes from the song's beat rather than from adding up
	// speed, so tempo changes and re-rendered audio can't make it drift.
	double anchorBeat = NAN, anchorPos = 0, anchorFramesPerBeat = 0;
	// Keep Pitch mode: two overlapping grains read the record at the pitch speed while `pos`
	// moves at the tempo speed.
	double grainStart[2] = { 0, 0 };
	double grainPhase[2] = { 0, 0 };
	float gain = 1.f;
	float env = 0.f;
	float attackInc = 1.f;
	float releaseCoef = 0.f;
	uint64_t age = 0;
};

// One hit of the built-in drum kit, synthesized.
struct DrumVoice {
	int type = -1;  // Drum, or -1 when idle
	double t = 0;   // seconds since the hit
	double phase = 0;
	float gain = 0;
	float fade = 1;
	bool choked = false;
	uint32_t delay = 0;  // frames to wait in the current block
	uint32_t seed = 1;
	SVF filter;
	float Noise()
	{
		seed ^= seed << 13;
		seed ^= seed >> 17;
		seed ^= seed << 5;
		return float(int32_t(seed)) * (1.f / 2147483648.f);
	}
};

struct PendingEvent {
	NoteEvent event;
	int64_t due;  // absolute sample time
};

const CFStringRef kStatePath = CFSTR("chipmunkSoul.path");
const CFStringRef kStateSlices = CFSTR("chipmunkSoul.slices");
const CFStringRef kStateChop = CFSTR("chipmunkSoul.chop");
const CFStringRef kStateBPM = CFSTR("chipmunkSoul.bpm");
const CFStringRef kStateGroups = CFSTR("chipmunkSoul.muteGroups");
const CFStringRef kStateEdits = CFSTR("chipmunkSoul.chopEdits");

}  // namespace

class ChipmunkSoul : public ausdk::MusicDeviceBase {
	using Base = ausdk::MusicDeviceBase;

public:
	explicit ChipmunkSoul(AudioComponentInstance ci) : Base(ci, 0, 1)
	{
		auto& g = *Globals();
		g.UseIndexedParameters(kNumParams);
		g.SetParameter(kParam_Pitch, 4.f);
		g.SetParameter(kParam_RootNote, 60.f);
		g.SetParameter(kParam_Attack, 1.f);
		g.SetParameter(kParam_Release, 60.f);
		g.SetParameter(kParam_PlayMode, 0.f);
		g.SetParameter(kParam_Choke, 0.f);
		g.SetParameter(kParam_Reverse, 0.f);
		g.SetParameter(kParam_LowCut, 20.f);
		g.SetParameter(kParam_HighCut, 20000.f);
		g.SetParameter(kParam_Crunch, 0.f);
		g.SetParameter(kParam_VelocitySens, 70.f);
		g.SetParameter(kParam_Volume, 0.f);
		g.SetParameter(kParam_Sync, 1.f);
		g.SetParameter(kParam_KeepPitch, 0.f);
		g.SetParameter(kParam_Swing, 50.f);
		g.SetParameter(kParam_Vinyl, 0.f);
		g.SetParameter(kParam_DrumVolume, -4.f);
		g.SetParameter(kParam_DrumKit, 0.f);
		g.SetParameter(kParam_EndMode, kEndContinue);
		g.SetParameter(kParam_InstantPlay, 1.f);
		ResetChopEdits();

		mKit.store(new Kit);
		for (auto& slice : mPreviewSlice) {
			slice.store(-1, std::memory_order_relaxed);  // nothing playing on the Instant Play output yet
		}
	}

	~ChipmunkSoul() override
	{
		StopPreview();
		delete mKit.load();
	}

	void Cleanup() override
	{
		StopPreview();
		Base::Cleanup();
	}

	bool StreamFormatWritable(AudioUnitScope, AudioUnitElement) override { return !IsInitialized(); }
	bool CanScheduleParameters() const noexcept override { return false; }
	bool SupportsTail() noexcept override { return true; }
	Float64 GetTailTime() noexcept override { return GetParameterRT(kParam_Release) * 0.001 + 0.05; }

	UInt32 SupportedNumChannels(const AUChannelInfo** outInfo) override
	{
		static const AUChannelInfo kChannels[] = { { 0, 2 } };
		if (outInfo) {
			*outInfo = kChannels;
		}
		return 1;
	}

	OSStatus Initialize() override
	{
		const OSStatus err = Base::Initialize();
		if (err != noErr) {
			return err;
		}
		if (Output(0).GetStreamFormat().mChannelsPerFrame != 2) {
			return kAudioUnitErr_FormatNotSupported;
		}
		mMain.ResetVoices();
		return noErr;
	}

	OSStatus Reset(AudioUnitScope, AudioUnitElement) override
	{
		mMain.ResetVoices();
		return noErr;
	}

	// ------------------------------------------------------------------------------------------
	// Parameters

	OSStatus GetParameterInfo(
		AudioUnitScope scope, AudioUnitParameterID id, AudioUnitParameterInfo& info) override
	{
		if (scope != kAudioUnitScope_Global) {
			return kAudioUnitErr_InvalidScope;
		}
		info.flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable;
		auto set = [&](CFStringRef name, AudioUnitParameterUnit unit, float lo, float hi, float def) {
			FillInParameterName(info, name, false);
			info.unit = unit;
			info.minValue = lo;
			info.maxValue = hi;
			info.defaultValue = def;
		};
		switch (id) {
		case kParam_Pitch:
			set(CFSTR("Pitch"), kAudioUnitParameterUnit_RelativeSemiTones, -12, 24, 4);
			break;
		case kParam_RootNote:
			set(CFSTR("Root Note"), kAudioUnitParameterUnit_MIDINoteNumber, 0, 108, 60);
			break;
		case kParam_Attack:
			set(CFSTR("Attack"), kAudioUnitParameterUnit_Milliseconds, 0, 1000, 1);
			info.flags |= kAudioUnitParameterFlag_DisplaySquareRoot;
			break;
		case kParam_Release:
			set(CFSTR("Release"), kAudioUnitParameterUnit_Milliseconds, 1, 3000, 60);
			info.flags |= kAudioUnitParameterFlag_DisplaySquareRoot;
			break;
		case kParam_PlayMode:
			set(CFSTR("Play Mode"), kAudioUnitParameterUnit_Indexed, 0, 1, 0);
			break;
		case kParam_Choke:
			set(CFSTR("Choke"), kAudioUnitParameterUnit_Boolean, 0, 1, 0);
			break;
		case kParam_Reverse:
			set(CFSTR("Reverse"), kAudioUnitParameterUnit_Boolean, 0, 1, 0);
			break;
		case kParam_LowCut:
			set(CFSTR("Low Cut"), kAudioUnitParameterUnit_Hertz, 20, 2000, 20);
			info.flags |= kAudioUnitParameterFlag_DisplayLogarithmic;
			break;
		case kParam_HighCut:
			set(CFSTR("High Cut"), kAudioUnitParameterUnit_Hertz, 500, 20000, 20000);
			info.flags |= kAudioUnitParameterFlag_DisplayLogarithmic;
			break;
		case kParam_Crunch:
			set(CFSTR("Crunch"), kAudioUnitParameterUnit_Percent, 0, 100, 0);
			break;
		case kParam_VelocitySens:
			set(CFSTR("Velocity"), kAudioUnitParameterUnit_Percent, 0, 100, 70);
			break;
		case kParam_Volume:
			set(CFSTR("Volume"), kAudioUnitParameterUnit_Decibels, -40, 12, 0);
			break;
		case kParam_Sync:
			set(CFSTR("Sync to Song Tempo"), kAudioUnitParameterUnit_Boolean, 0, 1, 1);
			break;
		case kParam_KeepPitch:
			set(CFSTR("Keep Pitch"), kAudioUnitParameterUnit_Boolean, 0, 1, 0);
			break;
		case kParam_Swing:
			set(CFSTR("Swing"), kAudioUnitParameterUnit_Percent, 50, 75, 50);
			break;
		case kParam_Vinyl:
			set(CFSTR("Vinyl"), kAudioUnitParameterUnit_Percent, 0, 100, 0);
			break;
		case kParam_DrumVolume:
			set(CFSTR("Drums"), kAudioUnitParameterUnit_Decibels, -40, 6, -4);
			break;
		case kParam_DrumKit:
			set(CFSTR("Drum Kit"), kAudioUnitParameterUnit_Indexed, 0, kNumDrumKits - 1, 0);
			break;
		case kParam_EndMode:
			set(CFSTR("At Chop End"), kAudioUnitParameterUnit_Indexed, 0, 2, kEndContinue);
			break;
		case kParam_InstantPlay:
			set(CFSTR("Instant Play"), kAudioUnitParameterUnit_Boolean, 0, 1, 1);
			break;
		default:
			return kAudioUnitErr_InvalidParameter;
		}
		return noErr;
	}

	// Play Mode is retired (a key now plays exactly as long as it's held) but keeps its ID so older
	// projects still load; it's just no longer listed.
	OSStatus GetParameterList(AudioUnitScope scope, AudioUnitParameterID* outList, UInt32& outCount) override
	{
		if (scope != kAudioUnitScope_Global) {
			return Base::GetParameterList(scope, outList, outCount);
		}
		outCount = 0;
		for (AudioUnitParameterID id = 0; id < kNumParams; ++id) {
			if (id != kParam_PlayMode) {
				if (outList) {
					outList[outCount] = id;
				}
				++outCount;
			}
		}
		return noErr;
	}

	OSStatus GetParameterValueStrings(
		AudioUnitScope scope, AudioUnitParameterID id, CFArrayRef* outStrings) override
	{
		if (scope == kAudioUnitScope_Global && id == kParam_DrumKit) {
			if (outStrings) {
				CFStringRef names[kNumDrumKits];
				for (int k = 0; k < kNumDrumKits; ++k) {
					names[k] = CFStringCreateWithCString(nullptr, kDrumKitNames[k], kCFStringEncodingUTF8);
				}
				*outStrings = CFArrayCreate(nullptr, reinterpret_cast<const void**>(names), kNumDrumKits, &kCFTypeArrayCallBacks);
				for (auto n : names) {
					CFRelease(n);
				}
			}
			return noErr;
		}
		if (scope == kAudioUnitScope_Global && id == kParam_EndMode) {
			if (outStrings) {
				CFStringRef names[] = { CFSTR("Continue"), CFSTR("Stop at End"), CFSTR("Loop") };
				*outStrings = CFArrayCreate(nullptr, reinterpret_cast<const void**>(names), 3, nullptr);
			}
			return noErr;
		}
		if (scope != kAudioUnitScope_Global || id != kParam_PlayMode) {
			return kAudioUnitErr_InvalidProperty;
		}
		if (outStrings) {
			CFStringRef names[] = { CFSTR("One-Shot"), CFSTR("Gate") };
			*outStrings = CFArrayCreate(nullptr, reinterpret_cast<const void**>(names), 2, nullptr);
		}
		return noErr;
	}

	// ------------------------------------------------------------------------------------------
	// Properties

	OSStatus GetPropertyInfo(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
		UInt32& outSize, bool& outWritable) override
	{
		if (id == kAudioUnitProperty_CocoaUI || id >= kProp_LoadFile) {
			if (scope != kAudioUnitScope_Global) {
				return kAudioUnitErr_InvalidScope;
			}
			switch (id) {
			case kAudioUnitProperty_CocoaUI:
				outSize = sizeof(AudioUnitCocoaViewInfo);
				outWritable = false;
				return noErr;
			case kProp_LoadFile:
				outSize = sizeof(CFStringRef);
				outWritable = true;
				return noErr;
			case kProp_Overview:
			case kProp_Info:
				outSize = sizeof(CFTypeRef);
				outWritable = false;
				return noErr;
			case kProp_Slices:
				outSize = sizeof(CFDataRef);
				outWritable = true;
				return noErr;
			case kProp_ChopSettings:
				outSize = sizeof(ChopSettings);
				outWritable = true;
				return noErr;
			case kProp_Playheads:
				outSize = sizeof(Playheads);
				outWritable = false;
				return noErr;
			case kProp_MuteGroups:
			case kProp_ChopEdits:
				outSize = sizeof(CFDataRef);
				outWritable = true;
				return noErr;
			case kProp_ExportChop:
			case kProp_EditorOpen:
				outSize = sizeof(int32_t);
				outWritable = true;
				return noErr;
			case kProp_ExportPath:
				outSize = sizeof(CFStringRef);
				outWritable = false;
				return noErr;
			case kProp_Recorded:
				outSize = sizeof(CFDataRef);
				outWritable = false;
				return noErr;
			case kProp_Audition:
				outSize = sizeof(int32_t);
				outWritable = true;
				return noErr;
			default:
				break;
			}
		}
		return Base::GetPropertyInfo(id, scope, element, outSize, outWritable);
	}

	OSStatus GetProperty(
		AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element, void* outData) override
	{
		if (scope == kAudioUnitScope_Global) {
			switch (id) {
			case kAudioUnitProperty_CocoaUI: {
				CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(CS_BUNDLE_ID));
				if (!bundle) {
					return kAudioUnitErr_InvalidProperty;
				}
				auto* info = static_cast<AudioUnitCocoaViewInfo*>(outData);
				info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(bundle);
				info->mCocoaAUViewClass[0] = CFStringCreateCopy(nullptr, CFSTR("ChipmunkSoulViewFactory_v1"));
				return noErr;
			}
			case kProp_Overview: {
				std::lock_guard lock(mKitMutex);
				*static_cast<CFDataRef*>(outData) = CopyOverview(*mKit.load());
				return noErr;
			}
			case kProp_Slices: {
				std::lock_guard lock(mKitMutex);
				*static_cast<CFDataRef*>(outData) = CopySlices(*mKit.load());
				return noErr;
			}
			case kProp_ChopSettings: {
				std::lock_guard lock(mKitMutex);
				*static_cast<ChopSettings*>(outData) = mKit.load()->settings;
				return noErr;
			}
			case kProp_Info:
				*static_cast<CFDictionaryRef*>(outData) = CopyInfo();
				return noErr;
			case kProp_MuteGroups:
				*static_cast<CFDataRef*>(outData) = CopyGroups();
				return noErr;
			case kProp_ChopEdits:
				*static_cast<CFDataRef*>(outData) = CopyChopEdits();
				return noErr;
			case kProp_Recorded: {
				CFMutableDataRef data = CFDataCreateMutable(nullptr, 0);
				RecordedNote n;
				while (mRecorded.Pop(n)) {
					CFDataAppendBytes(data, reinterpret_cast<const UInt8*>(&n), sizeof(n));
				}
				*static_cast<CFDataRef*>(outData) = data;
				return noErr;
			}
			case kProp_ExportPath: {
				std::lock_guard lock(mKitMutex);
				*static_cast<CFStringRef*>(outData) = CFStringCreateWithCString(nullptr, mExportPath.c_str(), kCFStringEncodingUTF8);
				return noErr;
			}
			case kProp_Playheads:
				FillPlayheads(*static_cast<Playheads*>(outData));
				return noErr;
			default:
				break;
			}
		}
		return Base::GetProperty(id, scope, element, outData);
	}

	OSStatus SetProperty(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement element,
		const void* data, UInt32 size) override
	{
		if (id >= kProp_LoadFile && scope == kAudioUnitScope_Global) {
			switch (id) {
			case kProp_LoadFile: {
				if (size != sizeof(CFStringRef)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				CFStringRef path = *static_cast<const CFStringRef*>(data);
				if (!path || CFGetTypeID(path) != CFStringGetTypeID()) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				ChopSettings settings;
				{
					std::lock_guard lock(mKitMutex);
					settings = mKit.load()->settings;
				}
				settings.regionStart = settings.regionEnd = 0;
				settings.autoPick = 0;  // a new song starts on its best part
				for (auto& g : mGroups) {
					g.store(0, std::memory_order_relaxed);
				}
				ResetChopEdits();
				LoadFile(ToStd(path), settings, nullptr);
				return noErr;
			}
			case kProp_Slices: {
				if (size != sizeof(CFDataRef)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				return SetSlices(*static_cast<const CFDataRef*>(data)) ? OSStatus(noErr)
																		: OSStatus(kAudioUnitErr_InvalidPropertyValue);
			}
			case kProp_ChopSettings: {
				if (size != sizeof(ChopSettings)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				Rechop(*static_cast<const ChopSettings*>(data));
				return noErr;
			}
			case kProp_MuteGroups:
				if (size != sizeof(CFDataRef) || !SetGroups(*static_cast<const CFDataRef*>(data))) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				PropertyChanged(kProp_MuteGroups, kAudioUnitScope_Global, 0);
				return noErr;
			case kProp_ChopEdits:
				if (size != sizeof(CFDataRef) || !SetChopEdits(*static_cast<const CFDataRef*>(data))) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				PropertyChanged(kProp_ChopEdits, kAudioUnitScope_Global, 0);
				return noErr;
			case kProp_EditorOpen:
				if (size != sizeof(int32_t)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				mEditorOpen = *static_cast<const int32_t*>(data) != 0;
				if (!mEditorOpen) {
					StopPreview();
				}
				return noErr;
			case kProp_ExportChop:
				if (size != sizeof(int32_t)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				return ExportChop(*static_cast<const int32_t*>(data)) ? OSStatus(noErr) : OSStatus(kAudioUnitErr_CannotDoInCurrentContext);
			case kProp_Audition: {
				if (size != sizeof(int32_t)) {
					return kAudioUnitErr_InvalidPropertyValue;
				}
				const int32_t value = *static_cast<const int32_t*>(data);
				// Instant Play: the editor's notes go to their own output, unless it's switched off or
				// the output can't be opened (then GarageBand plays them as usual).
				if (GetParameterRT(kParam_InstantPlay) >= 0.5f && mEditorOpen) {
					StartPreview();
				} else {
					StopPreview();
				}
				if (value == -1) {
					mUIQueue.Push({ NoteEvent::kAllOff, 0, 0, 0 });
				} else if (value >= kAuditionDrum) {
					mUIQueue.Push({ NoteEvent::kAuditionDrum, uint8_t(std::min(value - kAuditionDrum, 127)), 100, 0 });
				} else if (value >= 0) {
					mUIQueue.Push({ NoteEvent::kAudition, uint8_t(std::min(value, 127)), 100, 0 });
				} else {
					mUIQueue.Push({ NoteEvent::kAuditionOff, uint8_t(std::min(-2 - value, 127)), 0, 0 });
				}
				return noErr;
			}
			default:
				break;
			}
		}
		return Base::SetProperty(id, scope, element, data, size);
	}

	// ------------------------------------------------------------------------------------------
	// State (saved in the GarageBand project and in .aupreset files)

	OSStatus SaveState(CFPropertyListRef* outData) override
	{
		const OSStatus err = Base::SaveState(outData);
		if (err != noErr) {
			return err;
		}
		auto* dict = static_cast<CFMutableDictionaryRef>(const_cast<void*>(*outData));
		std::lock_guard lock(mKitMutex);
		const Kit& kit = *mKit.load();
		const std::string path = kit.sample ? kit.sample->path : mMissingPath;
		if (!path.empty()) {
			CFStringRef p = CFStringCreateWithCString(nullptr, path.c_str(), kCFStringEncodingUTF8);
			CFDictionarySetValue(dict, kStatePath, p);
			CFRelease(p);
		}
		CFDataRef slices = CopySlices(kit);
		CFDictionarySetValue(dict, kStateSlices, slices);
		CFRelease(slices);
		CFDataRef chop = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&kit.settings), sizeof(ChopSettings));
		CFDictionarySetValue(dict, kStateChop, chop);
		CFRelease(chop);
		CFNumberRef bpm = CFNumberCreate(nullptr, kCFNumberDoubleType, &kit.bpm);
		CFDictionarySetValue(dict, kStateBPM, bpm);
		CFRelease(bpm);
		CFDataRef groups = CopyGroups();
		CFDictionarySetValue(dict, kStateGroups, groups);
		CFRelease(groups);
		CFDataRef edits = CopyChopEdits();
		CFDictionarySetValue(dict, kStateEdits, edits);
		CFRelease(edits);
		return noErr;
	}

	OSStatus RestoreState(CFPropertyListRef plist) override
	{
		const OSStatus err = Base::RestoreState(plist);
		if (err != noErr) {
			return err;
		}
		auto dict = static_cast<CFDictionaryRef>(plist);
		auto path = static_cast<CFStringRef>(CFDictionaryGetValue(dict, kStatePath));
		auto chop = static_cast<CFDataRef>(CFDictionaryGetValue(dict, kStateChop));
		auto slices = static_cast<CFDataRef>(CFDictionaryGetValue(dict, kStateSlices));
		auto bpm = static_cast<CFNumberRef>(CFDictionaryGetValue(dict, kStateBPM));
		auto groups = static_cast<CFDataRef>(CFDictionaryGetValue(dict, kStateGroups));
		for (auto& g : mGroups) {
			g.store(0, std::memory_order_relaxed);
		}
		SetGroups(groups);
		ResetChopEdits();
		SetChopEdits(static_cast<CFDataRef>(CFDictionaryGetValue(dict, kStateEdits)));

		ChopSettings settings{ kChop_Transients, 16, 0.5f, 0, 0, 0 };
		if (chop && CFGetTypeID(chop) == CFDataGetTypeID()) {
			// Projects saved before best-part search have no autoPick field: keep their region.
			constexpr CFIndex kV1Size = offsetof(ChopSettings, autoPick);
			const CFIndex len = CFDataGetLength(chop);
			if (len == sizeof(ChopSettings)) {
				memcpy(&settings, CFDataGetBytePtr(chop), sizeof(ChopSettings));
			} else if (len == kV1Size) {
				memcpy(&settings, CFDataGetBytePtr(chop), size_t(kV1Size));
				settings.autoPick = -1;
			}
		}
		if (path && CFGetTypeID(path) == CFStringGetTypeID()) {
			if (LoadFile(ToStd(path), settings, slices) && bpm && CFGetTypeID(bpm) == CFNumberGetTypeID()) {
				std::lock_guard lock(mKitMutex);
				CFNumberGetValue(bpm, kCFNumberDoubleType, &mKit.load()->bpm);
			}
		} else {
			auto* kit = new Kit;
			kit->settings = settings;
			Publish(kit, "");
		}
		Notify();
		return noErr;
	}

	// ------------------------------------------------------------------------------------------
	// MIDI

	OSStatus HandleNoteOn(UInt8, UInt8 note, UInt8 velocity, UInt32 offset) noexcept override
	{
		mMIDIQueue.Push({ velocity ? NoteEvent::kOn : NoteEvent::kOff, note, velocity, offset });
		return noErr;
	}

	OSStatus HandleNoteOff(UInt8, UInt8 note, UInt8, UInt32 offset) noexcept override
	{
		mMIDIQueue.Push({ NoteEvent::kOff, note, 0, offset });
		return noErr;
	}

	OSStatus HandleAllNotesOff(UInt8) noexcept override
	{
		mMIDIQueue.Push({ NoteEvent::kAllOff, 0, 0, 0 });
		return noErr;
	}

	OSStatus HandleAllSoundOff(UInt8 channel) noexcept override { return HandleAllNotesOff(channel); }

	// ------------------------------------------------------------------------------------------
	// Render

	OSStatus Render(AudioUnitRenderActionFlags& flags, const AudioTimeStamp& inTimeStamp, UInt32 frames) noexcept override
	{
		mRenderEpoch.fetch_add(1);
		const Kit* kit = mKit.load();

		AudioBufferList& abl = Output(0).GetBufferList();
		float* outL = static_cast<float*>(abl.mBuffers[0].mData);
		float* outR = static_cast<float*>(abl.mBuffers[abl.mNumberBuffers > 1 ? 1 : 0].mData);
		std::fill(outL, outL + frames, 0.f);
		std::fill(outR, outR + frames, 0.f);

		Float64 tempo = 0, beat = 0;
		if (CallHostBeatAndTempo(&beat, &tempo) == noErr && tempo > 0) {
			mHostTempo.store(tempo, std::memory_order_relaxed);
		} else {
			tempo = 0;
		}
		Boolean playing = false;
		CallHostTransportState(&playing, nullptr, nullptr, nullptr, nullptr, nullptr);
		const double seconds = HostSeconds(inTimeStamp, mMainClock / GetOutputSampleRate());
		mMain.Prepare(*kit, tempo, beat, playing, seconds);
		mPlayingPitch.store(mMain.mPitch, std::memory_order_relaxed);
		mPlayingRatio.store(float(mMain.mTimeRatio), std::memory_order_relaxed);
		mLastBeat.store(beat, std::memory_order_relaxed);
		mLastTempo.store(mMain.mBlockTempo, std::memory_order_relaxed);
		mLastPlaying.store(mMain.mBlockPlaying, std::memory_order_relaxed);
		mLastSeconds.store(seconds, std::memory_order_relaxed);

		const double sr = GetOutputSampleRate();
		const int64_t blockEnd = mMainClock + frames;

		// Gather events for this block. With Swing up and the song playing, MIDI notes on off-beat
		// 16ths are pushed back (MPC style); their note-offs move with them.
		auto& events = mMain.mEvents;
		size_t numEvents = 0;
		const float swing = GetParameterRT(kParam_Swing) * 0.01f;
		const bool swingOn = playing && swing > 0.505f && tempo > 0;
		const double swingDelay = (swing - 0.5) * 0.5 * 60.0 / std::max(1.0, double(tempo)) * sr;
		NoteEvent e;
		while (mMIDIQueue.Pop(e)) {
			e.offset = std::min(e.offset, frames - 1);
			int64_t delay = 0;
			if (e.type == NoteEvent::kOn) {
				if (swingOn) {
					const double pos16 = (beat + e.offset / sr * tempo / 60.0) * 4.0;
					const double nearest = std::round(pos16);
					if (int64_t(nearest) % 2 != 0 && std::abs(pos16 - nearest) < 0.2) {
						delay = int64_t(swingDelay);
					}
				}
				mNoteDelay[e.note] = delay;
			} else if (e.type == NoteEvent::kOff) {
				delay = mNoteDelay[e.note];
			}
			if (delay > 0 && mNumPending < mPending.size()) {
				mPending[mNumPending++] = { e, mMainClock + e.offset + delay };
			} else if (numEvents < events.size()) {
				events[numEvents++] = e;
			}
		}
		for (size_t k = 0; k < mNumPending;) {
			if (mPending[k].due < blockEnd && numEvents < events.size()) {
				NoteEvent due = mPending[k].event;
				due.offset = uint32_t(std::max<int64_t>(0, mPending[k].due - mMainClock));
				events[numEvents++] = due;
				mPending[k] = mPending[--mNumPending];
			} else {
				++k;
			}
		}
		// The editor's notes play here unless Instant Play is sending them to the speakers directly.
		while (!mPreviewOn.load(std::memory_order_acquire) && numEvents < events.size() && mUIQueue.Pop(e)) {
			e.offset = 0;
			events[numEvents++] = e;
		}
		std::stable_sort(events.begin(), events.begin() + numEvents,
			[](const NoteEvent& a, const NoteEvent& b) { return a.offset < b.offset; });

		const bool sounding = mMain.Process(*kit, events.data(), numEvents, outL, outR, frames, sr);
		mMain.Publish(mPlayFrame, mPlaySlice, mPlayLevel);
		mMainClock = blockEnd;
		if (!sounding) {
			flags |= kAudioUnitRenderAction_OutputIsSilence;
		}
		mRenderEpoch.fetch_add(1);
		return noErr;
	}

private:
	// ------------------------------------------------------------------------------------------
	// Voices

	double GetOutputSampleRate() { return Output(0).GetStreamFormat().mSampleRate; }

	void FillPlayheads(Playheads& p) const
	{
		p.count = kMaxVoices;
		for (int i = 0; i < kMaxVoices; ++i) {
			p.frames[i] = mPlayFrame[size_t(i)].load(std::memory_order_relaxed);
			p.slices[i] = mPlaySlice[size_t(i)].load(std::memory_order_relaxed);
			p.levels[i] = mPlayLevel[size_t(i)].load(std::memory_order_relaxed);
		}
		// Voices playing on the Instant Play output fill in the free slots.
		int free = 0;
		for (int i = 0; i < kMaxVoices; ++i) {
			const int32_t slice = mPreviewSlice[size_t(i)].load(std::memory_order_relaxed);
			if (slice < 0) {
				continue;
			}
			while (free < kMaxVoices && p.slices[free] >= 0) {
				++free;
			}
			if (free == kMaxVoices) {
				break;
			}
			p.frames[free] = mPreviewFrame[size_t(i)].load(std::memory_order_relaxed);
			p.slices[free] = slice;
			p.levels[free] = mPreviewLevel[size_t(i)].load(std::memory_order_relaxed);
		}
	}

	// ------------------------------------------------------------------------------------------
	// Kit management (non-realtime)

	static std::string ToStd(CFStringRef s)
	{
		char buf[4096];
		if (CFStringGetFileSystemRepresentation(s, buf, sizeof(buf))) {
			return buf;
		}
		return {};
	}

	// Swaps in a new kit and frees the old one once the render thread can no longer see it.
	void Publish(Kit* kit, const std::string& status)
	{
		{
			std::lock_guard lock(mKitMutex);
			kit->generation = ++mGenerationCounter;
			Kit* old = mKit.exchange(kit);
			// Both players (GarageBand's render and Instant Play) must be done with the old kit.
			bool safe = true;
			for (auto* counter : { &mRenderEpoch, &mPreviewEpoch }) {
				const uint64_t epoch = counter->load();
				if (epoch & 1) {
					for (int i = 0; i < 2000 && counter->load() == epoch; ++i) {
						std::this_thread::sleep_for(std::chrono::microseconds(100));
					}
					safe = safe && counter->load() != epoch;
				}
			}
			if (safe) {
				delete old;
			}  // else: a render is stuck for >200 ms; leaking one kit beats crashing.
			mStatus = status;
		}
	}

	void Notify()
	{
		PropertyChanged(kProp_Overview, kAudioUnitScope_Global, 0);
		PropertyChanged(kProp_Slices, kAudioUnitScope_Global, 0);
		PropertyChanged(kProp_ChopSettings, kAudioUnitScope_Global, 0);
		PropertyChanged(kProp_Info, kAudioUnitScope_Global, 0);
		PropertyChanged(kProp_MuteGroups, kAudioUnitScope_Global, 0);
		PropertyChanged(kProp_ChopEdits, kAudioUnitScope_Global, 0);
	}

	bool LoadFile(const std::string& path, const ChopSettings& settings, CFDataRef savedSlices)
	{
		std::string error;
		Sample* sample = LoadSample(path, error);
		if (!sample) {
			auto* kit = new Kit;
			kit->settings = settings;
			mMissingPath = path;
			const auto slash = path.find_last_of('/');
			Publish(kit, error + ": " + (slash == std::string::npos ? path : path.substr(slash + 1)));
			Notify();
			return false;
		}
		mMissingPath.clear();

		auto* kit = new Kit;
		kit->sample.reset(sample);
		kit->settings = settings;
		if (!(savedSlices && ApplySlices(*kit, savedSlices))) {
			ChopInto(*kit, settings);
		}
		Publish(kit, "");
		Notify();
		return true;
	}

	void ChopInto(Kit& kit, ChopSettings settings)
	{
		kit.numPicks = 0;
		if (settings.autoPick >= 0) {
			// Search the whole song for its most chop-worthy stretch (one beat per slice, 4..32 beats).
			const auto picks = FindBestSections(*kit.sample, std::clamp(settings.count, 4, 32), 8);
			if (!picks.empty()) {
				settings.autoPick %= int(picks.size());
				settings.regionStart = picks[size_t(settings.autoPick)].start;
				settings.regionEnd = picks[size_t(settings.autoPick)].end;
				kit.numPicks = int(picks.size());
			}
		}
		kit.settings = settings;
		kit.starts = Chop(*kit.sample, settings, &kit.bpm);
		kit.regionStart = std::min(settings.regionStart, kit.sample->frames - 1);
		kit.regionEnd = settings.regionEnd == 0 || settings.regionEnd > kit.sample->frames ? kit.sample->frames
																							: settings.regionEnd;
	}

	static bool ApplySlices(Kit& kit, CFDataRef data)
	{
		if (!data || CFGetTypeID(data) != CFDataGetTypeID() || !kit.sample) {
			return false;
		}
		const auto len = size_t(CFDataGetLength(data));
		if (len < sizeof(SliceHeader)) {
			return false;
		}
		SliceHeader h;
		memcpy(&h, CFDataGetBytePtr(data), sizeof(h));
		if (h.count == 0 || h.count > uint32_t(kMaxSlices) || len != sizeof(h) + h.count * sizeof(uint32_t)) {
			return false;
		}
		std::vector<uint32_t> starts(h.count);
		memcpy(starts.data(), CFDataGetBytePtr(data) + sizeof(h), h.count * sizeof(uint32_t));
		std::sort(starts.begin(), starts.end());
		const uint32_t frames = kit.sample->frames;
		const uint32_t regionEnd = std::clamp<uint32_t>(h.regionEnd, 1, frames);
		if (starts.back() >= regionEnd) {
			return false;
		}
		kit.starts = std::move(starts);
		kit.regionStart = std::min(h.regionStart, kit.starts.front());
		kit.regionEnd = regionEnd;
		return true;
	}

	void ResetChopEdits()
	{
		for (int i = 0; i < kMaxSlices; ++i) {
			mChopPitch[size_t(i)].store(0.f, std::memory_order_relaxed);
			mChopGainDb[size_t(i)].store(0.f, std::memory_order_relaxed);
			mChopReverse[size_t(i)].store(false, std::memory_order_relaxed);
		}
	}

	CFDataRef CopyChopEdits() const
	{
		ChopEdit edits[kMaxSlices];
		for (int i = 0; i < kMaxSlices; ++i) {
			edits[i] = { mChopPitch[size_t(i)].load(std::memory_order_relaxed), mChopGainDb[size_t(i)].load(std::memory_order_relaxed),
				mChopReverse[size_t(i)].load(std::memory_order_relaxed) ? 1 : 0 };
		}
		return CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(edits), sizeof(edits));
	}

	bool SetChopEdits(CFDataRef data)
	{
		if (!data || CFGetTypeID(data) != CFDataGetTypeID() || CFDataGetLength(data) != CFIndex(sizeof(ChopEdit) * kMaxSlices)) {
			return false;
		}
		ChopEdit edits[kMaxSlices];
		memcpy(edits, CFDataGetBytePtr(data), sizeof(edits));
		for (int i = 0; i < kMaxSlices; ++i) {
			mChopPitch[size_t(i)].store(std::clamp(edits[i].pitch, -24.f, 24.f), std::memory_order_relaxed);
			mChopGainDb[size_t(i)].store(std::clamp(edits[i].gainDb, -40.f, 12.f), std::memory_order_relaxed);
			mChopReverse[size_t(i)].store(edits[i].reverse != 0, std::memory_order_relaxed);
		}
		return true;
	}

	// Writes the chop as it sounds (pitch, per-chop tweaks, reverse) to a 24-bit WAV in
	// ~/Music/Chipmunk Soul/Chops so it can be dragged onto a GarageBand track.
	bool ExportChop(int slice)
	{
		std::shared_ptr<const Sample> sample;
		uint32_t start = 0, end = 0;
		{
			std::lock_guard lock(mKitMutex);
			const Kit& kit = *mKit.load();
			if (!kit.sample || slice < 0 || slice >= int(kit.starts.size())) {
				return false;
			}
			sample = kit.sample;
			start = kit.starts[size_t(slice)];
			end = kit.SliceEnd(size_t(slice));
		}
		const double outRate = 44100.0;
		const double pitch = mPlayingPitch.load(std::memory_order_relaxed) + mChopPitch[size_t(slice)].load(std::memory_order_relaxed);
		const double speed = sample->sampleRate / outRate * std::exp2(pitch / 12.0);
		const bool reverse = (GetParameterRT(kParam_Reverse) >= 0.5f) != mChopReverse[size_t(slice)].load(std::memory_order_relaxed);
		const float gain = std::pow(10.f, (mChopGainDb[size_t(slice)].load(std::memory_order_relaxed) + GetParameterRT(kParam_Volume)) / 20.f);
		const size_t frames = size_t(double(end - start) / speed);
		if (frames < 16) {
			return false;
		}
		std::vector<float> interleaved(frames * 2);
		const size_t fade = std::min<size_t>(frames / 4, size_t(0.003 * outRate));
		for (size_t i = 0; i < frames; ++i) {
			const double pos = reverse ? double(end) - 1 - i * speed : double(start) + i * speed;
			const float env = gain * float(std::min({ 1.0, double(i) / double(fade), double(frames - 1 - i) / double(fade) }));
			interleaved[2 * i] = env * Hermite(sample->left.data(), sample->frames, pos);
			interleaved[2 * i + 1] = env * Hermite(sample->right.data(), sample->frames, pos);
		}

		const passwd* user = getpwuid(getuid());  // the real home folder, even inside a sandboxed host
		const std::string base = user && user->pw_dir ? user->pw_dir : (getenv("HOME") ? getenv("HOME") : "");
		const std::string folder = base + "/Music/Chipmunk Soul/Chops";
		std::string name = sample->name;
		if (const auto dot = name.find_last_of('.'); dot != std::string::npos) {
			name = name.substr(0, dot);
		}
		const std::string path = folder + "/" + name + " - chop " + std::to_string(slice + 1) + ".wav";
		CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(path.c_str()), CFIndex(path.size()), false);
		mkdir((base + "/Music/Chipmunk Soul").c_str(), 0755);
		mkdir(folder.c_str(), 0755);

		AudioStreamBasicDescription fileFormat{ outRate, kAudioFormatLinearPCM,
			AudioFormatFlags(kAudioFormatFlagIsSignedInteger) | kAudioFormatFlagIsPacked, 6, 1, 6, 2, 24, 0 };
		AudioStreamBasicDescription client{ outRate, kAudioFormatLinearPCM,
			AudioFormatFlags(kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked, 8, 1, 8, 2, 32, 0 };
		ExtAudioFileRef file = nullptr;
		OSStatus err = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, nullptr, kAudioFileFlags_EraseFile, &file);
		CFRelease(url);
		if (err != noErr) {
			return false;
		}
		ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
		AudioBufferList abl{ 1, { { 2, UInt32(interleaved.size() * sizeof(float)), interleaved.data() } } };
		err = ExtAudioFileWrite(file, UInt32(frames), &abl);
		ExtAudioFileDispose(file);
		if (err != noErr) {
			return false;
		}
		std::lock_guard lock(mKitMutex);
		mExportPath = path;
		return true;
	}

	CFDataRef CopyGroups() const
	{
		uint8_t bytes[kMaxSlices];
		for (int i = 0; i < kMaxSlices; ++i) {
			bytes[i] = mGroups[size_t(i)].load(std::memory_order_relaxed);
		}
		return CFDataCreate(nullptr, bytes, kMaxSlices);
	}

	bool SetGroups(CFDataRef data)
	{
		if (!data || CFGetTypeID(data) != CFDataGetTypeID() || CFDataGetLength(data) != kMaxSlices) {
			return false;
		}
		const UInt8* bytes = CFDataGetBytePtr(data);
		for (int i = 0; i < kMaxSlices; ++i) {
			mGroups[size_t(i)].store(std::min<uint8_t>(bytes[i], kMuteGroups), std::memory_order_relaxed);
		}
		return true;
	}

	bool SetSlices(CFDataRef data)
	{
		Kit* kit;
		{
			std::lock_guard lock(mKitMutex);
			kit = new Kit(*mKit.load());
		}
		if (!ApplySlices(*kit, data)) {
			delete kit;
			return false;
		}
		Publish(kit, "");
		PropertyChanged(kProp_Slices, kAudioUnitScope_Global, 0);
		return true;
	}

	void Rechop(const ChopSettings& settings)
	{
		Kit* kit;
		{
			std::lock_guard lock(mKitMutex);
			kit = new Kit(*mKit.load());
		}
		kit->settings = settings;
		kit->settings.count = std::clamp(settings.count, 1, kMaxSlices);
		kit->settings.sensitivity = std::clamp(settings.sensitivity, 0.f, 1.f);
		std::string status;
		if (kit->sample) {
			ChopInto(*kit, kit->settings);
			if (int(kit->starts.size()) < kit->settings.count) {
				status = "Found " + std::to_string(kit->starts.size()) +
						 " hits here. Raise Sensitivity or drag a wider section for more";
			}
		}
		Publish(kit, status);
		Notify();
	}

	CFDataRef CopyOverview(const Kit& kit) const
	{
		CFMutableDataRef data = CFDataCreateMutable(nullptr, 0);
		OverviewHeader h{ 0, 0, 0 };
		if (kit.sample) {
			h = { uint32_t(kit.sample->overview.size() / 2), kit.sample->frames, kit.sample->sampleRate };
		}
		CFDataAppendBytes(data, reinterpret_cast<const UInt8*>(&h), sizeof(h));
		if (kit.sample) {
			CFDataAppendBytes(data, reinterpret_cast<const UInt8*>(kit.sample->overview.data()),
				CFIndex(kit.sample->overview.size() * sizeof(float)));
		}
		return data;
	}

	static CFDataRef CopySlices(const Kit& kit)
	{
		CFMutableDataRef data = CFDataCreateMutable(nullptr, 0);
		const SliceHeader h{ kit.regionStart, kit.regionEnd, uint32_t(kit.starts.size()) };
		CFDataAppendBytes(data, reinterpret_cast<const UInt8*>(&h), sizeof(h));
		CFDataAppendBytes(data, reinterpret_cast<const UInt8*>(kit.starts.data()),
			CFIndex(kit.starts.size() * sizeof(uint32_t)));
		return data;
	}

	CFDictionaryRef CopyInfo()
	{
		std::lock_guard lock(mKitMutex);
		const Kit& kit = *mKit.load();
		CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
			nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		auto putString = [&](CFStringRef key, const std::string& value) {
			CFStringRef s = CFStringCreateWithCString(nullptr, value.c_str(), kCFStringEncodingUTF8);
			if (s) {
				CFDictionarySetValue(dict, key, s);
				CFRelease(s);
			}
		};
		auto putNumber = [&](CFStringRef key, double value) {
			CFNumberRef n = CFNumberCreate(nullptr, kCFNumberDoubleType, &value);
			CFDictionarySetValue(dict, key, n);
			CFRelease(n);
		};
		putString(kInfoFileName, kit.sample ? kit.sample->name : "");
		putString(kInfoFilePath, kit.sample ? kit.sample->path : mMissingPath);
		putString(kInfoStatus, mStatus);
		putNumber(kInfoSampleBPM, kit.bpm);
		putNumber(kInfoHostBPM, mHostTempo.load(std::memory_order_relaxed));
		putNumber(kInfoPitch, mPlayingPitch.load(std::memory_order_relaxed));
		putNumber(kInfoPicks, kit.numPicks);
		putNumber(kInfoTempoRatio, mPlayingRatio.load(std::memory_order_relaxed));
		return dict;
	}

	// ------------------------------------------------------------------------------------------
	// Instant Play output (editor notes straight to the speakers)

	bool StartPreview()
	{
		if (mPreviewOn.load()) {
			return true;
		}
		AudioComponentDescription desc{ kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0 };
		AudioComponent component = AudioComponentFindNext(nullptr, &desc);
		AudioUnit unit = nullptr;
		if (!component || AudioComponentInstanceNew(component, &unit) != noErr) {
			return false;
		}
		AudioStreamBasicDescription device{};
		UInt32 size = sizeof(device);
		AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &device, &size);
		mPreviewRate = device.mSampleRate > 0 ? device.mSampleRate : 48000.0;
		AudioStreamBasicDescription format{ mPreviewRate, kAudioFormatLinearPCM,
			AudioFormatFlags(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0 };
		UInt32 maxFrames = 4096;
		AURenderCallbackStruct callback{ &ChipmunkSoul::PreviewCallback, this };
		if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format)) != noErr ||
			AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames)) != noErr ||
			AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr ||
			AudioUnitInitialize(unit) != noErr) {
			AudioComponentInstanceDispose(unit);
			return false;
		}
		mPreview.ResetVoices();
		// Hand the editor's note queue over: make sure GarageBand's render isn't reading it right now.
		mPreviewOn.store(true);
		const uint64_t epoch = mRenderEpoch.load();
		for (int i = 0; (epoch & 1) && i < 2000 && mRenderEpoch.load() == epoch; ++i) {
			std::this_thread::sleep_for(std::chrono::microseconds(100));
		}
		mPreviewOut = unit;
		if (AudioOutputUnitStart(unit) != noErr) {
			StopPreview();
			return false;
		}
		return true;
	}

	void StopPreview()
	{
		if (!mPreviewOut) {
			mPreviewOn.store(false);
			return;
		}
		AudioOutputUnitStop(mPreviewOut);  // waits for the output's render thread to finish
		AudioUnitUninitialize(mPreviewOut);
		AudioComponentInstanceDispose(mPreviewOut);
		mPreviewOut = nullptr;
		for (auto& slice : mPreviewSlice) {
			slice.store(-1, std::memory_order_relaxed);
		}
		mPreviewOn.store(false);
	}

	static OSStatus PreviewCallback(void* refCon, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* timeStamp, UInt32,
		UInt32 frames, AudioBufferList* io)
	{
		static_cast<ChipmunkSoul*>(refCon)->RenderPreview(*flags, *timeStamp, frames, *io);
		return noErr;
	}

	void RenderPreview(AudioUnitRenderActionFlags& flags, const AudioTimeStamp& ts, UInt32 frames, AudioBufferList& io) noexcept
	{
		mPreviewEpoch.fetch_add(1);
		const Kit* kit = mKit.load();
		float* L = static_cast<float*>(io.mBuffers[0].mData);
		float* R = static_cast<float*>(io.mBuffers[io.mNumberBuffers > 1 ? 1 : 0].mData);
		std::fill(L, L + frames, 0.f);
		std::fill(R, R + frames, 0.f);
		// The song position, carried on from GarageBand's last render, so notes recorded from here
		// land in song time and the tempo sync matches.
		const double sr = mPreviewRate;
		const double now = HostSeconds(ts, mPreview.mClock / sr);
		const bool playing = mLastPlaying.load(std::memory_order_relaxed);
		const double tempo = mLastTempo.load(std::memory_order_relaxed);
		const double beat = mLastBeat.load(std::memory_order_relaxed) +
							(playing ? (now - mLastSeconds.load(std::memory_order_relaxed)) * tempo / 60.0 : 0.0);
		mPreview.Prepare(*kit, mHostTempo.load(std::memory_order_relaxed) > 0 ? tempo : 0.0, beat, playing, now);

		auto& events = mPreview.mEvents;
		size_t numEvents = 0;
		NoteEvent e;
		while (numEvents < events.size() && mUIQueue.Pop(e)) {
			e.offset = 0;
			events[numEvents++] = e;
		}
		if (!mPreview.Process(*kit, events.data(), numEvents, L, R, std::min<UInt32>(frames, 4096), sr)) {
			flags |= kAudioUnitRenderAction_OutputIsSilence;
		}
		mPreview.Publish(mPreviewFrame, mPreviewSlice, mPreviewLevel);
		mPreviewEpoch.fetch_add(1);
	}

	// Seconds on the shared host clock for a render (the time it will play), for the recorder, or
	// `fallback` when the host gives no time.
	static double HostSeconds(const AudioTimeStamp& ts, double fallback)
	{
		static const double ticksToSeconds = [] {
			mach_timebase_info_data_t info;
			mach_timebase_info(&info);
			return double(info.numer) / double(info.denom) * 1e-9;
		}();
		if (!(ts.mFlags & kAudioTimeStampHostTimeValid) || ts.mHostTime == 0) {
			return fallback;
		}
		return double(ts.mHostTime) * ticksToSeconds;
	}

	static double SyncedPitch(double hostBPM, double sampleBPM)
	{
		// The record plays at the project's tempo itself. Double or half time is only used when matching
		// the tempo exactly would take more than an octave of pitch (a 65 BPM record in a 140 project).
		double best = 12.0 * std::log2(hostBPM / sampleBPM);
		while (best > 12.0) best -= 12.0;
		while (best < -12.0) best += 12.0;
		return best;
	}

	// One player: voices, drums and effects with their running state. The plug-in has two: `mMain`,
	// which GarageBand renders (MIDI from the song and keyboards), and `mPreview`, which plays notes
	// from the editor straight to the speakers when Instant Play is on, skipping GarageBand's
	// render-ahead buffering so pads and keys feel immediate.
	struct Engine {
		ChipmunkSoul& au;
		explicit Engine(ChipmunkSoul& owner) : au(owner) {}

		// Per-block setup: tempo sync, pitch and the beat lock.
		void Prepare(const Kit& kit, double tempo, double beat, bool playing, double seconds)
		{
			mBlockBeat = beat;
			mBlockTempo = tempo > 0 ? tempo : 120.0;
			mBlockPlaying = playing && tempo > 0;
			mBlockSeconds = seconds;
			const bool synced = au.GetParameterRT(kParam_Sync) >= 0.5f && kit.bpm > 0 && tempo > 0;
			mKeepPitch = au.GetParameterRT(kParam_KeepPitch) >= 0.5f;
			if (mKeepPitch) {
				// Tempo by time-stretching; the Pitch slider moves pitch on its own.
				mPitch = au.GetParameterRT(kParam_Pitch);
				mTimeRatio = 1.0;
				if (synced) {
					mTimeRatio = tempo / kit.bpm;
					while (mTimeRatio > 1.414) {
						mTimeRatio *= 0.5;
					}
					while (mTimeRatio < 0.707) {
						mTimeRatio *= 2.0;
					}
				}
			} else {
				mPitch = synced ? float(SyncedPitch(tempo, kit.bpm)) : au.GetParameterRT(kParam_Pitch);
				mTimeRatio = std::exp2(mPitch / 12.0);
			}
			// Record frames per song beat while synced and playing (0 = not locked). Synced, this is the
			// record's own beat length times a whole octave factor, so it holds steady across tempo changes.
			mLockFramesPerBeat = synced && mBlockPlaying && kit.sample ? kit.sample->sampleRate * mTimeRatio * 60.0 / tempo : 0;
			if (kit.generation != mLastGeneration) {
				mLastGeneration = kit.generation;
				for (auto& v : mVoices) {
					v.stage = Voice::kIdle;
				}
			}
		}

		// Plays one block: events (sorted by offset) start and stop voices where they fall, then the
		// effects and the drums. Returns false when the output is silent.
		bool Process(const Kit& kit, NoteEvent* events, size_t numEvents, float* outL, float* outR, UInt32 frames, double sr)
		{
			UInt32 cursor = 0;
			size_t ei = 0;
			while (cursor < frames) {
				while (ei < numEvents && events[ei].offset <= cursor) {
					HandleEvent(kit, events[ei++], sr, cursor);
				}
				const UInt32 next = ei < numEvents ? std::min<UInt32>(events[ei].offset, frames) : frames;
				RenderVoices(kit, outL + cursor, outR + cursor, next - cursor, sr, cursor);
				cursor = next;
			}
			while (ei < numEvents) {
				HandleEvent(kit, events[ei++], sr, frames - 1);
			}
			AddVinyl(outL, outR, frames, sr);
			ProcessFX(outL, outR, frames, sr);
			const bool drums = RenderDrums(outL, outR, frames, sr);
			mClock += frames;
			bool sounding = drums || !mFXSilent;
			for (const auto& v : mVoices) {
				sounding = sounding || v.stage != Voice::kIdle;
			}
			return sounding;
		}

		void Publish(std::array<std::atomic<uint32_t>, kMaxVoices>& frame, std::array<std::atomic<int32_t>, kMaxVoices>& slice,
			std::array<std::atomic<float>, kMaxVoices>& level) const
		{
			for (size_t i = 0; i < mVoices.size(); ++i) {
				const auto& v = mVoices[i];
				const bool on = v.stage != Voice::kIdle;
				frame[i].store(on ? uint32_t(std::max(0.0, v.pos)) : 0, std::memory_order_relaxed);
				slice[i].store(on ? v.slice : -1, std::memory_order_relaxed);
				level[i].store(on ? v.env : 0.f, std::memory_order_relaxed);
			}
		}

		void ResetVoices()
		{
			for (auto& v : mVoices) {
				v.stage = Voice::kIdle;
			}
			for (auto& f : mFilters) {
				f.Reset();
			}
			mHeld[0] = mHeld[1] = 0.f;
			mCrunchPhase = 0;
			mGainSmoothed = -1.f;
		}

		// Hands a played note to the editor's recorder, timed in beats: the song position while the host
		// plays, otherwise a free-running clock at the song's tempo.
		void Record(int note, int velocity, UInt32 at, double sr)
		{
			if (note < 0 || note > 127) {
				return;
			}
			const double beat = mBlockPlaying ? mBlockBeat + at / sr * mBlockTempo / 60.0 : (mBlockSeconds + at / sr) * mBlockTempo / 60.0;
			au.mRecorded.Push({ beat, uint8_t(note), uint8_t(velocity), uint8_t(mBlockPlaying ? 1 : 0), 0 });
		}

		void HandleEvent(const Kit& kit, const NoteEvent& e, double sr, UInt32 at)
		{
			const int root = int(au.GetParameterRT(kParam_RootNote));
			switch (e.type) {
			case NoteEvent::kOn:
				Record(e.note, std::max<int>(1, e.velocity), at, sr);
				break;
			case NoteEvent::kOff:
				Record(e.note, 0, at, sr);
				break;
			case NoteEvent::kAudition:
				Record(root + e.note, e.velocity, at, sr);
				break;
			case NoteEvent::kAuditionOff:
				Record(root + e.note, 0, at, sr);
				break;
			case NoteEvent::kAuditionDrum:
				if (e.note < kNumDrums) {
					Record(root + kDrumOffsets[e.note], e.velocity, at, sr);
					Record(root + kDrumOffsets[e.note], 0, at, sr);  // drums are one-shots
				}
				break;
			default:
				break;
			}
			switch (e.type) {
			case NoteEvent::kOn: {
				const int offset = int(e.note) - root;
				if (offset >= 0) {
					StartVoice(kit, offset, e.note, e.velocity, sr);
				}
				for (int d = 0; d < kNumDrums; ++d) {  // the octave below the chops is the drum kit
					if (offset == kDrumOffsets[d]) {
						StartDrum(d, e.velocity, at);
					}
				}
				break;
			}
			case NoteEvent::kAuditionDrum:
				if (e.note < kNumDrums) {
					StartDrum(e.note, e.velocity, at);
				}
				break;
			case NoteEvent::kAudition:  // from the editor: pads, waveform clicks, laptop keys
				StartVoice(kit, e.note, kAuditionNote + e.note, e.velocity, sr);
				break;
			case NoteEvent::kOff:
			case NoteEvent::kAuditionOff: {
				const int note = e.type == NoteEvent::kOff ? e.note : kAuditionNote + e.note;
				const int64_t frames = kit.sample ? int64_t(kit.sample->frames) : 0;
				for (auto& v : mVoices) {
					if (v.note != note || !v.held || v.stage == Voice::kIdle) {
						continue;
					}
					// Letting go always stops the chop: fade out from wherever it has got to, even if
					// that's past the chop's end.
					v.held = false;
					if (v.reverse) {
						v.start = 0;
					} else {
						v.end = uint32_t(frames);
					}
					if (v.stage != Voice::kRelease) {
						Release(v, au.GetParameterRT(kParam_Release), sr);
					}
				}
				break;
			}
			case NoteEvent::kAllOff:
				for (auto& v : mVoices) {
					if (v.stage != Voice::kIdle) {
						Release(v, 8.f, sr);
					}
				}
				break;
			}
		}

		static void Release(Voice& v, float ms, double sr)
		{
			v.stage = Voice::kRelease;
			v.releaseCoef = float(std::exp(std::log(0.001) / (std::max(1.f, ms) * 0.001 * sr)));
		}

		void StartVoice(const Kit& kit, int slice, int note, int velocity, double sr)
		{
			if (!kit.sample || slice < 0 || slice >= int(kit.starts.size())) {
				return;
			}
			// Choke cuts everything; a mute group cuts only the other chops in the same group.
			const bool chokeAll = au.GetParameterRT(kParam_Choke) >= 0.5f;
			const int group = au.mGroups[size_t(slice)].load(std::memory_order_relaxed);
			for (auto& v : mVoices) {
				if (v.stage != Voice::kIdle && v.stage != Voice::kRelease && (chokeAll || (group > 0 && v.group == group))) {
					Release(v, 8.f, sr);
				}
			}

			Voice* voice = nullptr;
			for (auto& v : mVoices) {
				if (v.stage == Voice::kIdle) {
					voice = &v;
					break;
				}
			}
			if (!voice) {  // steal: prefer the quietest releasing voice, else the oldest
				for (auto& v : mVoices) {
					if (!voice || (v.stage == Voice::kRelease && (voice->stage != Voice::kRelease || v.env < voice->env)) ||
						(voice->stage != Voice::kRelease && v.age < voice->age)) {
						voice = &v;
					}
				}
			}

			const float sens = au.GetParameterRT(kParam_VelocitySens) * 0.01f;
			const float vel = float(velocity) / 127.f;
			const float attackMs = std::max(0.5f, au.GetParameterRT(kParam_Attack));
			const float chopPitch = au.mChopPitch[size_t(slice)].load(std::memory_order_relaxed);
			const float chopGain = std::pow(10.f, au.mChopGainDb[size_t(slice)].load(std::memory_order_relaxed) / 20.f);
			const bool chopReverse = au.mChopReverse[size_t(slice)].load(std::memory_order_relaxed);

			Voice& v = *voice;
			v.slice = slice;
			v.group = group;
			v.note = note;
			v.start = kit.starts[size_t(slice)];
			v.end = std::max(v.start + 1, kit.SliceEnd(size_t(slice)));
			v.reverse = (au.GetParameterRT(kParam_Reverse) >= 0.5f) != chopReverse;
			v.pos = v.reverse ? double(v.end) - 1.0 : double(v.start);
			v.held = true;
			v.chopRatio = std::exp2(chopPitch / 12.0);
			v.anchorBeat = NAN;  // anchored on its first rendered sample
		v.sinceLoop = 1e9;
			v.grainStart[0] = v.grainStart[1] = v.pos;
			v.grainPhase[0] = 0;
			v.grainPhase[1] = GrainLength(sr) / 2;
			v.gain = ((1.f - sens) + sens * vel * vel) * chopGain;
			v.env = 0.f;
			v.attackInc = float(1.0 / (attackMs * 0.001 * sr));
			v.stage = Voice::kAttack;
			v.age = ++mAgeCounter;
		}

		static double GrainLength(double sr) { return std::round(0.05 * sr); }

		void RenderVoices(const Kit& kit, float* outL, float* outR, UInt32 frames, double sr, UInt32 at)
		{
			if (!kit.sample || frames == 0) {
				return;
			}
			const Sample& s = *kit.sample;
			const float* L = s.left.data();
			const float* R = s.right.data();
			const int64_t n = s.frames;
			const double base = s.sampleRate / sr;
			// Varispeed: the record's speed sets both pitch and tempo. Keep Pitch: `pos` moves at the
			// tempo speed while grains read at the pitch speed.
			const double pitchSpeed = base * std::exp2(mPitch / 12.0);
			const double tempoSpeed = mKeepPitch ? base * mTimeRatio : pitchSpeed;
			const double declick = 0.003 * sr;  // output frames of fade at the slice edge
			const double grainLen = GrainLength(sr);
			const int endMode = std::clamp(int(au.GetParameterRT(kParam_EndMode) + 0.5f), 0, 2);

			// Vinyl wow (slow) and flutter (fast) wobble the speed a little.
			const float vinyl = au.GetParameterRT(kParam_Vinyl) * 0.01f;
			const double w1 = 2 * M_PI * 0.55 / sr, w2 = 2 * M_PI * 6.5 / sr;
			auto wobbleAt = [&](UInt32 i) {
				return vinyl > 0 ? 1.0 + vinyl * (0.0035 * std::sin(mWowPhase + i * w1) + 0.0007 * std::sin(mFlutterPhase + i * w2)) : 1.0;
			};

			const double songBeat = mBlockBeat + at / sr * mBlockTempo / 60.0;
			for (auto& v : mVoices) {
				if (v.stage == Voice::kIdle) {
					continue;
				}
				const double dir = v.reverse ? -1.0 : 1.0;
				if (mLockFramesPerBeat > 0) {
					const double framesPerBeat = mLockFramesPerBeat * v.chopRatio;
					if (std::isnan(v.anchorBeat) || std::abs(framesPerBeat / v.anchorFramesPerBeat - 1.0) > 1e-6) {
						v.anchorBeat = songBeat;  // (re)anchor: new voice, play pressed, octave or chop pitch changed
						v.anchorPos = v.pos;
						v.anchorFramesPerBeat = framesPerBeat;
					} else if (songBeat < v.anchorBeat - 0.01) {
						v.stage = Voice::kIdle;  // the song is being rendered again from before this note began
						continue;
					} else {
						v.pos = v.anchorPos + dir * (songBeat - v.anchorBeat) * framesPerBeat;
					}
				} else {
					v.anchorBeat = NAN;
				}
				const double read = pitchSpeed * v.chopRatio;
				const double move = mKeepPitch ? tempoSpeed : read;
				for (UInt32 i = 0; i < frames; ++i) {
					// Loop: while the key is held, jump back to the chop's start each time it ends.
					if (v.held && endMode == kEndLoop) {
						const double len = double(v.end) - double(v.start);
						const bool past = v.reverse ? v.pos < double(v.start) : v.pos >= double(v.end);
						if (len > 0 && past) {
							const double over = v.reverse ? double(v.start) - v.pos : v.pos - double(v.end);
							const double jump = dir * (std::floor(over / len) + 1) * len;
							v.pos -= jump;
							v.grainStart[0] -= jump;
							v.grainStart[1] -= jump;
							if (!std::isnan(v.anchorBeat)) {
								v.anchorPos -= jump;  // keeps the beat lock inside the chop
							}
							v.sinceLoop = 0;
						}
					}
					// Continue: while the key is held the chop keeps going into the rest of the song.
					const bool open = v.held && endMode == kEndContinue;
					const double stop = open ? (v.reverse ? 0.0 : double(n)) : (v.reverse ? double(v.start) : double(v.end));
					const double remaining = v.reverse ? v.pos - stop : stop - v.pos;
					if (remaining <= 0.0 || v.pos < 0.0 || v.pos >= double(n)) {
						v.stage = Voice::kIdle;
						break;
					}
					switch (v.stage) {
					case Voice::kAttack:
						v.env += v.attackInc;
						if (v.env >= 1.f) {
							v.env = 1.f;
							v.stage = Voice::kSustain;
						}
						break;
					case Voice::kRelease:
						v.env *= v.releaseCoef;
						if (v.env < 1e-4f) {
							v.stage = Voice::kIdle;
						}
						break;
					default:
						break;
					}
					if (v.stage == Voice::kIdle) {
						break;
					}
					const double wobble = wobbleAt(i);
					// Short fades at the chop's edge, and back in after a loop's jump, so neither clicks.
					const float edge = float(std::min({ 1.0, remaining / move / declick, v.sinceLoop / declick }));
					v.sinceLoop += 1.0;
					const float g = v.env * v.gain * edge;
					if (!mKeepPitch) {
						outL[i] += g * Hermite(L, n, v.pos);
						outR[i] += g * Hermite(R, n, v.pos);
					} else {
						// Two Hann-windowed grains half a grain apart always sum to 1.
						for (int k = 0; k < 2; ++k) {
							const double w = 0.5 - 0.5 * std::cos(2 * M_PI * v.grainPhase[k] / grainLen);
							const double src = v.grainStart[k] + dir * v.grainPhase[k] * read * wobble;
							outL[i] += g * float(w) * Hermite(L, n, src);
							outR[i] += g * float(w) * Hermite(R, n, src);
							v.grainPhase[k] += 1.0;
							if (v.grainPhase[k] >= grainLen) {
								v.grainPhase[k] -= grainLen;
								v.grainStart[k] = v.pos;
							}
						}
					}
					v.pos += dir * move * wobble;
				}
			}
			mWowPhase = std::fmod(mWowPhase + frames * w1, 2 * M_PI);
			mFlutterPhase = std::fmod(mFlutterPhase + frames * w2, 2 * M_PI);
		}

		// Crackle and hiss, only while chops are sounding (with a short tail), before the filters so
		// Low/High Cut shape them like the record.
		void AddVinyl(float* L, float* R, UInt32 frames, double sr)
		{
			const float vinyl = au.GetParameterRT(kParam_Vinyl) * 0.01f;
			bool sounding = false;
			for (const auto& v : mVoices) {
				sounding = sounding || v.stage != Voice::kIdle;
			}
			if (vinyl <= 0.f && mVinylLevel < 1e-4f) {
				return;
			}
			const float target = sounding ? vinyl : 0.f;
			const float smooth = float(1.0 - std::exp(-1.0 / (0.25 * sr)));
			for (UInt32 i = 0; i < frames; ++i) {
				mVinylLevel += (target - mVinylLevel) * smooth;
				float pop = 0.f;
				if (mVinylNoise.Noise() * 0.5f + 0.5f < 0.0004f * mVinylLevel) {
					mCrackle = (0.15f + 0.35f * std::abs(mVinylNoise.Noise())) * (mVinylNoise.Noise() > 0 ? 1.f : -1.f);
				}
				pop = mCrackle;
				mCrackle *= 0.55f;  // each crackle is a few samples long
				mHiss += (mVinylNoise.Noise() - mHiss) * 0.35f;
				const float x = mVinylLevel * (pop + 0.012f * mHiss);
				L[i] += x;
				R[i] += x * 0.9f;
			}
		}

		void StartDrum(int type, int velocity, UInt32 at)
		{
			// A new hat (closed or open) cuts off a ringing open hat.
			if (type == kDrumClosedHat || type == kDrumOpenHat) {
				for (auto& d : mDrums) {
					if (d.type == kDrumOpenHat) {
						d.choked = true;
					}
				}
			}
			DrumVoice* voice = &mDrums[0];
			for (auto& d : mDrums) {
				if (d.type < 0) {
					voice = &d;
					break;
				}
				if (d.t > voice->t) {
					voice = &d;  // steal the oldest
				}
			}
			const float vel = float(velocity) / 127.f;
			const float sens = au.GetParameterRT(kParam_VelocitySens) * 0.01f;
			voice->type = type;
			voice->t = 0;
			voice->phase = 0;
			voice->gain = (1.f - sens) + sens * vel * vel;
			voice->fade = 1.f;
			voice->choked = false;
			voice->delay = at;
			voice->seed = 0x9e3779b9u * uint32_t(type + 1) + uint32_t(mClock);
			voice->filter.Reset();
		}

		// The drum kit plays after the sample's effects so it stays clean and punchy. Each kit adds its
		// own lo-fi character (bit depth, sample rate, low-pass) to the drum bus.
		bool RenderDrums(float* L, float* R, UInt32 frames, double sr)
		{
			const KitDef& kit = kKits[std::clamp(int(au.GetParameterRT(kParam_DrumKit) + 0.5f), 0, kNumDrumKits - 1)];
			const float volume = std::pow(10.f, au.GetParameterRT(kParam_DrumVolume) / 20.f);
			const float chokeCoef = float(std::exp(-1.0 / (0.008 * sr)));
			const float kQ = 1.2f;
			auto g = [&](double hz) { return std::tan(float(M_PI) * float(std::min(hz, 0.45 * sr)) / float(sr)); };
			const float gSnare = g(kit.snareNoiseHz), gClap = g(kit.clapHz), gHat = g(kit.hatHz), gCymbal = g(kit.cymbalHz);
			const float gCowbell = g(400), gShaker = g(kit.percHz);
			// A cluster of detuned square waves: the classic analog drum machine "metal".
			auto metal = [](double t, double scale) {
				static const double freqs[] = { 205.3, 304.4, 369.6, 522.7, 540.0, 800.0 };
				float sum = 0;
				for (double f : freqs) {
					sum += std::sin(2 * M_PI * f * scale * t) >= 0 ? 1.f : -1.f;
				}
				return sum / 6.f;
			};
			auto square = [](double t, double f) { return std::sin(2 * M_PI * f * t) >= 0 ? 1.f : -1.f; };

			bool any = false;
			for (UInt32 c = 0; c < frames; c += UInt32(mDrumBus.size())) {
				const UInt32 n = std::min<UInt32>(frames - c, UInt32(mDrumBus.size()));
				std::fill(mDrumBus.begin(), mDrumBus.begin() + n, 0.f);
				for (auto& d : mDrums) {
					if (d.type < 0) {
						continue;
					}
					any = true;
					for (UInt32 i = d.delay > c ? d.delay - c : 0; i < n; ++i) {
						const double t = d.t;
						const float noise = d.Noise();
						float high = 0.f, low = 0.f, y = 0.f;
						switch (d.type) {
						case kDrumKick: {
							const double f = kit.kickEnd + (kit.kickStart - kit.kickEnd) * std::exp(-t * kit.kickSweep);
							d.phase += f / sr;
							const float body = float(std::sin(2 * M_PI * d.phase) * std::exp(-t * kit.kickDecay));
							y = std::tanh(body * kit.kickDrive) / std::tanh(kit.kickDrive) + noise * float(std::exp(-t * 300.0)) * kit.kickClick * 0.4f;
							break;
						}
						case kDrumSnare:
							d.filter.Tick(noise, gSnare, kQ, high);
							y = float(std::sin(2 * M_PI * kit.snareTone * t) * std::exp(-t * kit.snareToneDecay)) * kit.snareToneMix +
								high * float(std::exp(-t * kit.snareNoiseDecay)) * (1.f - kit.snareToneMix) * 1.2f;
							break;
						case kDrumClap: {
							low = d.filter.Tick(noise, gClap, kQ, high);
							const float band = (noise - low - high) / kQ;
							double env = 0;
							for (double burst : { 0.0, 0.010, 0.021 }) {
								env += t >= burst ? std::exp(-(t - burst) * 170.0) : 0.0;
							}
							env += t > 0.03 ? 0.9 * std::exp(-(t - 0.03) * kit.clapTail) : 0.0;
							y = band * float(env) * 1.4f;
							break;
						}
						case kDrumRim:
							y = float(std::sin(2 * M_PI * 1650.0 * t) * std::exp(-t * 95.0)) * 0.5f + noise * float(std::exp(-t * 250.0)) * 0.25f;
							break;
						case kDrumClosedHat:
						case kDrumOpenHat: {
							const float src = kit.hatMetal * metal(t, 1.6) + (1.f - kit.hatMetal) * noise;
							d.filter.Tick(src, gHat, kQ, high);
							const float decay = d.type == kDrumClosedHat ? kit.hatClosedDecay : kit.hatOpenDecay;
							y = high * float(std::exp(-t * decay)) * (d.type == kDrumClosedHat ? 0.5f : 0.42f);
							break;
						}
						case kDrumLowTom:
						case kDrumHighTom: {
							const double base = d.type == kDrumLowTom ? kit.tomLowHz : kit.tomHighHz;
							d.phase += base * (1.0 + 0.5 * std::exp(-t * 20.0)) / sr;
							y = float(std::sin(2 * M_PI * d.phase) * std::exp(-t * kit.tomDecay)) * 0.8f + noise * float(std::exp(-t * 80.0)) * 0.05f;
							break;
						}
						case kDrumCymbal:
							d.filter.Tick(0.6f * metal(t, 2.3) + 0.4f * noise, gCymbal, kQ, high);
							y = high * float(std::exp(-t * kit.cymbalDecay)) * 0.4f;
							break;
						case kDrumPerc:
							switch (kit.perc) {
							case kPercCowbell:
								d.filter.Tick(0.5f * (square(t, kit.percHz) + square(t, kit.percHz * 1.48)), gCowbell, kQ, high);
								y = high * float(std::exp(-t * kit.percDecay)) * 0.35f;
								break;
							case kPercShaker:
								d.filter.Tick(noise, gShaker, kQ, high);
								y = high * float(std::min(1.0, t / 0.01) * std::exp(-t * kit.percDecay)) * 0.4f;
								break;
							case kPercConga:
								d.phase += kit.percHz * (1.0 + 0.3 * std::exp(-t * 30.0)) / sr;
								y = float(std::sin(2 * M_PI * d.phase) * std::exp(-t * kit.percDecay)) * 0.6f;
								break;
							}
							break;
						}
						if (d.choked) {
							d.fade *= chokeCoef;
						}
						mDrumBus[i] += y * d.gain * d.fade;
						d.t += 1.0 / sr;
						if (d.t > 3.0 || d.fade < 1e-4f) {
							d.type = -1;
							break;
						}
					}
				}
				// The kit's lo-fi character.
				const float levels = std::exp2(kit.bits - 1.f);
				const float holdInc = kit.holdHz > 0 ? float(kit.holdHz / sr) : 1.f;
				const float lp = 1.f - std::exp(-2.f * float(M_PI) * float(std::min<double>(kit.lowpassHz, 0.45 * sr)) / float(sr));
				for (UInt32 i = 0; i < n; ++i) {
					float x = mDrumBus[i];
					if (kit.bits < 16) {
						x = std::round(x * levels) / levels;
					}
					mDrumHoldPhase += holdInc;
					if (mDrumHoldPhase >= 1.f) {
						mDrumHoldPhase -= 1.f;
						mDrumHeld = x;
					}
					mDrumLP += (mDrumHeld - mDrumLP) * lp;
					const float out = mDrumLP * volume;
					L[c + i] += out;
					R[c + i] += out;
				}
			}
			for (auto& d : mDrums) {
				d.delay = 0;
			}
			return any || std::abs(mDrumLP) > 1e-6f;
		}

		void ProcessFX(float* L, float* R, UInt32 frames, double sr)
		{
			const float crunch = au.GetParameterRT(kParam_Crunch) * 0.01f;
			const float lowCut = std::min<float>(au.GetParameterRT(kParam_LowCut), float(0.45 * sr));
			const float highCut = std::min<float>(au.GetParameterRT(kParam_HighCut), float(0.45 * sr));
			const float gainTarget = std::pow(10.f, au.GetParameterRT(kParam_Volume) / 20.f);
			const float kQ = 1.4142135f;

			const float gHPTarget = std::tan(float(M_PI) * lowCut / float(sr));
			const float gLPTarget = std::tan(float(M_PI) * highCut / float(sr));
			if (mGainSmoothed < 0.f) {
				mGainSmoothed = gainTarget;
				mGHP = gHPTarget;
				mGLP = gLPTarget;
			}
			const float inv = 1.f / float(std::max<UInt32>(frames, 1));
			const float dGain = (gainTarget - mGainSmoothed) * inv;
			const float dHP = (gHPTarget - mGHP) * inv;
			const float dLP = (gLPTarget - mGLP) * inv;

			// SP-1200-ish: fewer bits, lower sample rate, a bit of drive.
			const float bits = 16.f - 8.f * crunch;
			const float levels = std::exp2(bits - 1.f);
			const float holdHz = float(sr) + (9000.f - float(sr)) * std::pow(crunch, 0.6f);
			const float holdInc = holdHz / float(sr);
			const float drive = 1.f + 2.5f * crunch;

			const bool hpOn = lowCut > 21.f || mGHP > gHPTarget + 1e-6f;
			const bool lpOn = highCut < 19900.f || mGLP < gLPTarget - 1e-6f;
			float peak = 0.f;

			for (UInt32 i = 0; i < frames; ++i) {
				float x[2] = { L[i], R[i] };
				if (crunch > 0.001f) {
					mCrunchPhase += holdInc;
					const bool sampleNow = mCrunchPhase >= 1.f;
					if (sampleNow) {
						mCrunchPhase -= 1.f;
					}
					for (int c = 0; c < 2; ++c) {
						float y = std::tanh(x[c] * drive) / drive;  // unity gain for quiet signals, soft-clips peaks
						y = std::round(y * levels) / levels;
						if (sampleNow) {
							mHeld[c] = y;
						}
						x[c] = mHeld[c];
					}
				}
				mGHP += dHP;
				mGLP += dLP;
				mGainSmoothed += dGain;
				for (int c = 0; c < 2; ++c) {
					float high;
					if (hpOn) {
						mFilters[c].Tick(x[c], mGHP, kQ, high);
						x[c] = high;
					}
					if (lpOn) {
						x[c] = mFilters[2 + c].Tick(x[c], mGLP, kQ, high);
					}
					x[c] *= mGainSmoothed;
					peak = std::max(peak, std::abs(x[c]));
				}
				L[i] = x[0];
				R[i] = x[1];
			}
			mGHP = gHPTarget;
			mGLP = gLPTarget;
			mGainSmoothed = gainTarget;
			mFXSilent = peak < 1e-6f;
		}


		uint64_t mLastGeneration = ~0ull;
		float mPitch = 0.f;             // semitones in effect this block
		double mTimeRatio = 1.0;        // how much faster than the record the chops move
		double mLockFramesPerBeat = 0;  // beat lock, see Voice::anchorBeat
		bool mKeepPitch = false;
		double mBlockBeat = 0, mBlockTempo = 120, mBlockSeconds = 0;
		bool mBlockPlaying = false;
		int64_t mClock = 0;  // samples rendered so far
		std::array<NoteEvent, 576> mEvents{};
		std::array<Voice, kMaxVoices> mVoices{};
		uint64_t mAgeCounter = 0;
		std::array<DrumVoice, 16> mDrums{};
		std::array<float, 1024> mDrumBus{};
		float mDrumHoldPhase = 0, mDrumHeld = 0, mDrumLP = 0;
		double mWowPhase = 0, mFlutterPhase = 0;
		float mVinylLevel = 0, mCrackle = 0, mHiss = 0;
		DrumVoice mVinylNoise;  // just for its noise generator
		std::array<SVF, 4> mFilters{};  // HP L/R, LP L/R
		float mGHP = 0, mGLP = 0, mGainSmoothed = -1.f;
		float mHeld[2] = { 0, 0 };
		float mCrunchPhase = 0;
		bool mFXSilent = true;
	};

	static constexpr int kAuditionNote = 1000;  // editor-triggered voices, kept apart from MIDI notes

	std::atomic<Kit*> mKit{ nullptr };
	std::mutex mKitMutex;
	std::atomic<uint64_t> mRenderEpoch{ 0 };
	uint64_t mGenerationCounter = 0;
	std::string mStatus, mMissingPath;
	std::atomic<double> mHostTempo{ 0.0 };
	std::atomic<float> mPlayingPitch{ 0.f };
	std::atomic<float> mPlayingRatio{ 1.f };
	std::string mExportPath;

	std::array<std::atomic<float>, kMaxSlices> mChopPitch{};
	std::array<std::atomic<float>, kMaxSlices> mChopGainDb{};
	std::array<std::atomic<bool>, kMaxSlices> mChopReverse{};

	EventQueue<RecordedNote, 4096> mRecorded;
	std::array<PendingEvent, 256> mPending{};
	size_t mNumPending = 0;
	std::array<int64_t, 128> mNoteDelay{};

	EventQueue<NoteEvent, 512> mMIDIQueue;
	EventQueue<NoteEvent, 64> mUIQueue;

	std::array<std::atomic<uint8_t>, kMaxSlices> mGroups{};  // mute group per chop; kept apart from the kit so
															 // regrouping never interrupts playback
	std::array<std::atomic<uint32_t>, kMaxVoices> mPlayFrame{};
	std::array<std::atomic<int32_t>, kMaxVoices> mPlaySlice{};
	std::array<std::atomic<float>, kMaxVoices> mPlayLevel{};
	std::array<std::atomic<uint32_t>, kMaxVoices> mPreviewFrame{};
	std::array<std::atomic<int32_t>, kMaxVoices> mPreviewSlice{};
	std::array<std::atomic<float>, kMaxVoices> mPreviewLevel{};

	Engine mMain{ *this };
	Engine mPreview{ *this };
	int64_t mMainClock = 0;  // samples GarageBand has rendered, for swing scheduling

	// Instant Play: the editor's notes render on their own output straight to the speakers.
	AudioUnit mPreviewOut = nullptr;
	std::atomic<bool> mPreviewOn{ false };
	double mPreviewRate = 48000;
	bool mEditorOpen = false;
	std::atomic<uint64_t> mPreviewEpoch{ 0 };
	// The song position GarageBand last rendered, so preview notes can be recorded in song time.
	std::atomic<double> mLastBeat{ 0 }, mLastTempo{ 120 }, mLastSeconds{ 0 };
	std::atomic<bool> mLastPlaying{ false };

};

}  // namespace cs

using ChipmunkSoul = cs::ChipmunkSoul;
AUSDK_COMPONENT_ENTRY(ausdk::AUMusicDeviceFactory, ChipmunkSoul)
