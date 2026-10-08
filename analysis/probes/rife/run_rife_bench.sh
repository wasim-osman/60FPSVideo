#!/bin/bash
# RIFE (ncnn + Vulkan/MoltenVK) throughput, matched to the VTFrameProcessor probes.
# Loads SVP's own libRIFE.dylib into the system VapourSynth install.
cd "$(dirname "$0")" || exit 1
PY=/opt/homebrew/bin/python3
echo "==================================================================="
echo " RIFE vs VTFrameProcessor -- 24 -> 60 fps  |  $(date '+%Y-%m-%d %H:%M')"
echo " host: $(sysctl -n machdep.cpu.brand_string) | macOS $(sw_vers -productVersion)"
echo " RIFE plugin : SVP 4 Mac  Contents/Resources/rife/libRIFE.dylib (universal)"
echo " VapourSynth : $(/opt/homebrew/bin/vspipe --version 2>/dev/null | head -1)"
echo " Vulkan      : $(ls /opt/homebrew/lib/libvulkan.1.dylib 2>/dev/null && echo present)"
echo "==================================================================="
echo ""
echo "--- model comparison @ 1920x1080 ---"
for m in rife-v4 models/rife-v4.6 models/rife-v4.16lite; do
  printf "  %-22s " "$m"
  $PY bench_rife.py 1920 1080 24 60 100 "$m" 2>/dev/null | grep RESULT | sed 's/RESULT RIFE //'
done
echo ""
echo "--- resolution scaling, rife-v4 ---"
for res in "640 360" "1280 720" "1920 1080"; do
  printf "  %-10s " "${res// /x}"
  $PY bench_rife.py $res 24 60 100 rife-v4 2>/dev/null | grep RESULT | sed 's/RESULT RIFE //'
done
printf "  %-10s " "3840x2160"
$PY bench_rife.py 3840 2160 24 60 40 rife-v4 2>/dev/null | grep RESULT | sed 's/RESULT RIFE //'
echo ""
echo "--- gpu_thread scaling @ 1920x1080 (RIFE's own multi-queue) ---"
for gt in 1 2 3; do
  printf "  gpu_thread=%s  " "$gt"
  GPU_THREAD=$gt $PY bench_rife.py 1920 1080 24 60 100 rife-v4 2>/dev/null | grep RESULT | sed 's/RESULT RIFE //'
done
echo ""
echo "--- concurrency scaling @ 1920x1080 (separate processes, rife-v4) ---"
for n in 1 2 4; do
  echo "  -- $n process(es) --"
  for i in $(seq 1 $n); do
    ( $PY bench_rife.py 1920 1080 24 60 100 rife-v4 2>/dev/null | grep RESULT | sed 's/RESULT RIFE //' ) &
  done
  wait
done
echo ""
echo "==================================================================="
