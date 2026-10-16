# MDX Core ML GPU path — October 16, 2026

Local build 1.6.1 (25) prefers ONNX Runtime's CoreMLExecutionProvider for MDX
preparation, configured with MLProgram and CPUAndGPU compute units. Inst_HQ_5's
symbolic batch dimension is fixed to one so Core ML can capture its complete
graph. The CPU audio transforms and overlap reconstruction remain unchanged.
Becruily keeps its existing PyTorch Metal/CPU path.

Converted models live in Application Support/CoverFlow/Karaoke/ModelCache/MDX,
under a SHA-256 identity including complete weight bytes, UVR parameters, runtime
version and conversion settings. The original ONNX is never rewritten. Temporary
Core ML compilation uses the writable job directory. Existing prepared stem caches
are retained: acceleration applies when preparing uncached tracks.

If the provider is absent, conversion fails, or Core ML prediction throws or
returns invalid spectra, processing reports CPU use and continues there. A failed
block's positive and negative denoising predictions are both rerun on CPU; previous
completed audio stays intact. CPU errors are propagated instead of retried forever.
Progress reports conversion/loading, Core ML with GPU enabled, or CPU as applicable.
Core ML controls which allowed device executes each operation; the label describes
its enabled compute units, not a claim that every operation runs on GPU.

Verification:

- ONNX Runtime 1.31.0 includes CoreMLExecutionProvider in the bundled runtime.
- Real Inst_HQ_5 conversion and inference succeed. ONNX Runtime's profile reports
  one CoreMLExecutionProvider graph execution covering the model.
- Two real preparations reuse the same converted files without rewriting them.
  Core ML and CPU both produce 4,410 finite stereo 44.1 kHz frames per stem on the
  synthetic probe. Their maximum sample difference is 3.17e-7; the two stems sum
  to the gain-adjusted original within 1e-7.
- Eleven Python checks pass, including content-specific conversion cache keys,
  static batch/GPU provider configuration, explicit CPU mode, unavailable-provider
  fallback, conversion errors, mid-prediction errors/non-finite GPU results and
  repeated CPU processing after fallback, plus existing spectral/overlap checks.
- The full Swift suite passes: 78 tests, five audio-environment skips, zero failures.
  This includes real MDX and Becruily preparation through the Swift worker.

This environment exposes no Metal device to the test process. Core ML's diagnostic
compute plan therefore reports CPU execution. Conversion, Core ML graph execution,
CPU equivalence and fallback are verified; actual GPU scheduling, throughput and
long-song listening quality require a normal desktop run on a GPU-enabled Mac.
No GPU speedup claim is made from these sandbox timings.

Provider options and cache behavior follow the official ONNX Runtime documentation:
https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html
