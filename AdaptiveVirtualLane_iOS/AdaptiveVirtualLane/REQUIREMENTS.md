# Requirements & Dependencies

## iOS App (No Third-Party Swift Packages Required)

All functionality is implemented using **Apple system frameworks only**:

| Framework | Version | Purpose |
|-----------|---------|---------|
| `SwiftUI` | iOS 17+ | All UI screens and state management |
| `CoreML` | iOS 17+ | Neural network inference (5 models) |
| `Vision` | iOS 17+ | VNCoreMLRequest, optical flow, classification |
| `AVFoundation` | iOS 17+ | Camera capture + AVSpeechSynthesizer voice guidance |
| `CoreLocation` | iOS 17+ | GPS positioning (CLLocationManager) |
| `CoreImage` | iOS 17+ | Frame preprocessing, color correction filters |
| `Accelerate` | iOS 17+ | Fast vectorized array operations |
| `Metal` | iOS 17+ | GPU-accelerated overlay rendering |
| `Combine` | iOS 17+ | Reactive state binding between pipeline and UI |

**Minimum Xcode version:** 15.0  
**Minimum iOS version:** 17.0  
**Swift version:** 5.9+

---

## CoreML Models Required

Five CoreML models must be present in the Xcode bundle:

| Model File | Source | Conversion |
|------------|--------|-----------|
| `bike_lane_seg.mlmodel` | **YOU HAVE THIS** — from Ultralytics training | Already converted |
| `road_type_cls.mlmodel` | **YOU HAVE THIS** — from Ultralytics training | Already converted |
| `yolo26n.mlpackage` | Ultralytics `yolo26n.pt` (COCO pretrained) | `scripts/convert_models.py obstacle` |
| `TwinLiteNetPlusMedium.mlpackage` | [TwinLiteNet GitHub](https://github.com/chequanghuy/TwinLiteNet) | `scripts/convert_models.py drivable` |
| `DepthAnythingV2Small.mlpackage` | [HuggingFace apple/DepthAnythingV2](https://huggingface.co/apple) or [DA2 repo](https://github.com/DepthAnything/Depth-Anything-V2) | `scripts/convert_models.py depth` |

### Fallback Behaviour (if model not found)

The app is designed to **degrade gracefully** — it will log a warning and use a heuristic fallback:

| Missing Model | Fallback |
|---------------|---------|
| `bike_lane_seg` | No bike lane detection (always open-road branch) |
| `yolo26n` | No obstacle detection (path generation still works) |
| `TwinLiteNetPlusMedium` | Bottom 60% of frame assumed drivable |
| `DepthAnythingV2Small` | Road width assumed ~3m at 3m depth |
| `road_type_cls` | Defaults to two-way (conservative) |

This means the app **runs and produces a visual lane overlay** even without all models, which is useful for testing the UI and pipeline structure before all models are added.

---

## External Services

| Service | API | Free Tier | Purpose |
|---------|-----|-----------|---------|
| TomTom Location Platform | REST (HTTPS) | 2,500 req/day | Geocoding, bicycle routing, traffic flow |

Sign up at: https://developer.tomtom.com  
No credit card required for the free tier.

---

## Python Dependencies (for model conversion only)

Only needed when running `scripts/convert_models.py`:

```
torch>=2.0.0
torchvision>=0.15.0
coremltools>=7.0
ultralytics>=8.4.45
```

Install with:
```bash
pip install torch torchvision coremltools "ultralytics>=8.4.45"
```

---

## Hardware Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| iPhone chip | A12 Bionic (iPhone XS) | A16 Bionic (iPhone 14 Pro) |
| RAM | 3 GB | 6 GB |
| iOS | 17.0 | 17.4+ |
| Neural Engine | Yes (for DA2-S acceleration) | Yes |
| Camera | Wide-angle rear | Wide-angle rear |
| GPS | Yes | Yes (with good sky view) |
