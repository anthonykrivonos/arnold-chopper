#include "Analysis.h"

#include <Accelerate/Accelerate.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
#include <numeric>

namespace cs {

namespace {

constexpr uint32_t kFFTSize = 1024;
constexpr double kMaxSeconds = 12 * 60;

std::vector<float> MonoMix(const Sample& s)
{
	std::vector<float> mono(s.frames);
	for (uint32_t i = 0; i < s.frames; ++i) {
		mono[i] = 0.5f * (s.left[i] + s.right[i]);
	}
	return mono;
}

void BuildOverview(Sample& s, const std::vector<float>& mono)
{
	s.overview.assign(2 * kOverviewPeaks, 0.f);
	if (s.frames == 0) {
		return;
	}
	for (int p = 0; p < kOverviewPeaks; ++p) {
		const uint64_t a = uint64_t(p) * s.frames / kOverviewPeaks;
		const uint64_t b = std::max<uint64_t>(a + 1, uint64_t(p + 1) * s.frames / kOverviewPeaks);
		float lo = 0.f, hi = 0.f;
		for (uint64_t i = a; i < b && i < s.frames; ++i) {
			lo = std::min(lo, mono[i]);
			hi = std::max(hi, mono[i]);
		}
		s.overview[2 * p] = lo;
		s.overview[2 * p + 1] = hi;
	}
}

// Log-magnitude spectral flux, then a moving-average subtraction so only sudden changes remain.
void BuildNovelty(Sample& s, const std::vector<float>& mono)
{
	s.hop = s.sampleRate > 60000 ? 1024 : 512;
	const uint32_t numFrames = s.frames > kFFTSize ? (s.frames - kFFTSize) / s.hop + 1 : 1;

	const vDSP_Length log2n = 10;
	FFTSetup fft = vDSP_create_fftsetup(log2n, kFFTRadix2);
	std::vector<float> window(kFFTSize), frame(kFFTSize, 0.f), re(kFFTSize / 2), im(kFFTSize / 2);
	std::vector<float> mag(kFFTSize / 2), prev(kFFTSize / 2, 0.f);
	vDSP_hann_window(window.data(), kFFTSize, vDSP_HANN_NORM);

	// Timbre bands: 12 log-spaced bands from 60 Hz to 12 kHz.
	const float binHz = float(s.sampleRate / kFFTSize);
	std::array<uint32_t, Sample::kTimbreBands + 1> bandEdges;
	for (int b = 0; b <= Sample::kTimbreBands; ++b) {
		const float hz = 60.f * std::pow(200.f, float(b) / Sample::kTimbreBands);
		bandEdges[size_t(b)] = std::clamp<uint32_t>(uint32_t(hz / binHz), 1, kFFTSize / 2 - 1);
	}
	const uint32_t tonalLo = uint32_t(300.f / binHz), tonalHi = std::min<uint32_t>(kFFTSize / 2 - 1, uint32_t(3000.f / binHz));
	s.loudness.assign(numFrames, -120.f);
	s.tonality.assign(numFrames, 0.f);
	s.timbre.assign(numFrames, {});
	s.chroma.assign(numFrames, {});
	// Pitch class of each FFT bin between 60 Hz and 2 kHz (-1 = unused).
	std::vector<int> pitchClass(kFFTSize / 2, -1);
	for (uint32_t k = 1; k < kFFTSize / 2; ++k) {
		const float hz = k * binHz;
		if (hz >= 60.f && hz <= 2000.f) {
			pitchClass[k] = int(std::lround(12.0 * std::log2(hz / 440.0) + 69.0)) % 12;
		}
	}

	std::vector<float> flux(numFrames, 0.f);
	for (uint32_t f = 0; f < numFrames; ++f) {
		const uint64_t start = uint64_t(f) * s.hop;
		const uint64_t avail = std::min<uint64_t>(kFFTSize, s.frames > start ? s.frames - start : 0);
		std::fill(frame.begin(), frame.end(), 0.f);
		if (avail > 0) {
			vDSP_vmul(mono.data() + start, 1, window.data(), 1, frame.data(), 1, avail);
		}
		DSPSplitComplex split{ re.data(), im.data() };
		vDSP_ctoz(reinterpret_cast<const DSPComplex*>(frame.data()), 2, &split, 1, kFFTSize / 2);
		vDSP_fft_zrip(fft, &split, 1, log2n, FFT_FORWARD);
		split.imagp[0] = 0.f;  // drop Nyquist packed into DC slot
		vDSP_zvabs(&split, 1, mag.data(), 1, kFFTSize / 2);

		float sum = 0.f;
		for (uint32_t k = 1; k < kFFTSize / 2; ++k) {
			const float m = std::log1p(10.f * mag[k]);
			const float d = m - prev[k];
			if (d > 0.f) {
				sum += d;
			}
			prev[k] = m;
		}
		flux[f] = sum;

		float energy = 0.f;
		for (uint32_t k = 1; k < kFFTSize / 2; ++k) {
			energy += mag[k] * mag[k];
		}
		s.loudness[f] = 10.f * std::log10(energy + 1e-12f);
		for (int b = 0; b < Sample::kTimbreBands; ++b) {
			float e = 0.f;
			for (uint32_t k = bandEdges[size_t(b)]; k < std::max(bandEdges[size_t(b) + 1], bandEdges[size_t(b)] + 1); ++k) {
				e += mag[k] * mag[k];
			}
			s.timbre[f][size_t(b)] = std::log10(e + 1e-9f);
		}
		auto& chroma = s.chroma[f];
		for (uint32_t k = 1; k < kFFTSize / 2; ++k) {
			if (pitchClass[k] >= 0) {
				chroma[size_t(pitchClass[k])] += mag[k] * mag[k];
			}
		}
		float norm = 1e-12f;
		for (float v : chroma) {
			norm += v * v;
		}
		norm = std::sqrt(norm);
		for (float& v : chroma) {
			v /= norm;
		}
		// Spectral flatness (geometric / arithmetic mean): ~1 for noise, near 0 for notes and chords.
		double logSum = 0, linSum = 0;
		for (uint32_t k = tonalLo; k <= tonalHi; ++k) {
			const double p = double(mag[k]) * mag[k] + 1e-12;
			logSum += std::log(p);
			linSum += p;
		}
		const double n = tonalHi - tonalLo + 1;
		const double flatness = std::exp(logSum / n) / (linSum / n);
		s.tonality[f] = float(std::clamp(1.0 - flatness, 0.0, 1.0));
	}
	vDSP_destroy_fftsetup(fft);

	// Subtract a local mean (~190 ms) and half-wave rectify.
	const int w = 8;
	std::vector<double> prefix(numFrames + 1, 0.0);
	for (uint32_t i = 0; i < numFrames; ++i) {
		prefix[i + 1] = prefix[i] + flux[i];
	}
	s.novelty.assign(numFrames, 0.f);
	for (int i = 0; i < int(numFrames); ++i) {
		const int a = std::max(0, i - w), b = std::min(int(numFrames), i + w + 1);
		const double mean = (prefix[b] - prefix[a]) / (b - a);
		s.novelty[i] = float(std::max(0.0, flux[i] - mean));
	}

}

void Analyze(Sample& s)
{
	const auto mono = MonoMix(s);
	BuildOverview(s, mono);
	BuildNovelty(s, mono);
}

struct Onset {
	uint32_t frame;  // hop index
	float strength;  // normalized
};

std::vector<Onset> PickOnsets(const Sample& s, uint32_t start, uint32_t end, float sensitivity)
{
	std::vector<Onset> out;
	const auto& n = s.novelty;
	if (n.size() < 3) {
		return out;
	}
	const int fa = int(start / s.hop), fb = std::min<int>(int(n.size()), int(end / s.hop) + 1);
	const int radius = 3;
	std::vector<Onset> peaks;
	for (int i = std::max(1, fa); i < fb - 1; ++i) {
		if (n[i] <= 0.f) {
			continue;
		}
		bool isPeak = true;
		for (int j = std::max(0, i - radius); j <= std::min<int>(int(n.size()) - 1, i + radius); ++j) {
			if (j != i && (n[j] > n[i] || (n[j] == n[i] && j < i))) {
				isPeak = false;
				break;
			}
		}
		if (isPeak) {
			peaks.push_back({ uint32_t(i), n[i] });
		}
	}
	if (peaks.empty()) {
		return out;
	}
	// Measure against the region's own loud hits (95th percentile peak; small wiggles between
	// hits vastly outnumber real hits), then let sensitivity sweep the threshold logarithmically:
	// 0 = only the loudest hits, 1 = hits 50x quieter count too.
	std::vector<float> values;
	for (const auto& p : peaks) {
		values.push_back(p.strength);
	}
	auto p95 = values.begin() + (values.size() * 95) / 100;
	std::nth_element(values.begin(), p95, values.end());
	const float scale = std::max(1e-9f, *p95);
	const float threshold = std::pow(0.02f, std::clamp(sensitivity, 0.f, 1.f));
	for (auto p : peaks) {
		p.strength /= scale;
		if (p.strength >= threshold) {
			out.push_back(p);
		}
	}
	return out;
}

// Turns an onset (hop index) into a click-free sample position just before the attack.
uint32_t RefineOnset(const Sample& s, double approxFrame, uint32_t lowerBound)
{
	// Flux peaks once the new energy is well inside the analysis window.
	const double guess = approxFrame * s.hop + kFFTSize * 0.5;
	const int64_t searchA = std::max<int64_t>(lowerBound, int64_t(guess) - int64_t(kFFTSize));
	const int64_t searchB = std::min<int64_t>(s.frames, int64_t(guess) + int64_t(kFFTSize));
	if (searchB - searchA < 128) {
		return uint32_t(std::clamp<int64_t>(int64_t(guess), lowerBound, s.frames ? s.frames - 1 : 0));
	}

	// Peak-hold envelope over 32-sample blocks (holding ~6 ms so low notes don't ripple), then:
	// find the steepest jump, measure the level just before it, and walk back to where the
	// envelope first climbs clearly above that level.
	constexpr int kBlock = 32, kHold = 8;
	const int numBlocks = int((searchB - searchA) / kBlock);
	std::vector<float> peaks(numBlocks), env(numBlocks);
	for (int b = 0; b < numBlocks; ++b) {
		float p = 0.f;
		for (int k = 0; k < kBlock; ++k) {
			const int64_t i = searchA + b * kBlock + k;
			p = std::max(p, std::abs(0.5f * (s.left[i] + s.right[i])));
		}
		peaks[b] = p;
		env[b] = p;
		for (int j = std::max(0, b - kHold + 1); j < b; ++j) {
			env[b] = std::max(env[b], peaks[j]);
		}
	}
	int rise = 1;
	float best = -1.f;
	for (int b = 1; b < numBlocks; ++b) {
		const float d = env[b] - env[b - 1];
		if (d > best) {
			best = d;
			rise = b;
		}
	}
	float before = env[rise - 1], peak = env[rise];
	for (int b = std::max(0, rise - 10); b < rise; ++b) {
		before = std::min(before, env[b]);
	}
	for (int b = rise; b < std::min(numBlocks, rise + kHold); ++b) {
		peak = std::max(peak, env[b]);
	}
	const float threshold = before + 0.2f * (peak - before);
	int onset = rise;
	while (onset > 0 && env[onset - 1] > threshold) {
		--onset;
	}
	int64_t pos = searchA + int64_t(onset) * kBlock - kBlock;

	// Nearest zero crossing going backwards (bounded) so the slice never starts with a click.
	for (int64_t i = pos; i > std::max<int64_t>(lowerBound + 1, pos - 64); --i) {
		const float a = s.left[i - 1] + s.right[i - 1], b = s.left[i] + s.right[i];
		if ((a <= 0.f && b >= 0.f) || (a >= 0.f && b <= 0.f)) {
			pos = i;
			break;
		}
	}
	return uint32_t(std::clamp<int64_t>(pos, lowerBound, s.frames ? s.frames - 1 : 0));
}

double BeatPeriodFrames(const Sample& s, int fa, int fb)
{
	const auto& n = s.novelty;
	const double frameRate = s.sampleRate / s.hop;
	const int minLag = int(std::floor(60.0 * frameRate / 190.0));
	const int maxLag = int(std::ceil(60.0 * frameRate / 55.0));
	if (fb - fa < maxLag * 3) {
		return 0.0;
	}

	auto ac = [&](int lag) {
		double sum = 0.0;
		for (int i = fa; i + lag < fb; ++i) {
			sum += double(n[i]) * n[i + lag];
		}
		return sum / (fb - fa - lag);
	};

	std::vector<double> score(maxLag * 2 + 2, 0.0);
	for (int lag = minLag; lag <= maxLag * 2 + 1 && fa + lag < fb; ++lag) {
		score[lag] = ac(lag);
	}
	int bestLag = 0;
	double bestScore = 0.0;
	for (int lag = minLag; lag <= maxLag; ++lag) {
		const double bpm = 60.0 * frameRate / lag;
		// Reward lags whose multiples also line up, and lean toward typical soul/hip-hop tempos.
		const double prior = std::exp(-0.5 * std::pow(std::log2(bpm / 100.0) / 0.9, 2.0));
		const double sc = (score[lag] + 0.5 * score[std::min<int>(lag * 2, int(score.size()) - 1)]) * prior;
		if (sc > bestScore) {
			bestScore = sc;
			bestLag = lag;
		}
	}
	if (bestLag == 0) {
		return 0.0;
	}
	// Parabolic interpolation for a fractional lag.
	double lag = bestLag;
	if (bestLag > minLag && bestLag + 1 < int(score.size())) {
		const double a = score[bestLag - 1], b = score[bestLag], c = score[bestLag + 1];
		const double denom = a - 2 * b + c;
		if (std::abs(denom) > 1e-12) {
			lag += std::clamp(0.5 * (a - c) / denom, -0.5, 0.5);
		}
	}
	return lag;
}

// Offset (in hops, from fa) that puts the most onset energy on a grid of the given period.
double BestPhase(const Sample& s, int fa, int fb, double period)
{
	double bestPhase = 0, bestSum = -1;
	for (double phase = 0; phase < period; phase += 0.5) {
		double sum = 0;
		for (double t = fa + phase; t < fb; t += period) {
			const int i = int(std::lround(t));
			if (i >= 0 && i < int(s.novelty.size())) {
				sum += s.novelty[size_t(i)];
			}
		}
		if (sum > bestSum) {
			bestSum = sum;
			bestPhase = phase;
		}
	}
	return bestPhase;
}

double FoldBPM(double bpm)
{
	if (bpm <= 0) {
		return 0;
	}
	while (bpm < 70.0) {
		bpm *= 2.0;
	}
	while (bpm >= 140.0) {
		bpm *= 0.5;
	}
	return bpm;
}

std::vector<uint32_t> Finish(std::vector<uint32_t> starts, uint32_t regionStart)
{
	std::sort(starts.begin(), starts.end());
	starts.erase(std::unique(starts.begin(), starts.end()), starts.end());
	if (starts.empty()) {
		starts.push_back(regionStart);
	}
	if (starts.size() > size_t(kMaxSlices)) {
		starts.resize(kMaxSlices);
	}
	return starts;
}

}  // namespace

Sample* MakeSample(std::vector<float> left, std::vector<float> right, double sampleRate)
{
	auto* s = new Sample;
	s->frames = uint32_t(left.size());
	s->left = std::move(left);
	s->right = right.empty() ? s->left : std::move(right);
	s->sampleRate = sampleRate;
	Analyze(*s);
	return s;
}

Sample* LoadSample(const std::string& path, std::string& error)
{
	CFURLRef url = CFURLCreateFromFileSystemRepresentation(
		nullptr, reinterpret_cast<const UInt8*>(path.c_str()), CFIndex(path.size()), false);
	ExtAudioFileRef file = nullptr;
	OSStatus err = ExtAudioFileOpenURL(url, &file);
	CFRelease(url);
	if (err != noErr) {
		// GarageBand runs plug-ins in a helper process that macOS silently blocks from Downloads,
		// Desktop and Documents. Tell the user where to put the file instead.
		const int fd = open(path.c_str(), O_RDONLY);
		if (fd < 0 && (errno == EPERM || errno == EACCES)) {
			error = "macOS won't let plug-ins read that folder. Use Import to copy the song into Music > Chipmunk Soul";
		} else {
			error = "Can't open that file (is it an audio file?)";
		}
		if (fd >= 0) {
			close(fd);
		}
		return nullptr;
	}

	AudioStreamBasicDescription fileFormat{};
	UInt32 size = sizeof(fileFormat);
	ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat);
	SInt64 fileFrames = 0;
	size = sizeof(fileFrames);
	ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &fileFrames);

	const UInt32 channels = std::clamp<UInt32>(fileFormat.mChannelsPerFrame, 1, 2);
	AudioStreamBasicDescription client{};
	client.mSampleRate = fileFormat.mSampleRate > 0 ? fileFormat.mSampleRate : 44100.0;
	client.mFormatID = kAudioFormatLinearPCM;
	client.mFormatFlags = AudioFormatFlags(kAudioFormatFlagsNativeFloatPacked) | kAudioFormatFlagIsNonInterleaved;
	client.mBitsPerChannel = 32;
	client.mChannelsPerFrame = channels;
	client.mFramesPerPacket = 1;
	client.mBytesPerFrame = client.mBytesPerPacket = sizeof(float);
	err = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client);
	if (err != noErr) {
		ExtAudioFileDispose(file);
		error = "Unsupported audio format";
		return nullptr;
	}

	const uint64_t maxFrames = uint64_t(kMaxSeconds * client.mSampleRate);
	std::vector<float> left, right;
	left.reserve(size_t(std::min<uint64_t>(std::max<SInt64>(fileFrames, 0), maxFrames)));
	right.reserve(left.capacity());

	constexpr UInt32 kChunk = 32768;
	std::vector<float> bufL(kChunk), bufR(kChunk);
	alignas(AudioBufferList) uint8_t ablStorage[sizeof(AudioBufferList) + sizeof(AudioBuffer)];
	auto* abl = reinterpret_cast<AudioBufferList*>(ablStorage);
	while (left.size() < maxFrames) {
		abl->mNumberBuffers = channels;
		abl->mBuffers[0] = { 1, kChunk * sizeof(float), bufL.data() };
		if (channels == 2) {
			abl->mBuffers[1] = { 1, kChunk * sizeof(float), bufR.data() };
		}
		UInt32 frames = kChunk;
		err = ExtAudioFileRead(file, &frames, abl);
		if (err != noErr) {
			ExtAudioFileDispose(file);
			error = "Error while decoding the file";
			return nullptr;
		}
		if (frames == 0) {
			break;
		}
		left.insert(left.end(), bufL.begin(), bufL.begin() + frames);
		const auto& r = channels == 2 ? bufR : bufL;
		right.insert(right.end(), r.begin(), r.begin() + frames);
	}
	ExtAudioFileDispose(file);

	if (left.size() < 64) {
		error = "That file is empty";
		return nullptr;
	}

	auto* s = MakeSample(std::move(left), std::move(right), client.mSampleRate);
	s->path = path;
	s->voices = DetectVoiceActivity(path);
	const auto slash = path.find_last_of('/');
	s->name = slash == std::string::npos ? path : path.substr(slash + 1);
	return s;
}

