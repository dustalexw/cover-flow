#import "CFMDXRuntime.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <array>
#include <memory>
#include <string>
#include <vector>

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

namespace {
struct Demucs {
    Ort::Session session{nullptr};
    Ort::RunOptions run;
    std::string input, output;
    int64_t segment = 0, stems = 0;
    /// `hint`: the stem count when the export leaves it dynamic (4 or 6), or 0 to
    /// find it out later with probe() — which runs a whole segment, so it's avoided
    /// whenever the count is known (the built-in downloads).
    explicit Demucs(const char *path, int64_t hint) {
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(4);
        // The optimizer's constant folding needs several gigabytes for this graph.
        options.SetGraphOptimizationLevel(ORT_DISABLE_ALL);
        options.DisableCpuMemArena();
        session = Ort::Session(environment(), path, options);
        if (session.GetInputCount()!=1 || session.GetOutputCount()!=1) throw std::runtime_error("This is not a Demucs stem model.");
        Ort::AllocatorWithDefaultOptions allocator;
        input = session.GetInputNameAllocated(0,allocator).get(); output = session.GetOutputNameAllocated(0,allocator).get();
        auto in = session.GetInputTypeInfo(0).GetTensorTypeAndShapeInfo();
        auto dims = in.GetShape();
        if (in.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || dims.size()!=3 || (dims[0]>=0 && dims[0]!=1) || dims[1]!=2) throw std::runtime_error("This is not a Demucs stem model.");
        segment = dims[2] > 0 ? dims[2] : 343980;
        auto out = session.GetOutputTypeInfo(0).GetTensorTypeAndShapeInfo();
        auto odims = out.GetShape();
        if (out.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || odims.size()!=4) throw std::runtime_error("This is not a Demucs stem model.");
        stems = odims[1] > 0 ? odims[1] : (hint == 4 || hint == 6 ? hint : 0);
        if (stems!=0 && stems!=4 && stems!=6) throw std::runtime_error("Choose a 4-stem or 6-stem HTDemucs model.");
    }
    /// Dynamic output dimensions: count the stems with a silent segment.
    void probe() {
        if (stems != 0) return;
        std::vector<float> silence(2 * segment, 0.0f);
        auto result = predict(silence.data());
        stems = (int64_t)(result.size() / (2 * segment));
        if (stems!=4 && stems!=6) throw std::runtime_error("Choose a 4-stem or 6-stem HTDemucs model.");
    }
    std::vector<float> predict(float *mix) {
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        std::array<int64_t,3> shape{1,2,segment};
        auto tensor=Ort::Value::CreateTensor<float>(memory,mix,(size_t)(2*segment),shape.data(),3);
        const char *in=input.c_str(), *out=output.c_str();
        auto outputs=session.Run(run,&in,&tensor,1,&out,1);
        auto info=outputs[0].GetTensorTypeAndShapeInfo();
        auto dims=info.GetShape();
        if (dims.size()!=4 || dims[0]!=1 || dims[2]!=2 || dims[3]!=segment || info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) throw std::runtime_error("The Demucs model returned unexpected stems.");
        const float *data=outputs[0].GetTensorData<float>();
        return std::vector<float>(data, data + info.GetElementCount());
    }
};
}
@interface CFDemucsRuntime () { std::unique_ptr<Demucs> _model; }
@end
@implementation CFDemucsRuntime
- (instancetype)initWithPath:(NSString *)path error:(NSError **)error {
    return [self initWithPath:path stems:0 error:error];
}
- (instancetype)initWithPath:(NSString *)path stems:(NSInteger)stems error:(NSError **)error {
    if ((self=[super init])) { try { _model=std::make_unique<Demucs>(path.fileSystemRepresentation, (int64_t)stems); } catch(const std::exception &e) { if(error) *error=makeError(e); return nil; } }
    return self;
}
- (BOOL)probeStems:(NSError **)error {
    try { _model->probe(); return YES; } catch(const std::exception &e) { if(error) *error=makeError(e); return NO; }
}
- (NSInteger)stemCount { return (NSInteger)_model->stems; }
- (NSInteger)segment { return (NSInteger)_model->segment; }
- (NSData *)predict:(NSData *)mix error:(NSError **)error {
    try {
        if (mix.length!=(NSUInteger)(2*_model->segment)*sizeof(float)) throw std::runtime_error("Incorrect Demucs input size.");
        auto result=_model->predict((float *)mix.bytes);
        if (_model->stems==0) _model->stems=(int64_t)(result.size()/(2*_model->segment));
        if ((int64_t)result.size()!=_model->stems*2*_model->segment) throw std::runtime_error("The Demucs model returned unexpected stems.");
        return [NSData dataWithBytes:result.data() length:result.size()*sizeof(float)];
    } catch(const std::exception &e) { if(error) *error=makeError(e); return nil; }
}
- (void)cancel { if (_model) { try { _model->run.SetTerminate(); } catch(...) {} } }
@end
