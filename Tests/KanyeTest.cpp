// "Does it sample like Kanye?" For each spot in kanye_references.tsv, the best-part search must
// offer a section starting there (within 1.5 s) among its first three ideas.
#include "Analysis.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

using namespace cs;

namespace {

constexpr int kTopIdeas = 3;
constexpr double kToleranceSeconds = 1.5;

double ParseTime(const std::string& t)
{
	const auto colon = t.find(':');
	return colon == std::string::npos ? std::stod(t) : std::stod(t.substr(0, colon)) * 60 + std::stod(t.substr(colon + 1));
}

std::string Clock(double t)
{
	char buf[16];
	snprintf(buf, sizeof(buf), "%d:%04.1f", int(t) / 60, std::fmod(t, 60.0));
	return buf;
}

}  // namespace

int main(int argc, char** argv)
{
	const std::string table = argc > 1 ? argv[1] : "Tests/kanye_references.tsv";
	const std::string folder = std::string(getenv("HOME")) + "/Music/Chipmunk Soul/";
	std::ifstream in(table);
	if (!in) {
		printf("can't read %s\n", table.c_str());
		return 1;
	}

	std::map<std::string, std::unique_ptr<Sample>> songs;
	int checked = 0, failures = 0, skipped = 0;
	std::string line;
	while (std::getline(in, line)) {
		if (line.empty() || line[0] == '#') {
			continue;
		}
		std::vector<std::string> cols;
		std::stringstream ss(line);
		for (std::string col; std::getline(ss, col, '\t');) {
			cols.push_back(col);
		}
		if (cols.size() < 3) {
			continue;
		}
		const std::string path = cols[0][0] == '/' ? cols[0] : folder + cols[0];
		auto& song = songs[path];
		if (!song) {
			std::string error;
			song.reset(LoadSample(path, error));
			if (!song) {
				printf("SKIP  %s (%s)\n", cols[0].c_str(), error.c_str());
				++skipped;
				continue;
			}
		}
		const double want = ParseTime(cols[1]);
		const auto ideas = FindBestSections(*song, 16, 8);  // the plug-in's default: 4 bars, 8 ideas
		int rank = -1;
		for (size_t i = 0; i < ideas.size() && rank < 0; ++i) {
			if (std::abs(ideas[i].start / song->sampleRate - want) <= kToleranceSeconds) {
				rank = int(i) + 1;
			}
		}
		const bool ok = rank >= 1 && rank <= kTopIdeas;
		failures += !ok;
		++checked;
		std::string list;
		for (size_t i = 0; i < ideas.size(); ++i) {
			list += (i ? ", " : "") + Clock(ideas[i].start / song->sampleRate);
		}
		printf("%s  %s @ %s: %s  (ideas: %s)\n", ok ? "PASS" : "FAIL", cols[2].c_str(), cols[1].c_str(),
			rank > 0 ? ("idea #" + std::to_string(rank)).c_str() : "not offered", list.c_str());
	}
	printf("\n%d of %d Kanye spots found in the top %d ideas", checked - failures, checked, kTopIdeas);
	printf(skipped ? " (%d songs not on this Mac)\n" : "\n", skipped);
	return failures;
}
