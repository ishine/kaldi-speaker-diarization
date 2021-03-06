#!/usr/bin/env bash
# Copyright   2017   Johns Hopkins University (Author: Daniel Garcia-Romero)
#             2017   Johns Hopkins University (Author: Daniel Povey)
#        2017-2018   David Snyder
#             2018   Ewald Enzinger
#             2018   Zili Huang
# Apache 2.0.
#
# See ../README.txt for more info on data required.
# Results (diarization error rate) are inline in comments below.
#SBATCH --output=logs/run_%J.out
#SBATCH -c 5

. ./cmd.sh
. ./path.sh
set -e
mfccdir=`pwd`/mfcc
vaddir=`pwd`/mfcc

voxceleb1_root=/data/voxceleb/VoxCeleb1
num_components=2048
ivector_dim=400
ivec_dir=exp/extractor_c${num_components}_i${ivector_dim}


stage=4

if [ $stage -le 0 ]; then
  # Now prepare the VoxCeleb1 train and test data.  If you downloaded the corpus soon
  # after it was first released, you may need to use an older version of the script, which
  # can be invoked as follows:
  # local/make_voxceleb1.pl $voxceleb1_root data
  local/make_voxceleb1_v2.pl $voxceleb1_root dev data/voxceleb1_train

  utils/combine_data.sh data/train data/voxceleb1_train
fi

if [ $stage -le 1 ]; then
  # Make MFCCs for each dataset
  for name in train; do
    steps/make_mfcc.sh --write-utt2num-frames true \
      --mfcc-config conf/mfcc.conf --nj 20 --cmd "$train_cmd --max-jobs-run 20" \
      data/${name} exp/make_mfcc $mfccdir
    utils/fix_data_dir.sh data/${name}
  done
fi
if [ $stage -le 2 ]; then

  # Compute the energy-based VAD for train
  sid/compute_vad_decision.sh --nj 20 --cmd "$train_cmd" \
    data/train exp/make_vad $vaddir
  utils/fix_data_dir.sh data/train

  # This writes features to disk after adding deltas and applying the sliding window CMN.
  # Although this is somewhat wasteful in terms of disk space, for diarization
  # it ends up being preferable to performing the CMN in memory.  If the CMN
  # were performed in memory it would need to be performed after the subsegmentation,
  # which leads to poorer results.
  for name in train; do
    local/prepare_feats.sh --nj 20 --cmd "$train_cmd" \
      data/$name data/${name}_cmn exp/${name}_cmn
    if [ -f data/$name/vad.scp ]; then
      cp data/$name/vad.scp data/${name}_cmn/
    fi
    if [ -f data/$name/segments ]; then
      cp data/$name/segments data/${name}_cmn/
    fi
    utils/fix_data_dir.sh data/${name}_cmn
  done

  echo "0.01" > data/train_cmn/frame_shift
  # Create segments to extract i-vectors from for PLDA training data.
  # The segments are created using an energy-based speech activity
  # detection (SAD) system, but this is not necessary.  You can replace
  # this with segments computed from your favorite SAD.
  diarization/vad_to_segments.sh --nj 20 --cmd "$train_cmd" \
      data/train_cmn data/train_cmn_segmented
fi
if [ $stage -le 3 ]; then
  # Train the UBM on VoxCeleb 1
  # UBM - Universal Background Model
  sid/train_diag_ubm.sh --cmd "$train_cmd --mem 4G" \
    --nj 40 --num-threads 8 \
    data/train $num_components \
    exp/diag_ubm

  sid/train_full_ubm.sh --cmd "$train_cmd --mem 25G" \
    --nj 40 --remove-low-count-gaussians false \
    data/train \
    exp/diag_ubm exp/full_ubm
fi

if [ $stage -le 4 ]; then
  # In this stage, we train the i-vector extractor on a subset of VoxCeleb 1
  #
  # Note that there are well over 1 million utterances in our training set,
  # and it takes an extremely long time to train the extractor on all of this.
  # Also, most of those utterances are very short.  Short utterances are
  # harmful for training the i-vector extractor.  Therefore, to reduce the
  # training time and improve performance, we will only train on the 100k
  # longest utterances.
  # they trained on 100k, we're training on 5k so 5% of the data they had
  utils/subset_data_dir.sh \
    --utt-list <(sort -n -k 2 data/train/utt2num_frames | tail -n 5000) \
    data/train data/train_5k

  # Train the i-vector extractor.
  sid/train_ivector_extractor.sh --cmd "$train_cmd --mem 3G" \
    --ivector-dim $ivector_dim --num-iters 5 \
    exp/full_ubm/final.ubm data/train_5k \
    $ivec_dir
fi
