#!/bin/sh
cd /Users/dmitryschab/Documents/projects/tiktok-brain/pipeline-lab
# wait for all dl shards to exit
while pgrep -f "run.py dl" >/dev/null 2>&1; do sleep 15; done
echo "$(date +%H:%M:%S) downloads done: $(ls full/media/*.wav 2>/dev/null | wc -l) wavs" >> full/orchestrate.log
# launch 3 transcribe shards
for s in 0 1 2; do
  nohup ./.venv/bin/python full/run.py transcribe --shard $s/3 > full/tr_$s.log 2>&1 &
done
echo "$(date +%H:%M:%S) transcribe shards launched" >> full/orchestrate.log
