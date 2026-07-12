#!/bin/sh
# Blocks until dl + transcribe workers are all gone, then prints final stats.
# Run as a FILE (sh wait_done.sh) so its argv doesn't contain the grep patterns.
cd /Users/dmitryschab/Documents/projects/tiktok-brain/pipeline-lab
while pgrep -f "run.py dl --shard" >/dev/null 2>&1; do sleep 20; done
sleep 25   # let orchestrator launch transcribe
while pgrep -f "run.py transcribe --shard" >/dev/null 2>&1; do sleep 30; done
echo "=== PIPELINE COMPLETE ==="
echo "wavs        : $(ls full/media/*.wav 2>/dev/null | wc -l)"
echo "transcripts : $(ls full/transcripts/*.txt 2>/dev/null | wc -l)"
echo "null (music): $(ls full/transcripts/*.null 2>/dev/null | wc -l)"
for s in 0 1 2; do echo "tr shard $s: $(tail -1 full/tr_$s.log 2>/dev/null)"; done
