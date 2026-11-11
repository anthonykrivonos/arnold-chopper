// Shared between the Audio Unit (C++) and its Cocoa view (Objective-C++).
#pragma once

#include <AudioToolbox/AudioToolbox.h>
#include <cstdint>

#define CS_BUNDLE_ID "com.anthony.ChipmunkSoul"
#define CS_VIEW_FACTORY_CLASS ChipmunkSoulViewFactory_v1

namespace cs {

constexpr int kMaxSlices = 64;
constexpr int kMaxVoices = 64;  // enough to hold down any number of keys at once
constexpr int kMuteGroups = 4;  // A..D; chops in the same group cut each other off
constexpr int kOverviewPeaks = 65536;  // fine enough to zoom into a few bars of a long song

enum Param : AudioUnitParameterID {
	kParam_Pitch = 0,     // semitones, varispeed (tape) style: speed and pitch move together
	kParam_RootNote,      // MIDI note that triggers slice 1
	kParam_Attack,        // ms
	kParam_Release,       // ms
	kParam_PlayMode,      // retired: kept so saved projects keep their parameter IDs
	kParam_Choke,         // new slice cuts off the previous one (MPC mono style)
	kParam_Reverse,
	kParam_LowCut,        // Hz
	kParam_HighCut,       // Hz
	kParam_Crunch,        // %, SP-1200-ish bit/rate reduction + saturation
	kParam_VelocitySens,  // %
	kParam_Volume,        // dB
	kParam_Sync,          // follow the song tempo: pitch is set so the sample's BPM matches it
	kParam_KeepPitch,     // sync the tempo by time-stretching instead of speeding the record up
	kParam_Swing,         // %, MPC style: 50 = straight, 66 = triplet feel (delays off-beat 16ths)
	kParam_Vinyl,         // %, crackle and hiss while chops play, plus wow and flutter
	kParam_DrumVolume,    // dB, the built-in drum kit
	kParam_DrumKit,       // indexed: which kit (kDrumKitNames)
	kParam_EndMode,       // indexed (EndMode): what a held key does when its chop ends
	kParam_InstantPlay,   // notes from the editor play straight to the speakers, skipping GarageBand's buffering
	kNumParams
};

enum ChopMode : int32_t { kChop_Transients = 0, kChop_Beats = 1, kChop_Even = 2 };

// What a held key does when its chop ends: play on into the song, stop, or repeat the chop.
enum EndMode : int { kEndContinue = 0, kEndStop = 1, kEndLoop = 2 };

// Custom properties (global scope, element 0).
enum Property : AudioUnitPropertyID {
	kProp_LoadFile = 64000,  // set: CFStringRef absolute path
	kProp_Overview,          // get: CFDataRef -> OverviewHeader + float[2 * numPeaks] (min,max)
	kProp_Slices,            // get/set: CFDataRef -> SliceHeader + uint32_t[count]
	kProp_ChopSettings,      // get/set: ChopSettings (setting re-chops)
	kProp_Info,              // get: CFDictionaryRef (see kInfo* keys)
	kProp_Playheads,         // get: Playheads
	kProp_Audition,          // set: int32_t slice >= 0 starts it, -2 - slice releases it, -1 stops all
	kProp_MuteGroups,        // get/set: CFDataRef -> uint8_t[kMaxSlices], 0 = none, 1..kMuteGroups
	kProp_ChopEdits,         // get/set: CFDataRef -> ChopEdit[kMaxSlices]
	kProp_ExportChop,        // set: int32_t slice -> writes it to Music/Chipmunk Soul/Chops as a WAV
	kProp_ExportPath,        // get: CFStringRef path of the last exported chop
	kProp_Recorded,          // get: CFDataRef -> RecordedNote[] played since the last read (oldest first)
	kProp_EditorOpen,        // set: int32_t 1/0 when the editor opens/closes (Instant Play only runs while it's open)
};

// Audition values >= kAuditionDrum play drum (value - kAuditionDrum).
constexpr int32_t kAuditionDrum = 1000;

// Built-in drum kit: ten pads (⇧1..⇧0 in this order). From MIDI they sit on the octave just below
// the chops, laid out like General MIDI drums (offsets are semitones below the root note).
enum Drum : int {
	kDrumKick, kDrumSnare, kDrumClap, kDrumRim, kDrumClosedHat, kDrumOpenHat, kDrumLowTom, kDrumHighTom, kDrumCymbal, kDrumPerc,
	kNumDrums
};
constexpr int kDrumOffsets[kNumDrums] = { -12, -10, -9, -11, -6, -2, -7, -5, -3, -1 };
constexpr const char* kDrumNames[kNumDrums] = { "Kick", "Snare", "Clap", "Rim", "Hat", "Open Hat", "Low Tom", "Hi Tom", "Cymbal", "Perc" };

constexpr int kNumDrumKits = 10;
constexpr const char* kDrumKitNames[kNumDrumKits] = { "808", "909", "707", "SP-1200", "MPC60",
	"LinnDrum", "Boom Bap", "Lo-Fi", "Trap", "Live Soul" };

// A note played into the plug-in (from GarageBand, the laptop keys or the editor), for the recorder.
struct RecordedNote {
	double beat;       // song position in beats when the host is playing, else beats since a free-running clock
	uint8_t note;      // the MIDI note that plays it back (chops from the root up, drums an octave below)
	uint8_t velocity;  // 0 = note off
	uint8_t hostPlaying;
	uint8_t pad;
};

// Per-chop tweaks, applied on top of the global settings.
struct ChopEdit {
	float pitch;      // semitones
	float gainDb;
	int32_t reverse;  // flips the global Reverse for this chop
};

struct OverviewHeader {
	uint32_t numPeaks;
	uint32_t numFrames;
	double sampleRate;
};

struct SliceHeader {
	uint32_t regionStart;
	uint32_t regionEnd;
	uint32_t count;
};

struct ChopSettings {
	int32_t mode;
	int32_t count;
	float sensitivity;  // 0..1
	uint32_t regionStart;
	uint32_t regionEnd;  // 0 = end of file
	int32_t autoPick;    // >= 0: chop the Nth best part of the song (region is filled in); -1: region is manual
};

struct Playheads {
	uint32_t count;
	uint32_t frames[kMaxVoices];
	int32_t slices[kMaxVoices];
	float levels[kMaxVoices];
};

#define kInfoFileName CFSTR("fileName")
#define kInfoFilePath CFSTR("filePath")
#define kInfoStatus CFSTR("status")
#define kInfoSampleBPM CFSTR("sampleBPM")
#define kInfoHostBPM CFSTR("hostBPM")
#define kInfoPitch CFSTR("pitch")            // the pitch actually playing (differs from the slider while synced)
#define kInfoPicks CFSTR("picks")            // how many best-part candidates were found
#define kInfoTempoRatio CFSTR("tempoRatio")  // how much faster the chops play than the record

}  // namespace cs
