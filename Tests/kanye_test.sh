#!/bin/bash
# Does the best-part search pick what Kanye picked? See Tests/kanye_references.tsv.
cd "$(dirname "$0")/.." && clang++ -std=c++23 -fobjc-arc -O2 -ISource Tests/KanyeTest.cpp Source/Analysis.cpp Source/VocalDetector.mm \
  -framework AudioToolbox -framework Accelerate -framework CoreFoundation -framework Foundation -framework SoundAnalysis -framework CoreMedia \
  -o build/KanyeTest && build/KanyeTest