double EstimateBPM(const Sample& s, uint32_t start, uint32_t end)
{
	end = end == 0 ? s.frames : std::min(end, s.frames);
	const int fa = int(start / s.hop), fb = std::min<int>(int(s.novelty.size()), int(end / s.hop));
	const double lag = BeatPeriodFrames(s, fa, fb);
	return lag > 0 ? FoldBPM(60.0 * s.sampleRate / (lag * s.hop)) : 0.0;
}

std::vector<Section> FindBestSections(const Sample& s, int beats, int maxResults)
{
	std::vector<Section> out;
	const int numHops = int(s.novelty.size());
	if (numHops < 64) {
		return out;
	}
	// Beat grid across the whole song (or ~0.63 s steps if there's no steady beat).
	double bpm = EstimateBPM(s, 0, 0);
	if (bpm <= 0) {
		bpm = 95;
	}
	const double period = 60.0 * s.sampleRate / (bpm * s.hop);
	std::vector<int> grid;
	for (double t = BestPhase(s, 0, numHops, period); t < numHops; t += period) {
		grid.push_back(int(std::lround(t)));
	}
	const int numBeats = int(grid.size()) - 1;
	beats = std::clamp(beats, 2, 32);
	if (numBeats < beats) {
		return out;
	}

	// Describe each beat: loudness, tonality, timbre, and how much of its onset energy is on the beat.
	struct Beat {
		float db, tonal, onBeat, total, singing, drums;
		std::array<float, Sample::kTimbreBands> timbre;
		std::array<float, 12> chroma;
	};
	const bool haveVoices = s.voices.step > 0;
	// Each classifier value describes a 2 s window starting at index * step, so read the window
	// centred on the requested time.
	auto voiceAt = [&](const std::vector<float>& v, double seconds) {
		const size_t k = size_t(std::clamp(std::round((seconds - 1.0) / s.voices.step), 0.0, double(v.size() - 1)));
		return v[k];
	};
	std::vector<Beat> b(static_cast<size_t>(numBeats));
	for (int i = 0; i < numBeats; ++i) {
		Beat& x = b[size_t(i)];
		x = {};
		const int a = grid[size_t(i)], e = std::max(a + 1, grid[size_t(i) + 1]);
		double db = 0;
		for (int h = a; h < e; ++h) {
			db += s.loudness[size_t(h)];
			x.tonal += s.tonality[size_t(h)];
			x.total += s.novelty[size_t(h)];
			for (int k = 0; k < Sample::kTimbreBands; ++k) {
				x.timbre[size_t(k)] += s.timbre[size_t(h)][size_t(k)];
			}
			for (int k = 0; k < 12; ++k) {
				x.chroma[size_t(k)] += s.chroma[size_t(h)][size_t(k)];
			}
			if (std::abs(h - a) <= 2) {
				x.onBeat = std::max(x.onBeat, s.novelty[size_t(h)]);
			}
		}
		const float n = float(e - a);
		x.db = float(db / n);
		x.tonal /= n;
		for (auto& v : x.timbre) {
			v /= n;
		}
		if (haveVoices) {
			const double mid = (a + e) * 0.5 * s.hop / s.sampleRate;
			x.singing = voiceAt(s.voices.singing, mid);
			x.drums = voiceAt(s.voices.drums, mid);
		}
	}

	// Bar lines: chords tend to change on the downbeat, so pick the beat-in-bar (of 4) where the
	// pitch content changes most. Many songs change chords every two beats, which makes beat 1 and
	// beat 3 indistinguishable, so loops may start on any half-bar line.
	int downbeat = 0;
	{
		double change[4] = { 0, 0, 0, 0 };
		for (int i = 1; i < numBeats; ++i) {
			double dot = 0, na = 1e-9, nb = 1e-9;
			for (int k = 0; k < 12; ++k) {
				dot += b[size_t(i)].chroma[size_t(k)] * b[size_t(i - 1)].chroma[size_t(k)];
				na += b[size_t(i)].chroma[size_t(k)] * b[size_t(i)].chroma[size_t(k)];
				nb += b[size_t(i - 1)].chroma[size_t(k)] * b[size_t(i - 1)].chroma[size_t(k)];
			}
			change[i % 4] += 1.0 - dot / std::sqrt(na * nb);
		}
		downbeat = int(std::max_element(std::begin(change), std::end(change)) - std::begin(change));
	}
	const int halfBarPhase = downbeat % 2;
	auto barStartAtOrBefore = [&](int beat) { return std::max(0, beat - ((beat - halfBarPhase) % 2 + 2) % 2); };

	// Hooks repeat. Compare every two-bar phrase with every other one by its chords and melody
	// (pitch classes, with the song's overall key removed so only the movement counts).
	std::array<float, 12> keyProfile{};
	for (const auto& x : b) {
		for (int k = 0; k < 12; ++k) {
			keyProfile[size_t(k)] += x.chroma[size_t(k)] / numBeats;
		}
	}
	for (auto& x : b) {
		float norm = 1e-9f;
		for (int k = 0; k < 12; ++k) {
			x.chroma[size_t(k)] -= keyProfile[size_t(k)];
			norm += x.chroma[size_t(k)] * x.chroma[size_t(k)];
		}
		for (auto& v : x.chroma) {
			v /= std::sqrt(norm);
		}
	}
	// How exactly does the section starting at beat i recur elsewhere (aligned, same length)?
	// The hook is the phrase with the closest repeat; its partner is where it comes back.
	auto similarity = [&](int i, int j) {
		double sim = 0;
		for (int k = 0; k < beats; ++k) {
			for (int p = 0; p < 12; ++p) {
				sim += b[size_t(i + k)].chroma[size_t(p)] * b[size_t(j + k)].chroma[size_t(p)];
			}
		}
		return sim / beats;
	};
	std::vector<double> repetition(size_t(numBeats), 0.0);
	for (int i = 0; i + beats <= numBeats; ++i) {
		for (int j = 0; j + beats <= numBeats; ++j) {
			if (std::abs(i - j) >= beats) {
				repetition[size_t(i)] = std::max(repetition[size_t(i)], similarity(i, j));
			}
		}
	}

	// The first time the voice comes in is a classic chop: the hook, before the band fills in.
	// Find where clear singing starts, walk back to where it first rises, and start that bar.
	int vocalEntry = -1;
	for (int i = 0; haveVoices && i + 2 < numBeats && vocalEntry < 0; ++i) {
		if (b[size_t(i)].singing > 0.45f && b[size_t(i + 1)].singing > 0.45f && b[size_t(i + 2)].singing > 0.45f) {
			vocalEntry = i;
		}
	}
	if (vocalEntry >= 0) {
		while (vocalEntry > 0 && b[size_t(vocalEntry - 1)].singing > 0.15f) {
			--vocalEntry;
		}
		// Start a half-bar early so the singer's pickup into the phrase is kept.
		vocalEntry = barStartAtOrBefore(std::max(0, vocalEntry - 1));
	}

	// Song-wide references so scores are relative to this record.
	std::vector<float> dbs;
	std::array<float, Sample::kTimbreBands> songMean{};
	for (const auto& x : b) {
		dbs.push_back(x.db);
		for (int k = 0; k < Sample::kTimbreBands; ++k) {
			songMean[size_t(k)] += x.timbre[size_t(k)] / numBeats;
		}
	}
	auto p90 = dbs.begin() + (dbs.size() * 9) / 10;
	std::nth_element(dbs.begin(), p90, dbs.end());
	const float loudRef = *p90;
	auto distance = [](const std::array<float, Sample::kTimbreBands>& u, const std::array<float, Sample::kTimbreBands>& v) {
		float d = 0;
		for (int k = 0; k < Sample::kTimbreBands; ++k) {
			d += (u[size_t(k)] - v[size_t(k)]) * (u[size_t(k)] - v[size_t(k)]);
		}
		return std::sqrt(d);
	};
	float songSpread = 1e-6f;
	for (const auto& x : b) {
		songSpread += distance(x.timbre, songMean) / numBeats;
	}

	// Average of a window, blended with the average of its worst quarter, so a few dead or noisy
	// beats sink the whole window instead of being averaged away.
	auto robust = [](std::vector<double>& v) {
		std::sort(v.begin(), v.end());
		const size_t q = std::max<size_t>(1, v.size() / 4);
		double all = 0, worst = 0;
		for (size_t k = 0; k < v.size(); ++k) {
			all += v[k];
			worst += k < q ? v[k] : 0;
		}
		return 0.5 * all / v.size() + 0.5 * worst / q;
	};

	std::vector<Section> candidates;
	std::vector<int> candidateBeat;
	std::vector<double> louds, tonals, sung;
	for (int i = 0; i + beats <= numBeats; ++i) {
		double onBeat = 0, total = 1e-9, drums = 0, repeated = 0;
		louds.clear();
		tonals.clear();
		sung.clear();
		std::array<float, Sample::kTimbreBands> mean{};
		for (int j = i; j < i + beats; ++j) {
			const Beat& x = b[size_t(j)];
			// Full marks within 6 dB of the loud parts, nothing 24 dB down (intros, fades, gaps).
			louds.push_back(std::clamp((x.db - (loudRef - 24.f)) / 18.f, 0.f, 1.f));
			// Flatness of real mixes rarely gets below ~0.3, so stretch 0.35..0.85 tonality over 0..1.
			tonals.push_back(std::clamp((x.tonal - 0.35) / 0.5, 0.0, 1.0));
			onBeat += x.onBeat;
			total += x.total;
			sung.push_back(x.singing);
			drums += x.drums / beats;
			for (int k = 0; k < Sample::kTimbreBands; ++k) {
				mean[size_t(k)] += x.timbre[size_t(k)] / beats;
			}
		}
		// 0.3 = ordinary similarity within one song, 0.7+ = the same phrase sung again.
		repeated = std::clamp((repetition[size_t(i)] - 0.3) / 0.4, 0.0, 1.0);
		double spread = 0;
		for (int j = i; j < i + beats; ++j) {
			spread += distance(b[size_t(j)].timbre, mean) / beats;
		}
		const double loud = robust(louds);
		const double tonalScore = robust(tonals);
		const double variety = std::clamp(spread / songSpread / 1.5, 0.0, 1.0);
		const double punch = std::clamp(onBeat / total * 4.0, 0.0, 1.0);
		double score;
		if (haveVoices) {
			// What producers chop: sung, repeated phrases over light drums, cleanly started.
			const double vocal = robust(sung);
			const double entry = i == vocalEntry ? 1.0 : 0.0;
			// A sung loop doesn't need its own drum hits (the producer adds drums), so light drums
			// replace punch here.
			score = loud * (0.4 * vocal + 0.3 * repeated + 0.15 * tonalScore + 0.15 * (1.0 - drums)) + 0.15 * entry;
		} else {
			score = loud * (0.4 * tonalScore + 0.2 * variety + 0.2 * punch + 0.2 * repeated);
		}
		const uint32_t start = uint32_t(std::min<int64_t>(int64_t(grid[size_t(i)]) * s.hop, s.frames - 1));
		const uint32_t end = uint32_t(std::min<int64_t>(int64_t(grid[size_t(i + beats)]) * s.hop, s.frames));
		candidates.push_back({ start, end, score });
		candidateBeat.push_back(i);
	}

	// The hook first: the most exactly repeated loud, sung phrase, with every occurrence, earliest
	// first (the first time through is usually the cleanest). Producers sample the hook. Searched at
	// every beat rather than on the bar grid, because live records drift against a fixed grid.
	std::vector<Section> hook;
	{
		int h = -1;
		for (int i = 0; i + beats <= numBeats; ++i) {
			const Beat& mid = b[size_t(i + beats / 2)];
			const bool usable = mid.db > loudRef - 12.f && (!haveVoices || mid.singing > 0.3f);
			if (usable && repetition[size_t(i)] > 0.6 && (h < 0 || repetition[size_t(i)] > repetition[size_t(h)])) {
				h = i;
			}
		}
		std::vector<int> occurrences;
		if (h >= 0) {
			std::vector<std::pair<double, int>> matches;
			for (int k = 0; k + beats <= numBeats; ++k) {
				const double sim = k == h ? 1.0 : similarity(k, h);
				if (sim > 0.6) {
					matches.push_back({ sim, k });
				}
			}
			std::sort(matches.rbegin(), matches.rend());
			for (const auto& [sim, k] : matches) {
				if (std::none_of(occurrences.begin(), occurrences.end(), [&](int o) { return std::abs(o - k) < beats; })) {
					occurrences.push_back(k);
				}
			}
			std::sort(occurrences.begin(), occurrences.end());
		}
		if (!occurrences.empty()) {
			// Where does the phrase really start? At the vocal entry if the first occurrence is where
			// the voice comes in, otherwise on the nearest half-bar line. Later occurrences keep the
			// same alignment.
			const int first = occurrences.front();
			int shift;
			if (vocalEntry >= 0 && std::abs(vocalEntry - first) <= 4) {
				shift = vocalEntry - first;
			} else {
				shift = barStartAtOrBefore(first + 1) - first;
			}
			for (int k : occurrences) {
				const int i = std::clamp(k + shift, 0, numBeats - beats);
				const uint32_t start = uint32_t(std::min<int64_t>(int64_t(grid[size_t(i)]) * s.hop, s.frames - 1));
				const uint32_t end = uint32_t(std::min<int64_t>(int64_t(grid[size_t(i + beats)]) * s.hop, s.frames));
				hook.push_back({ start, end, 2.0 });
			}
		}
	}

	// Best first, skipping anything that overlaps a better pick by more than a quarter.
	std::sort(candidates.begin(), candidates.end(), [](const Section& x, const Section& y) { return x.score > y.score; });
	candidates.insert(candidates.begin(), hook.begin(), hook.end());
	for (const auto& c : candidates) {
		if (int(out.size()) >= maxResults) {
			break;
		}
		const double len = double(c.end - c.start);
		const bool overlaps = std::any_of(out.begin(), out.end(), [&](const Section& o) {
			const double overlap = double(std::min(c.end, o.end)) - double(std::max(c.start, o.start));
			return overlap > 0.25 * len;
		});
		if (!overlaps) {
			out.push_back(c);
		}
	}
	// Start each pick right on its downbeat hit rather than on the grid estimate.
	for (auto& o : out) {
		const uint32_t len = o.end - o.start;
		const auto hits = PickOnsets(s, o.start > s.hop * 8 ? o.start - s.hop * 8 : 0, o.start + s.hop * 8, 0.8f);
		double frame = double(o.start) / s.hop;
		float strongest = 0;
		for (const auto& h : hits) {
			if (h.strength > strongest) {
				strongest = h.strength;
				frame = h.frame;
			}
		}
		o.start = RefineOnset(s, frame, 0);
		o.end = std::min(s.frames, o.start + len);
	}
	return out;
}

