// Sample loading, onset detection, tempo estimation and auto-chopping.
// Nothing in here is realtime-safe; it runs on the UI / host thread.
#pragma once

#include "Shared.h"
#include "VocalDetector.h"

#include <array>
#include <string>
#include <vector>

namespace cs {

struct Sample {
	std::vector<float> left, right;  // deinterleaved, at the file's own sample rate
	double sampleRate = 44100.0;
	uint32_t frames = 0;
	std::string path, name;

	std::vector<float> overview;  // kOverviewPeaks (min, max) pairs of the mono mix

	// Onset analysis.
	uint32_t hop = 512;
	std::vector<float> novelty;  // one value per hop, >= 0

	// Per-hop descriptors used to judge which part of the song is worth chopping.
	static constexpr int kTimbreBands = 12;
	std::vector<float> loudness;                             // dB
	std::vector<float> tonality;                             // 0 = noise .. 1 = clearly pitched (300 Hz-3 kHz)
	std::vector<std::array<float, kTimbreBands>> timbre;  // log energy in log-spaced bands
	std::vector<std::array<float, 12>> chroma;            // pitch-class energy (C..B), unit length
	VoiceActivity voices;                                 // singing / drums over time (files only)
};

struct Section {
	uint32_t start, end;  // sample frames
	double score;         // 0..1
};

// Returns nullptr and fills `error` on failure.
Sample* LoadSample(const std::string& path, std::string& error);

// Builds a sample from raw buffers (used by the tests).
Sample* MakeSample(std::vector<float> left, std::vector<float> right, double sampleRate);

// Estimated tempo of [start, end) in BPM, folded into 70..140. 0 if nothing rhythmic was found.
double EstimateBPM(const Sample& s, uint32_t start, uint32_t end);

// The most chop-worthy stretches of `beats` beats anywhere in the song, best first, not overlapping.
std::vector<Section> FindBestSections(const Sample& s, int beats, int maxResults);

// Slice start points (sample frames, ascending, first one at or near settings.regionStart).
// Ignores settings.autoPick; resolve that into a region with FindBestSections first.
std::vector<uint32_t> Chop(const Sample& s, const ChopSettings& settings, double* outBPM);

}  // namespace cs
