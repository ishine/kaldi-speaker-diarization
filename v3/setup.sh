#!/bin/bash

. path.sh

echo Setting up symlinks
ln -sfn ../../wsj/s5/steps steps
ln -sfn ../../wsj/s5/utils utils
ln -sfn ../../callhome_diarization/v1/diarization diarization
ln -sfn ../../callhome_diarization/v1/local/ local
ln -sfn ../../sre08/v1/sid/ sid

echo "Make logs dir"
mkdir -p logs

echo Done
