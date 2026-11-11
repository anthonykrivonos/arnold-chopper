// Recipes for the built-in drum kits. Everything is synthesized, so these are kits in the style of
// classic drum machines rather than copies of their samples.
#pragma once

#include "Shared.h"

namespace cs {

enum PercType { kPercCowbell, kPercShaker, kPercConga };

struct KitDef {
	// Kick: a sine sweeping from `start` to `end` Hz, decaying at `decay` per second.
	float kickStart, kickEnd, kickSweep, kickDecay, kickClick, kickDrive;
	// Snare: a tone plus high-passed noise.
	float snareTone, snareToneDecay, snareNoiseDecay, snareNoiseHz, snareToneMix;
	// Clap: band-passed noise bursts and a tail.
	float clapHz, clapTail;
	// Hats: noise and/or a metallic cluster of square waves, high-passed. `metal` 0..1 blends them.
	float hatHz, hatClosedDecay, hatOpenDecay, hatMetal;
	// Toms.
	float tomLowHz, tomHighHz, tomDecay;
	// Cymbal.
	float cymbalHz, cymbalDecay;
	// Percussion.
	PercType perc;
	float percHz, percDecay;
	// Lo-fi character of the whole kit: bit depth, sample-and-hold rate (0 = off), low-pass.
	float bits, holdHz, lowpassHz;
};

constexpr KitDef kKits[kNumDrumKits] = {
	// 808: long boomy kick, snappy tonal snare, metallic hats, the cowbell.
	{ 120, 48, 18, 2.2f, 0.05f, 1.0f, 238, 18, 16, 2000, 0.55f, 1100, 10, 7000, 45, 4, 1.0f, 95, 165, 7, 6000, 1.5f,
		kPercCowbell, 540, 9, 16, 0, 18000 },
	// 909: punchy, clicky kick, bright noisy snare.
	{ 220, 52, 32, 5, 0.35f, 1.6f, 190, 25, 11, 2500, 0.45f, 1300, 13, 8000, 55, 6, 0.6f, 110, 180, 9, 7000, 1.0f,
		kPercConga, 260, 12, 16, 0, 18000 },
	// 707: tight and crisp, slightly lo-fi.
	{ 160, 55, 30, 7, 0.2f, 1.2f, 200, 30, 15, 3000, 0.35f, 1500, 15, 9000, 60, 7, 0.3f, 120, 200, 10, 8000, 1.2f,
		kPercCowbell, 600, 10, 10, 25000, 12000 },
	// SP-1200: 12-bit, 26 kHz grit, driven kick.
	{ 100, 50, 25, 6, 0.3f, 2.2f, 180, 20, 9, 1800, 0.5f, 1200, 11, 7500, 50, 5, 0.2f, 100, 170, 8, 6500, 1.1f,
		kPercShaker, 6000, 25, 12, 26040, 13000 },
	// MPC60: 12-bit, warm and fat.
	{ 110, 50, 24, 5.5f, 0.25f, 1.8f, 195, 22, 10, 2000, 0.45f, 1250, 12, 8000, 50, 5, 0.2f, 105, 175, 8, 7000, 1.0f,
		kPercConga, 280, 12, 12, 40000, 15000 },
	// LinnDrum: tight 80s kick and snare.
	{ 130, 58, 35, 8, 0.3f, 1.3f, 220, 28, 12, 3000, 0.4f, 1400, 14, 9000, 60, 6, 0.1f, 130, 210, 10, 8000, 1.0f,
		kPercCowbell, 560, 10, 14, 28000, 16000 },
	// Boom Bap: dusty, heavy kick, cracking snare.
	{ 90, 48, 22, 5, 0.4f, 2.6f, 170, 18, 8, 1500, 0.5f, 1000, 9, 7000, 45, 5, 0.1f, 95, 160, 8, 6000, 1.2f,
		kPercShaker, 6000, 30, 12, 26040, 9000 },
	// Lo-Fi: 8-bit, muffled, soft.
	{ 80, 45, 20, 6, 0.2f, 2.0f, 160, 15, 9, 1200, 0.55f, 900, 10, 6000, 50, 6, 0.0f, 90, 150, 7, 5000, 1.4f,
		kPercConga, 240, 12, 8, 16000, 5000 },
	// Trap: long 808 boom, sharp hats and snare.
	{ 160, 42, 14, 1.4f, 0.3f, 2.0f, 210, 26, 14, 3500, 0.3f, 1600, 15, 10000, 80, 7, 0.4f, 90, 150, 5, 9000, 1.2f,
		kPercShaker, 7000, 25, 16, 0, 18000 },
	// Live Soul: tight acoustic kick, rattly snare, washy cymbal.
	{ 95, 55, 40, 9, 0.5f, 1.2f, 200, 30, 7, 1500, 0.35f, 1100, 12, 8500, 70, 4, 0.0f, 110, 170, 6, 5500, 0.8f,
		kPercConga, 300, 10, 16, 0, 14000 },
};

}  // namespace cs
