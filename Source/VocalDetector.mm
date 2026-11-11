#import <Foundation/Foundation.h>
#import <SoundAnalysis/SoundAnalysis.h>

#include "VocalDetector.h"

#include <algorithm>
#include <cmath>

// Collects one row per classifier window. Prefixed so it can't collide with other plug-ins' classes.
@interface ChipmunkSoulVoiceObserver_v1 : NSObject <SNResultsObserving>
@property (nonatomic) cs::VoiceActivity* activity;
@end

@implementation ChipmunkSoulVoiceObserver_v1
- (void)request:(id<SNRequest>)request didProduceResult:(id<SNResult>)result
{
	auto* r = (SNClassificationResult*)result;
	auto confidence = [&](NSArray<NSString*>* labels) {
		double best = 0;
		for (NSString* label in labels) {
			best = std::max(best, [r classificationForIdentifier:label].confidence);
		}
		return float(best);
	};
	const size_t index = size_t(std::lround(CMTimeGetSeconds(r.timeRange.start) / _activity->step));
	if (_activity->singing.size() <= index) {
		_activity->singing.resize(index + 1, 0.f);
		_activity->drums.resize(index + 1, 0.f);
	}
	_activity->singing[index] = confidence(@[ @"singing", @"choir", @"male_singing", @"female_singing", @"child_singing", @"humming" ]);
	_activity->drums[index] = confidence(@[ @"drum_kit", @"drum", @"snare_drum", @"bass_drum", @"cymbal", @"hi_hat" ]);
}
@end

namespace cs {

VoiceActivity DetectVoiceActivity(const std::string& path)
{
	VoiceActivity activity;
	@autoreleasepool {
		NSError* error = nil;
		SNClassifySoundRequest* request = [[SNClassifySoundRequest alloc] initWithClassifierIdentifier:SNClassifierIdentifierVersion1
																								 error:&error];
		NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
		SNAudioFileAnalyzer* analyzer = request ? [[SNAudioFileAnalyzer alloc] initWithURL:url error:&error] : nil;
		if (!analyzer) {
			return activity;
		}
		// 2-second windows every second.
		request.windowDuration = CMTimeMakeWithSeconds(2.0, 44100);
		request.overlapFactor = 0.5;
		activity.step = 1.0;
		ChipmunkSoulVoiceObserver_v1* observer = [ChipmunkSoulVoiceObserver_v1 new];
		observer.activity = &activity;
		if (![analyzer addRequest:request withObserver:observer error:&error]) {
			return {};
		}
		[analyzer analyze];
	}
	if (activity.singing.empty()) {
		activity.step = 0;
	}
	return activity;
}

}  // namespace cs
