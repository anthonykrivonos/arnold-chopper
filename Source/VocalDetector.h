// Uses macOS's built-in sound classifier (SoundAnalysis) to find where a song has singing and
// where it has drums. Producers chop sung phrases, ideally over light drums.
#pragma once

#include <string>
#include <vector>

namespace cs {

struct VoiceActivity {
	double step = 0;              // seconds between values; 0 if unavailable
	std::vector<float> singing;   // 0..1 per step
	std::vector<float> drums;     // 0..1 per step
};

// Blocks while analyzing (about 0.5 s for a 3-minute song). Empty result if the classifier is
// unavailable or the file can't be read.
VoiceActivity DetectVoiceActivity(const std::string& path);

}  // namespace cs