std::vector<uint32_t> Chop(const Sample& s, const ChopSettings& cs, double* outBPM)
{
	const uint32_t regionStart = std::min(cs.regionStart, s.frames ? s.frames - 1 : 0);
	const uint32_t regionEnd =
		cs.regionEnd == 0 || cs.regionEnd > s.frames ? s.frames : std::max(cs.regionEnd, regionStart + 1);
	const int count = std::clamp(cs.count, 1, kMaxSlices);
	const double length = double(regionEnd - regionStart);

	double bpm = EstimateBPM(s, regionStart, regionEnd);
	if (outBPM) {
		*outBPM = bpm;
	}

	std::vector<uint32_t> starts;

	if (cs.mode == kChop_Even || s.novelty.size() < 8) {
		for (int i = 0; i < count; ++i) {
			starts.push_back(regionStart + uint32_t(length * i / count));
		}
		return Finish(starts, regionStart);
	}

	if (cs.mode == kChop_Beats && bpm > 0) {
		// Snap to any hit near the beat, however quiet; sensitivity only applies to Transients.
		const auto onsets = PickOnsets(s, regionStart, regionEnd, 0.8f);
		const int fa = int(regionStart / s.hop), fb = std::min<int>(int(s.novelty.size()), int(regionEnd / s.hop));
		const double period = 60.0 * s.sampleRate / (bpm * s.hop);
		const double bestPhase = BestPhase(s, fa, fb, period);
		const double snapRadius = 0.035 * s.sampleRate / s.hop;
		uint32_t lowerBound = regionStart;
		for (double t = fa + bestPhase; t < fb && int(starts.size()) < count; t += period) {
			// Snap to a nearby real onset so the chop lands on the hit, not the math.
			double frame = t;
			float strongest = 0.f;
			for (const auto& o : onsets) {
				if (std::abs(double(o.frame) - t) <= snapRadius && o.strength > strongest) {
					strongest = o.strength;
					frame = o.frame;
				}
			}
			const uint32_t pos = RefineOnset(s, frame, lowerBound);
			if (pos >= regionEnd) {
				break;
			}
			starts.push_back(pos);
			lowerBound = pos + 1;
		}
		if (!starts.empty() && starts.front() - regionStart < uint32_t(0.25 * period * s.hop)) {
			starts.front() = regionStart;  // don't leave a sliver of audio before the first hit
		}
		return Finish(starts, regionStart);
	}

	// Transient mode: sensitivity sets the chop density relative to the tempo (50% = about one chop
	// per beat, 0% = one per ~3 beats, 100% = ~3 per beat); the strongest hits win. A fixed floor
	// keeps the small wiggles between hits from ever counting as hits.
	auto onsets = PickOnsets(s, regionStart, regionEnd, 0.75f);
	const double beatsInRegion = length / s.sampleRate * (bpm > 0 ? bpm : 120.0) / 60.0;
	const size_t target = size_t(std::max(1.0, std::round(beatsInRegion * std::exp2(3.0 * std::clamp(cs.sensitivity, 0.f, 1.f) - 1.5))));
	if (onsets.size() > target) {
		std::sort(onsets.begin(), onsets.end(), [](const Onset& a, const Onset& b) { return a.strength > b.strength; });
		onsets.resize(target);
		std::sort(onsets.begin(), onsets.end(), [](const Onset& a, const Onset& b) { return a.frame < b.frame; });
	}

	const double minGap = 0.08 * s.sampleRate;
	uint32_t first = regionStart;
	for (const auto& o : onsets) {
		const uint32_t p = RefineOnset(s, o.frame, regionStart);
		if (p >= regionStart && p - regionStart < 0.12 * s.sampleRate) {
			first = p;
			break;
		}
		if (p > regionStart) {
			break;
		}
	}
	starts.push_back(first);
	for (const auto& o : onsets) {
		if (int(starts.size()) >= kMaxSlices) {
			break;
		}
		const uint32_t p = RefineOnset(s, o.frame, starts.back() + 1);
		if (p >= regionEnd) {
			break;
		}
		if (p >= starts.back() + minGap) {
			starts.push_back(p);
		}
	}
	// No transients at all (e.g. a smooth string pad)? Fall back to even slices.
	if (starts.size() == 1 && count > 1) {
		for (int i = 1; i < count; ++i) {
			starts.push_back(regionStart + uint32_t(length * i / count));
		}
	}
	return Finish(starts, regionStart);
}

}  // namespace cs
