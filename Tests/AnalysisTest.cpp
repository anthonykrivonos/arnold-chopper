// Synthesizes a drum-and-chords loop at a known tempo and checks BPM detection and chopping.
#include "Analysis.h"

#include <cmath>
#include <cstdio>
#include <random>

using namespace cs;

static Sample* MakeLoop(double bpm, double sr, double seconds, double leadIn)
{
	const size_t n = size_t(seconds * sr);
	std::vector<float> l(n, 0.f);
	std::mt19937 rng(7);
	std::uniform_real_distribution<float> noise(-1.f, 1.f);
	const double beat = 60.0 / bpm * sr;
	// Soft sustained chord underneath, like a soul record.
	for (size_t i = 0; i < n; ++i) {
		const double t = i / sr;
		l[i] = 0.08f * float(std::sin(2 * M_PI * 220 * t) + std::sin(2 * M_PI * 277.2 * t) + std::sin(2 * M_PI * 329.6 * t));
	}
	for (int b = 0;; ++b) {
		const size_t at = size_t(leadIn * sr + b * beat);
		if (at >= n) {
			break;
		}
		const bool kick = b % 2 == 0;
		for (size_t k = 0; k < size_t(0.18 * sr) && at + k < n; ++k) {
			const double t = k / sr;
			const float env = float(std::exp(-t * (kick ? 18 : 30)));
			l[at + k] += kick ? 0.8f * env * float(std::sin(2 * M_PI * (50 + 80 * std::exp(-t * 40)) * t))
							  : 0.5f * env * noise(rng);
		}
	}
	return MakeSample(l, {}, sr);
}

int main()
{
	int failures = 0;
	for (double bpm : { 84.0, 92.0, 100.0, 118.0, 132.0 }) {
		const double sr = 44100;
		const double leadIn = 0.37;
		Sample* s = MakeLoop(bpm, sr, 20, leadIn);
		const double est = EstimateBPM(*s, 0, 0);
		const bool bpmOK = std::abs(est - bpm) < 1.0;

		double chopBPM = 0;
		ChopSettings beats{ kChop_Beats, 16, 0.5f, 0, 0 };
		auto b = Chop(*s, beats, &chopBPM);
		// Beat slices after the first should sit within ~15 ms before the hit they belong to.
		const double period = 60.0 / bpm * sr;
		// Signed offset from the nearest hit: slightly early is fine, late would clip the attack.
		auto offsetMs = [&](uint32_t f) {
			const double k = std::round((f - leadIn * sr) / period);
			return (f - (leadIn * sr + k * period)) / sr * 1000;
		};
		auto inTolerance = [](double ms) { return ms > -8 && ms < 1; };
		double worst = 0;
		bool beatsOK = true;
		for (size_t i = 1; i < b.size(); ++i) {
			const double ms = offsetMs(b[i]);
			beatsOK = beatsOK && inTolerance(ms);
			worst = std::abs(ms) > std::abs(worst) ? ms : worst;
		}
		// A region holding exactly 16 hits: every slice after the first must land on one.
		ChopSettings tr{ kChop_Transients, 16, 0.7f, 0, uint32_t((leadIn + 15.5 * 60 / bpm) * sr) };
		auto t = Chop(*s, tr, nullptr);
		double worstT = 0;
		bool transientsOK = true;
		for (size_t i = 1; i < t.size(); ++i) {
			const double ms = offsetMs(t[i]);
			transientsOK = transientsOK && inTolerance(ms);
			worstT = std::abs(ms) > std::abs(worstT) ? ms : worstT;
		}
		// Region start + one chop per hit (the region holds 16 hits).
		const bool ok = bpmOK && b.size() == 16 && beatsOK && t.size() >= 16 && t.size() <= 17 && transientsOK;
		failures += !ok;
		printf("%s  true %.0f BPM -> detected %.2f | beats: %zu slices, worst offset %.1f ms | transients: %zu slices, worst %.1f ms\n",
			ok ? "PASS" : "FAIL", bpm, est, b.size(), worst, t.size(), worstT);
		delete s;
	}
	// Best-part search: 20 s of quiet hiss, 15 s of loud noise bursts, then 15 s of a groove with
	// changing chords. The pick must land in the groove.
	{
		const double sr = 44100, beat = 60.0 / 96 * sr;
		std::vector<float> song(size_t(50 * sr), 0.f);
		std::mt19937 rng(3);
		std::uniform_real_distribution<float> noise(-1.f, 1.f);
		for (size_t i = 0; i < size_t(20 * sr); ++i) song[i] = 0.01f * noise(rng);
		for (size_t i = size_t(20 * sr); i < size_t(35 * sr); ++i) {
			const double inBeat = std::fmod(double(i), beat) / sr;
			song[i] = 0.5f * float(std::exp(-inBeat * 10)) * noise(rng);
		}
		const double chords[4][3] = { { 220, 277.2, 329.6 }, { 246.9, 311.1, 370 }, { 196, 246.9, 293.7 }, { 174.6, 220, 261.6 } };
		for (size_t i = size_t(35 * sr); i < song.size(); ++i) {
			const double t = i / sr, inBeat = std::fmod(double(i), beat) / sr;
			const auto& c = chords[size_t((i - size_t(35 * sr)) / size_t(beat * 2)) % 4];
			float v = 0.12f * float(std::sin(2 * M_PI * c[0] * t) + std::sin(2 * M_PI * c[1] * t) + std::sin(2 * M_PI * c[2] * t));
			v += 0.6f * float(std::exp(-inBeat * 20) * std::sin(2 * M_PI * 60 * inBeat));
			song[i] = v;
		}
		Sample* g = MakeSample(song, {}, sr);
		auto picks = FindBestSections(*g, 16, 4);
		const bool ok = !picks.empty() && picks[0].start >= 34.5 * sr && picks.size() >= 2;
		failures += !ok;
		printf("%s  best part of a 50 s song: %.1f-%.1fs (groove is 35-50s), %zu candidates\n", ok ? "PASS" : "FAIL",
			picks.empty() ? -1.0 : picks[0].start / sr, picks.empty() ? -1.0 : picks[0].end / sr, picks.size());
		delete g;
	}

	ChopSettings even{ kChop_Even, 8, 0.5f, 1000, 9000 };
	Sample* s = MakeLoop(100, 48000, 5, 0);
	auto e = Chop(*s, even, nullptr);
	const bool evenOK = e.size() == 8 && e[0] == 1000 && e[1] == 2000 && e[7] == 8000;
	failures += !evenOK;
	printf("%s  even chop: %zu slices starting %u, %u ... %u\n", evenOK ? "PASS" : "FAIL", e.size(), e[0], e[1], e[7]);
	delete s;
	return failures;
}
