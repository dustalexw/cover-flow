#import "CFMDXRuntime.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <array>
#include <memory>
#include <string>

namespace {
Ort::Env &environment() { static Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "CoverFlow-iPad"); env.DisableTelemetryEvents(); return env; }
struct Model {
    Ort::Session session{nullptr};
    Ort::RunOptions run;
    std::string input, output;
    std::array<int64_t, 4> shape;
    size_t count;
    Model(const char *path, bool gpu, const char *cache, int frequency, int time) : shape{1,4,frequency,time}, count(4ULL*frequency*time) {
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(4);
        for (const char *batch : {"batch_size", "batch", "batch_dim"}) Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(options, batch, 1));
        if (gpu) options.AppendExecutionProvider("CoreML", {{"ModelFormat", "MLProgram"}, {"MLComputeUnits", "CPUAndGPU"}, {"RequireStaticInputShapes", "1"}, {"ModelCacheDirectory", cache}});
        session = Ort::Session(environment(), path, options);
        if (session.GetInputCount()!=1 || session.GetOutputCount()!=1) throw std::runtime_error("Choose a single-input, single-output MDX model.");
        Ort::AllocatorWithDefaultOptions allocator;
        input = session.GetInputNameAllocated(0,allocator).get(); output = session.GetOutputNameAllocated(0,allocator).get();
        for (const auto &info : {session.GetInputTypeInfo(0),session.GetOutputTypeInfo(0)}) {
            auto tensor=info.GetTensorTypeAndShapeInfo(); auto dimensions=tensor.GetShape();
            if (tensor.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || dimensions.size()!=4) throw std::runtime_error("The model must process float32 stereo spectra.");
            for (int i=0;i<4;i++) if (dimensions[i]>=0 && dimensions[i]!=shape[i]) throw std::runtime_error("The model dimensions do not match its UVR settings.");
        }
    }
};
NSError *makeError(const std::exception &exception) { return [NSError errorWithDomain:@"CoverFlow.MDX" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:exception.what()] ?: @"Model processing failed."}]; }
}
@interface CFMDXRuntime () { std::unique_ptr<Model> _model; }
@end
@implementation CFMDXRuntime
+ (NSString *)runtimeVersion { return [NSString stringWithUTF8String:OrtGetApiBase()->GetVersionString()]; }
- (instancetype)initWithPath:(NSString *)path gpu:(BOOL)gpu cache:(NSString *)cache frequency:(NSInteger)frequency time:(NSInteger)time error:(NSError **)error {
    if ((self=[super init])) { try { _model=std::make_unique<Model>(path.fileSystemRepresentation,gpu,cache.fileSystemRepresentation,(int)frequency,(int)time); } catch(const std::exception &e) { if(error) *error=makeError(e); return nil; } }
    return self;
}
- (NSData *)predict:(NSData *)spectrum error:(NSError **)error {
    try {
        if (spectrum.length!=_model->count*sizeof(float)) throw std::runtime_error("Incorrect MDX input size.");
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        auto input=Ort::Value::CreateTensor<float>(memory,(float *)spectrum.bytes,_model->count,_model->shape.data(),4);
        const char *in=_model->input.c_str(), *out=_model->output.c_str();
        auto outputs=_model->session.Run(_model->run,&in,&input,1,&out,1);
        auto info=outputs[0].GetTensorTypeAndShapeInfo();
        auto dimensions=info.GetShape();
        if (dimensions.size()!=4 || !std::equal(dimensions.begin(),dimensions.end(),_model->shape.begin()) || info.GetElementCount()!=_model->count || info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) throw std::runtime_error("The model returned invalid spectra.");
        return [NSData dataWithBytes:outputs[0].GetTensorData<float>() length:_model->count*sizeof(float)];
    } catch(const std::exception &e) { if(error) *error=makeError(e); return nil; }
}
- (void)cancel { if (_model) { try { _model->run.SetTerminate(); } catch(...) {} } }
@end
